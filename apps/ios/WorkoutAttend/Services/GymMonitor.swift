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
            // 반경에 들어온 것만으로는 부족하다. 헬스장 층 고도가 확인되면 입실.
            watchForGymFloor()
        } else {
            floorWatch?.cancel()
            floorWatch = nil
            UserDefaults.standard.set(false, forKey: Self.insideKey)
            await didLeaveGym()
        }
    }

    // MARK: 층(고도) 확인

    private var floorWatch: Task<Void, Never>?
    /// 반경에 들어온 뒤 입실 조건을 기다리는 최대 시간
    private static let floorWatchTimeout: Duration = .seconds(30 * 60)
    /// Gym.nearRadius 안에 계속 머문 시작 시각 (고도와 상관없이 오래 있으면 입실)
    private var nearGymSince: Date?

    /// 반경 안에서 아래 중 하나가 되면 입실 처리. 반경을 벗어나거나 시간이 지나면 그만둔다.
    /// - 고도가 헬스장 층 범위
    /// - 고도가 달라도 Gym.nearRadius 안에 Gym.nearDuration 이상 머묾
    private func watchForGymFloor() {
        guard floorWatch == nil else { return }
        floorWatch = Task {
            // 가만히 있으면 위치 업데이트가 멈추고 앱이 정지될 수 있어서, 감시하는 동안 백그라운드 실행을 유지한다
            let activity = CLBackgroundActivitySession()
            let bgTask = UIApplication.shared.beginBackgroundTask(withName: "gym-floor")
            nearGymSince = nil
            // 가만히 있어서 업데이트가 안 와도 머문 시간을 확인한다
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    if self.stayedNearLongEnough() {
                        await self.enterFromWatch(reason: "stay")
                        self.floorWatch?.cancel()
                        return
                    }
                }
            }
            defer {
                ticker.cancel()
                activity.invalidate()
                UIApplication.shared.endBackgroundTask(bgTask)
                nearGymSince = nil
                floorWatch = nil
            }
            let gym = CLLocation(latitude: Gym.coordinate.latitude, longitude: Gym.coordinate.longitude)
            let deadline = ContinuousClock.now + Self.floorWatchTimeout
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if Task.isCancelled || ContinuousClock.now >= deadline { break }
                    guard let loc = update.location, loc.horizontalAccuracy >= 0 else { continue }
                    let distance = loc.distance(from: gym)
                    log.info("floor watch distance=\(Int(distance), privacy: .public) alt=\(loc.altitude, privacy: .public) vacc=\(loc.verticalAccuracy, privacy: .public)")
                    if distance > Gym.radius + 30 { break }
                    if distance <= Gym.nearRadius { nearGymSince = nearGymSince ?? loc.timestamp } else { nearGymSince = nil }
                    if distance <= Gym.radius && Gym.isOnFloor(loc) {
                        await enterFromWatch(reason: "floor")
                        break
                    }
                    if stayedNearLongEnough() {
                        await enterFromWatch(reason: "stay")
                        break
                    }
                }
            } catch {
                log.error("floor watch error \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func stayedNearLongEnough() -> Bool {
        guard let since = nearGymSince else { return false }
        return Date().timeIntervalSince(since) >= Gym.nearDuration
    }

    private func enterFromWatch(reason: String) async {
        // 고도 확인과 머문 시간 확인이 동시에 통과해도 한 번만
        guard UserDefaults.standard.object(forKey: Self.insideKey) as? Bool != true else { return }
        log.info("enter via \(reason, privacy: .public)")
        UserDefaults.standard.set(Date(), forKey: Self.handledKey)
        UserDefaults.standard.set(true, forKey: Self.insideKey)
        await didEnterGym()
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
        // 입실은 반경 + 헬스장 층 고도, 퇴실은 반경을 확실히 벗어났을 때만
        let inside: Bool
        if distance <= Gym.radius && Gym.isOnFloor(location) { inside = true }
        else if distance > Gym.radius + 30 { inside = false }
        else {
            // 반경 안인데 아직 다른 층이면 올라올 때까지 지켜본다. 경계 근처는 판단 보류.
            if distance <= Gym.radius && lastInside != true { watchForGymFloor() }
            return
        }
        guard lastInside != inside else { return }
        UserDefaults.standard.set(Date(), forKey: Self.handledKey)
        UserDefaults.standard.set(inside, forKey: Self.insideKey)
        if inside { await didEnterGym() } else { await didLeaveGym() }
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
