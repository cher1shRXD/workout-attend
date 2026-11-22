import CoreLocation
import OSLog
import UIKit

/// 위치 권한, 헬스장 지오펜스(CLMonitor)를 담당.
/// 지오펜스를 넘으면 앱이 꺼져 있어도 iOS가 앱을 백그라운드로 깨워서 입실/퇴실을 기록한다.
///
/// iOS 18부터는 "항상" 권한이 있어도 `.always` CLServiceSession 을 들고 있어야
/// 앱을 안 쓰는 동안(백그라운드·종료 상태) CLMonitor 이벤트를 받을 수 있다.
/// 앱이 백그라운드로 다시 실행되면 곧바로 세션을 다시 만들어야 한다 (didFinishLaunching → startMonitoring).
private let log = Logger(subsystem: "workoutattend", category: "geofence")

@Observable
final class GymMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = GymMonitor()

    enum AutoStatus { case on, whenInUseOnly, off, notDetermined }

    private(set) var authorization: CLAuthorizationStatus
    /// "정확한 위치"가 꺼져 있으면 지오펜스가 동작하지 않는다
    private(set) var preciseLocation: Bool
    var autoStatus: AutoStatus {
        switch authorization {
        case .authorizedAlways: .on
        case .authorizedWhenInUse: .whenInUseOnly
        case .notDetermined: .notDetermined
        default: .off
        }
    }

    /// 출석 성공 시 화면 갱신용
    var onCheckedIn: (() -> Void)?

    private let manager = CLLocationManager()
    private var serviceSession: CLServiceSession?
    private var monitor: CLMonitor?
    private var monitorTask: Task<Void, Never>?
    private static let monitorName = "GymMonitor"
    private static let conditionID = "gym"

    private override init() {
        authorization = manager.authorizationStatus
        preciseLocation = manager.accuracyAuthorization == .fullAccuracy
        super.init()
        manager.delegate = self
    }

    // MARK: 권한

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: openSettings()
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let precise = manager.accuracyAuthorization == .fullAccuracy
        Task { @MainActor in
            let wasNotDetermined = self.authorization == .notDetermined
            self.authorization = status
            self.preciseLocation = precise
            // "앱 사용 중 허용" 직후 바로 "항상 허용"까지 요청
            if status == .authorizedWhenInUse && wasNotDetermined { self.manager.requestAlwaysAuthorization() }
            if status == .authorizedAlways || status == .authorizedWhenInUse { self.startMonitoring() }
        }
    }

    // MARK: 지오펜스

    /// 앱 시작 시마다 호출해야 한다 (백그라운드로 깨어났을 때 이벤트를 받기 위해).
    /// 이번 실행에서 입실/퇴실 이벤트를 하나라도 처리했는지
    private var handledSinceLaunch = false

    /// - Parameter launchedForLocation: iOS가 위치 이벤트 때문에 앱을 백그라운드로 실행했는지
    func startMonitoring(launchedForLocation: Bool = false) {
        // 세션은 실행 직후 바로 잡아야 한다. 늦으면 백그라운드 실행에서 이벤트를 못 받는다.
        if serviceSession == nil {
            serviceSession = CLServiceSession(authorization: .always)
            log.info("service session created")
        }
        guard monitorTask == nil else { return }
        monitorTask = Task {
            log.info("monitor start")
            let monitor = await CLMonitor(Self.monitorName)
            self.monitor = monitor
            // 예전 반경으로 등록돼 있으면 새 반경으로 바꾼다
            let existing = await monitor.record(for: Self.conditionID)?.condition as? CLMonitor.CircularGeographicCondition
            if existing?.radius != Gym.radius {
                if existing != nil { await monitor.remove(Self.conditionID) }
                let condition = CLMonitor.CircularGeographicCondition(center: Gym.coordinate, radius: Gym.radius)
                await monitor.add(condition, identifier: Self.conditionID, assuming: .unsatisfied)
            }
            // 이 이벤트 때문에 앱이 깨어난 경우, 스트림을 듣기 전에 이미 지나가 버릴 수 있다.
            // 마지막으로 기록된 상태 변화를 먼저 확인해서 아직 처리 안 했으면 처리한다.
            if let last = await monitor.record(for: Self.conditionID)?.lastEvent {
                await self.handle(state: last.state, date: last.date, via: "record")
            }
            // 입실 상태로 다시 실행됐으면 층을 벗어나는지 계속 본다
            if self.isInside { self.watchPresence() }
            log.info("monitor ready launchedForLocation=\(launchedForLocation, privacy: .public)")
            if launchedForLocation { self.scheduleLaunchFallback() }
            do {
                for try await event in await monitor.events where event.identifier == Self.conditionID {
                    await self.handle(state: event.state, date: event.date, via: "stream")
                }
            } catch {
                log.error("CLMonitor error \(error.localizedDescription, privacy: .public)")
            }
            self.monitorTask = nil
        }
    }

    func stopMonitoring() async {
        monitorTask?.cancel()
        monitorTask = nil
        presenceWatch?.cancel()
        presenceWatch = nil
        await monitor?.remove(Self.conditionID)
        serviceSession?.invalidate()
        serviceSession = nil
    }

    /// 마지막으로 처리한 상태 변화 시각. 같은 이벤트를 두 번 처리하지 않게 한다
    /// (예: 헬스장 안에서 직접 운동 종료 후 앱을 다시 열어도 다시 시작되지 않도록).
    private static let handledKey = "geofence.lastHandledEventDate"
    /// 마지막으로 처리한 상태 (true = 헬스장 안)
    private static let insideKey = "geofence.lastHandledInside"

    private func handle(state: CLMonitor.Event.State, date: Date, via: String) async {
        let lastHandled = UserDefaults.standard.object(forKey: Self.handledKey) as? Date ?? .distantPast
        log.info("event state=\(state.rawValue, privacy: .public) via=\(via, privacy: .public) new=\(date > lastHandled, privacy: .public)")
        guard date > lastHandled, state == .satisfied || state == .unsatisfied else { return }
        UserDefaults.standard.set(date, forKey: Self.handledKey)
        handledSinceLaunch = true
        if state == .satisfied {
            // 반경에 들어온 것만으로는 부족하다. 반경 안 + 헬스장 층 고도가 확인되면 입실.
            watchPresence()
        } else {
            presenceWatch?.cancel()
            presenceWatch = nil
            UserDefaults.standard.set(false, forKey: Self.insideKey)
            await didLeaveGym()
        }
    }

    // MARK: 층(고도) 확인

    private var presenceWatch: Task<Void, Never>?
    /// 헬스장 밖(다른 층)에서 입실을 기다리는 최대 시간
    private static let entryWatchTimeout: Duration = .seconds(30 * 60)
    /// GPS 고도는 흔들리므로, 헬스장 층을 벗어난 값이 이 시간·횟수 이상 이어져야 퇴실로 본다
    private static let leaveConfirmDuration: TimeInterval = 60
    private static let leaveConfirmCount = 3

    private var isInside: Bool { UserDefaults.standard.object(forKey: Self.insideKey) as? Bool == true }

    /// 반경 근처에 있는 동안 위치를 계속 본다.
    /// - (반경 안 AND 헬스장 층 고도) 이면 입실
    /// - 입실 상태에서 그 조건이 깨지면(예: 1층으로 내려감) 퇴실
    /// 반경을 확실히 벗어나면 그만둔다. 입실 전에는 entryWatchTimeout 이 지나도 그만둔다.
    private func watchPresence() {
        guard presenceWatch == nil else { return }
        presenceWatch = Task {
            // 가만히 있어도 앱이 정지되지 않게 백그라운드 위치 세션을 유지한다
            let activity = CLBackgroundActivitySession()
            defer {
                activity.invalidate()
                presenceWatch = nil
            }
            let gym = CLLocation(latitude: Gym.coordinate.latitude, longitude: Gym.coordinate.longitude)
            var waitingSince = ContinuousClock.now
            var offSince: Date?
            var offCount = 0
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if Task.isCancelled { break }
                    guard let loc = update.location, loc.horizontalAccuracy >= 0 else { continue }
                    let distance = loc.distance(from: gym)
                    log.info("presence distance=\(Int(distance), privacy: .public) alt=\(loc.altitude, privacy: .public) vacc=\(loc.verticalAccuracy, privacy: .public) inside=\(self.isInside, privacy: .public)")
                    if distance > Gym.radius + 30 {
                        await setInside(false, reason: "far")
                        break
                    }
                    if distance <= Gym.radius && Gym.isOnFloor(loc) {
                        offSince = nil
                        offCount = 0
                        await setInside(true, reason: "floor")
                    } else if isInside {
                        // 고도를 못 받은 값으로는 퇴실 판단을 하지 않는다
                        if distance <= Gym.radius && loc.verticalAccuracy < 0 { continue }
                        let since = offSince ?? loc.timestamp
                        offSince = since
                        offCount += 1
                        if offCount >= Self.leaveConfirmCount && loc.timestamp.timeIntervalSince(since) >= Self.leaveConfirmDuration {
                            await setInside(false, reason: "off-floor")
                            offSince = nil
                            offCount = 0
                            waitingSince = .now
                        }
                    } else if ContinuousClock.now - waitingSince >= Self.entryWatchTimeout {
                        break
                    }
                }
            } catch {
                log.error("presence watch error \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 상태가 바뀔 때만 입실/퇴실 처리
    private func setInside(_ inside: Bool, reason: String) async {
        guard isInside != inside else { return }
        log.info("\(inside ? "enter" : "leave", privacy: .public) via \(reason, privacy: .public)")
        UserDefaults.standard.set(Date(), forKey: Self.handledKey)
        UserDefaults.standard.set(inside, forKey: Self.insideKey)
        if inside { await didEnterGym() } else { await didLeaveGym() }
    }

    /// 위치 이벤트로 깨어났는데 이벤트가 전달되지 않는 경우가 있어서(앱이 듣기 전에 지나감),
    /// 몇 초 기다려도 처리한 게 없으면 현재 위치로 맞춰본다.
    private func scheduleLaunchFallback() {
        Task {
            let bgTask = UIApplication.shared.beginBackgroundTask(withName: "gym-launch-fallback")
            defer { UIApplication.shared.endBackgroundTask(bgTask) }
            try? await Task.sleep(for: .seconds(3))
            guard !handledSinceLaunch else { return }
            await reconcileWithCurrentLocation(reason: "launch")
        }
    }

    /// 놓친 입실/퇴실이 있으면 현재 위치로 맞춘다. (위치 이벤트로 깨어났을 때, 앱을 열 때)
    /// 마지막으로 처리한 상태(안/밖)와 다를 때만 처리하므로, 헬스장 안에서 직접 운동을 끝낸 뒤
    /// 앱을 다시 열어도 다시 시작되지 않는다. 서버도 중복 입실/퇴실은 무시한다.
    func reconcileWithCurrentLocation(reason: String) async {
        guard Keychain.token != nil, autoStatus == .on || autoStatus == .whenInUseOnly else { return }
        guard let location = try? await currentLocation(timeout: .seconds(8)) else { return }
        let gym = CLLocation(latitude: Gym.coordinate.latitude, longitude: Gym.coordinate.longitude)
        let distance = location.distance(from: gym)
        let lastInside = UserDefaults.standard.object(forKey: Self.insideKey) as? Bool
        log.info("reconcile(\(reason, privacy: .public)) distance=\(Int(distance), privacy: .public) alt=\(location.altitude, privacy: .public) last=\(String(describing: lastInside), privacy: .public)")
        // 입실은 반경 안 AND 헬스장 층 고도. 반경을 확실히 벗어났으면 바로 퇴실.
        // 그 밖(반경 안인데 다른 층 등)은 값 하나로 판단하지 않고 지켜본다.
        if distance > Gym.radius + 30 {
            await setInside(false, reason: "reconcile-far")
        } else if distance <= Gym.radius && Gym.isOnFloor(location) {
            await setInside(true, reason: "reconcile-floor")
        } else if distance <= Gym.radius || lastInside == true {
            watchPresence()
        }
    }

    /// 헬스장 입실 = 출석 + 운동 시작
    private func didEnterGym() async {
        guard Keychain.token != nil else { return }
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "gym-enter")
        defer { UIApplication.shared.endBackgroundTask(bgTask) }
        do {
            let res = try await API.startSession(source: .geofence)
            // 잠깐 나갔다 들어와 이전 운동을 이어가는 경우엔 알리지 않는다
            if !res.unchanged, let s = res.session, Format.isRecent(s.startedAt) {
                await Notifications.local(title: "출석 💪", body: "\(Gym.name) 입실! 운동 기록을 시작했어요.")
            }
        } catch {
            log.error("start failed \(error.localizedDescription, privacy: .public)")
        }
        onCheckedIn?()
    }

    /// 헬스장 퇴실 = 운동 종료
    private func didLeaveGym() async {
        guard Keychain.token != nil else { return }
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "gym-leave")
        defer { UIApplication.shared.endBackgroundTask(bgTask) }
        guard let res = try? await API.endSession(source: .geofence), !res.unchanged, let s = res.session else { return }
        await Notifications.local(title: "퇴실 👋", body: "이번에 \(Format.duration(from: s.startedAt, to: s.endedAt)) 운동했어요.")
        onCheckedIn?()
    }

    /// 정확도 65m 이내 위치를 최대 15초 기다린다. 못 받으면 가장 좋은 값을 쓴다.
    private func currentLocation(timeout: Duration = .seconds(15)) async throws -> CLLocation {
        var best: CLLocation?
        let deadline = ContinuousClock.now + timeout
        let updates = Task<CLLocation?, Error> {
            for try await update in CLLocationUpdate.liveUpdates() {
                guard let loc = update.location, loc.horizontalAccuracy >= 0 else { continue }
                if best == nil || loc.horizontalAccuracy < best!.horizontalAccuracy { best = loc }
                if loc.horizontalAccuracy <= 65 || ContinuousClock.now >= deadline { return best }
            }
            return best
        }
        let timer = Task {
            try? await Task.sleep(until: deadline)
            updates.cancel()
        }
        defer { timer.cancel() }
        if let loc = try? await updates.value ?? best { return loc }
        if let loc = best ?? manager.location { return loc }
        throw APIError(message: "현재 위치를 확인할 수 없어요.", status: 0)
    }
}
