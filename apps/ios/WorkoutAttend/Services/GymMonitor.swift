import CoreLocation
import OSLog
import UIKit

/// 위치 권한, 헬스장 지오펜스(CLMonitor), 현재 위치 출석을 담당.
/// 지오펜스에 들어가면 앱이 꺼져 있어도 iOS가 앱을 백그라운드로 깨워서 출석시킨다.
private let log = Logger(subsystem: "workoutattend", category: "geofence")

@Observable
final class GymMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = GymMonitor()

    enum AutoStatus { case on, whenInUseOnly, off, notDetermined }

    private(set) var authorization: CLAuthorizationStatus
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
    private var monitor: CLMonitor?
    private var monitorTask: Task<Void, Never>?
    private static let monitorName = "GymMonitor"
    private static let conditionID = "gym"

    private override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    // MARK: 권한

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let wasNotDetermined = self.authorization == .notDetermined
            self.authorization = status
            // "앱 사용 중 허용" 직후 바로 "항상 허용"까지 요청
            if status == .authorizedWhenInUse && wasNotDetermined { self.manager.requestAlwaysAuthorization() }
            if status == .authorizedAlways || status == .authorizedWhenInUse { self.startMonitoring() }
        }
    }

    // MARK: 지오펜스

    /// 앱 시작 시마다 호출해야 한다 (백그라운드로 깨어났을 때 이벤트를 받기 위해).
    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task {
            log.info("monitor start")
            let monitor = await CLMonitor(Self.monitorName)
            self.monitor = monitor
            if !(await monitor.identifiers).contains(Self.conditionID) {
                let condition = CLMonitor.CircularGeographicCondition(center: Gym.coordinate, radius: Gym.radius)
                await monitor.add(condition, identifier: Self.conditionID, assuming: .unsatisfied)
            }
            do {
                for try await event in await monitor.events where event.identifier == Self.conditionID {
                    log.info("event state=\(String(describing: event.state), privacy: .public)")
                    switch event.state {
                    case .satisfied: await self.didEnterGym()
                    case .unsatisfied: await self.didLeaveGym()
                    default: break
                    }
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
