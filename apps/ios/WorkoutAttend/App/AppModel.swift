import Foundation
import Observation

@Observable
final class AppModel {
    enum Phase { case loading, loggedOut, loggedIn(Member) }

    var phase: Phase = .loading
    var today: TodayResponse?
    var history: HistoryResponse?
    var loadError: String?

    private var silentTriedDate: String?

    var me: Member? {
        if case .loggedIn(let m) = phase { m } else { nil }
    }

    var myTodayCheckin: String? {
        guard let me else { return nil }
        return today?.members.first { $0.id == me.id }?.checkedInAt
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
        history = nil
        phase = .loggedOut
    }

    private func afterLogin() async {
        await Notifications.requestAndRegister()
        await Notifications.uploadToken()
        GymMonitor.shared.startMonitoring()
        await onForeground()
    }

    func refresh() async {
        do {
            async let t = API.today()
            async let h = API.history(days: 14)
            today = try await t
            history = try await h
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

    func checkinNow() async throws -> CheckinResponse {
        let res = try await GymMonitor.shared.checkinHere(source: .manual)
        await refresh()
        return res
    }
}
