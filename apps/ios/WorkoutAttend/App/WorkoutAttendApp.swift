import SwiftUI
import UserNotifications

@main
struct WorkoutAttendApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        // 시뮬레이터 테스트용: `simctl launch <dev> dev.workoutattend.app -debugToken <토큰>`
        if let token = UserDefaults.standard.string(forKey: "debugToken") { Keychain.setToken(token) }
        #endif
        // 지오펜스 이벤트로 백그라운드에서 깨어난 경우에도 모니터를 다시 붙여야 이벤트를 받는다.
        if Keychain.token != nil { GymMonitor.shared.startMonitoring() }
        return true
    }

    // 앱을 보고 있을 때도 배너 표시
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
