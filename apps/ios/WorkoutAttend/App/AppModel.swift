import Foundation
import Observation

@Observable
final class AppModel {
    enum Phase { case loading, loggedOut, loggedIn(Member) }

    var phase: Phase = .loading
    var today: TodayResponse?
    var calendar: CalendarResponse?
    /// 달력에 보이는 달 (KST "YYYY-MM"). 처음엔 이번 달.
    var calendarMonth: String = Format.currentMonth()
    var loadError: String?

    var me: Member? {
        if case .loggedIn(let m) = phase { m } else { nil }
    }

    /// 지금 내가 운동 중이면 시작 시각
    var myActiveSince: String? {
        guard let me else { return nil }
        return today?.members.first { $0.id == me.id }?.activeSince
    }

    init() {
        GymMonitor.shared.onCheckedIn = { [weak self] in
            Task { await self?.refresh() }
        }
    }

    func bootstrap() async {
        guard Keychain.token != nil else { phase = .loggedOut; return }
        do {
            phase = .loggedIn(try await API.me())
        } catch let e as APIError where e.status == 401 {
            Keychain.setToken(nil)
            phase = .loggedOut
            return
        } catch {
            // 오프라인 등: 일단 홈으로 보내고 거기서 재시도
            phase = .loggedIn(Member(id: -1, name: ""))
        }
        await afterLogin()
    }

    func join(name: String, code: String) async throws {
        let res = try await API.join(name: name, code: code)
        Keychain.setToken(res.token)
        phase = .loggedIn(res.member)
        await afterLogin()
    }

    func logout() async {
        await GymMonitor.shared.stopMonitoring()
        Keychain.setToken(nil)
        today = nil
        calendar = nil
        phase = .loggedOut
    }

    private func afterLogin() async {
        // 알림 권한 팝업 응답을 기다리지 않고 바로 데이터를 불러온다
        #if DEBUG
        let skipPrompt = UserDefaults.standard.bool(forKey: "debugNoPrompt")
        #else
        let skipPrompt = false
        #endif
        if !skipPrompt { Task { await Notifications.requestPermission() } }
        GymMonitor.shared.startMonitoring()
        await onForeground()
    }

    func refresh() async {
        do {
            async let t = API.today()
            async let c = API.calendar(month: calendarMonth)
            today = try await t
            let cal = try await c
            if cal.month == calendarMonth { calendar = cal }
            if me?.id == -1 { phase = .loggedIn(try await API.me()) }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 앱이 앞으로 올 때 최신 상태로. 입실/퇴실은 지오펜스가 처리한다.
    func onForeground() async {
        await refresh()
    }

    func showMonth(offset: Int) async {
        calendarMonth = Format.month(calendarMonth, adding: offset)
        let month = calendarMonth
        if let cal = try? await API.calendar(month: month), month == calendarMonth { calendar = cal }
    }

    /// 수동 입실 (지오펜스가 놓쳤을 때). 헬스장 반경 안이어야 한다.
    func startWorkout() async throws {
        _ = try await GymMonitor.shared.startHere()
        await refresh()
    }

    func endWorkout() async throws -> WorkoutSession? {
        let res = try await API.endSession(source: .manual)
        await refresh()
        return res.session
    }

}
