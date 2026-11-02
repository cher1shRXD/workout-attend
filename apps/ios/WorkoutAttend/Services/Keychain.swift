import Foundation
import Security

/// 로그인 토큰 저장소. 잠금 상태의 백그라운드(지오펜스)에서도 읽을 수 있게 AfterFirstUnlock.
nonisolated enum Keychain {
    private static let service = "com.taewookim.workoutattend"
    private static let account = "auth-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var token: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ value: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let value else { return }
        var query = baseQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}
