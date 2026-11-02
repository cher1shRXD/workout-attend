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
        // 시뮬레이터 테스트용: `simctl launch <dev> com.taewookim.workoutattend -debugToken <토큰>`
        if let token = UserDefaults.standard.string(forKey: "debugToken") { Keychain.setToken(token) }
        #endif
        // 지오펜스 이벤트로 백그라운드에서 깨어난 경우에도 모니터를 다시 붙여야 이벤트를 받는다.
        if Keychain.token != nil {
            // 이 앱은 위치 말고는 백그라운드로 실행될 이유가 없다(푸시·백그라운드 갱신 없음).
            // CLMonitor 로 깨어날 때 launchOptions 에 .location 이 안 붙는 경우가 있어서 실행 상태로 판단한다.
            let launchedInBackground = application.applicationState == .background || launchOptions?[.location] != nil
            GymMonitor.shared.startMonitoring(launchedForLocation: launchedInBackground)
        }
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
