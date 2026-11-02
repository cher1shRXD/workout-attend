import UIKit
import UserNotifications

enum Notifications {
    /// 받은 APNs 디바이스 토큰. 로그인 전에 받으면 로그인 후 전송.
    private static var deviceToken: String?

    static func requestAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    static func didReceive(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        Task { await uploadToken() }
    }

    static func uploadToken() async {
        guard let deviceToken, Keychain.token != nil else { return }
        #if DEBUG
        let sandbox = true // Xcode 로 직접 설치한 빌드
        #else
        let sandbox = false // TestFlight / App Store
        #endif
        try? await API.savePushToken(deviceToken, sandbox: sandbox)
    }

    static func local(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}
