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

    private var silentTriedDate: String?

    var me: Member? {
        if case .loggedIn(let m) = phase { m } else { nil }
    }

    var myTodayCheckin: String? {
        guard let me else { return nil }
        return today?.members.first { $0.id == me.id }?.checkedInAt
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

    /// 앱을 열 때 헬스장이면 조용히 출석 (지오펜스를 놓친 경우 대비)
    func onForeground() async {
        await refresh()
        guard let today, myTodayCheckin == nil, silentTriedDate != today.date else { return }
        let auth = GymMonitor.shared.authorization
        guard auth == .authorizedAlways || auth == .authorizedWhenInUse else { return }
        silentTriedDate = today.date
        if (try? await GymMonitor.shared.checkinHere(source: .manual)) != nil {
            await refresh()
        }
    }

    func showMonth(offset: Int) async {
        calendarMonth = Format.month(calendarMonth, adding: offset)
        let month = calendarMonth
        if let cal = try? await API.calendar(month: month), month == calendarMonth { calendar = cal }
    }

    func startWorkout() async throws {
        _ = try await API.startSession(source: .manual)
        await refresh()
    }

    func endWorkout() async throws -> WorkoutSession? {
        let res = try await API.endSession(source: .manual)
        await refresh()
        return res.session
    }

    func checkinNow() async throws -> CheckinResponse {
        let res = try await GymMonitor.shared.checkinHere(source: .manual)
        await refresh()
        return res
    }
}
