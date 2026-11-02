import CoreLocation
import OSLog
import UIKit

/// 위치 권한, 헬스장 지오펜스(CLMonitor), 수동 입실 위치 확인을 담당.
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
            if !(await monitor.identifiers).contains(Self.conditionID) {
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
        UserDefaults.standard.set(state == .satisfied, forKey: Self.insideKey)
        handledSinceLaunch = true
        if state == .satisfied { await didEnterGym() } else { await didLeaveGym() }
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
        let inside: Bool
        if distance <= Gym.radius { inside = true }
        else if distance > Gym.radius + 30 { inside = false }
        else { return } // 경계 근처는 판단 보류
        let lastInside = UserDefaults.standard.object(forKey: Self.insideKey) as? Bool
        log.info("reconcile(\(reason, privacy: .public)) distance=\(Int(distance), privacy: .public) inside=\(inside, privacy: .public) last=\(String(describing: lastInside), privacy: .public)")
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
            let res = try await API.startSession(source: .geofence, location: nil)
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

    // MARK: 수동 입실

    /// 현재 위치로 수동 입실. 서버가 헬스장 반경 안인지 확인한다.
    func startHere() async throws -> SessionResponse {
        let location = try await currentLocation()
        return try await API.startSession(source: .manual, location: location)
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
