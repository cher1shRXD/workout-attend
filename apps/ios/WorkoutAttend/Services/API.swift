import Foundation

// MARK: - 모델 (서버 apps/server/src/shared.ts 와 동일)

nonisolated struct Member: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

nonisolated struct JoinResponse: Codable, Sendable {
    let token: String
    let member: Member
}

nonisolated enum CheckinSource: String, Codable, Sendable {
    case manual, geofence
}

nonisolated struct CheckinRequest: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let source: CheckinSource
}

nonisolated struct CheckinResponse: Codable, Sendable {
    let date: String
    let checkedInAt: String
    let alreadyCheckedIn: Bool
    let distanceMeters: Int
}

nonisolated struct TodayMember: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let checkedInAt: String?
}

nonisolated struct TodayResponse: Codable, Sendable {
    struct Window: Codable, Sendable { let startHour: Int; let endHour: Int }
    struct GymInfo: Codable, Sendable { let name: String; let latitude: Double; let longitude: Double; let radiusMeters: Double }
    let date: String
    let window: Window
    let gym: GymInfo
    let members: [TodayMember]
}

nonisolated struct HistoryResponse: Codable, Sendable {
    struct Row: Codable, Identifiable, Sendable {
        let id: Int
        let name: String
        let attended: [String: String]
    }
    let dates: [String]
    let members: [Row]
}

nonisolated struct APIError: LocalizedError, Sendable {
    let message: String
    let status: Int
    var errorDescription: String? { message }
}

// MARK: - 클라이언트

nonisolated enum API {
    private struct ErrorBody: Decodable { let error: String }
    private struct OK: Decodable {}
    private struct Empty: Encodable {}

    private static func request<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> T {
        var req = URLRequest(url: URL(string: path, relativeTo: AppConfig.apiBaseURL)!.absoluteURL)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = Keychain.token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = try JSONEncoder().encode(body) }

        let (data, res) = try await URLSession.shared.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "요청 실패 (\(status))"
            throw APIError(message: msg, status: status)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func join(name: String, code: String) async throws -> JoinResponse {
        struct Body: Encodable { let name: String; let code: String }
        return try await request("POST", "/api/join", body: Body(name: name, code: code))
    }

    static func me() async throws -> Member {
        try await request("GET", "/api/me")
    }

    static func savePushToken(_ token: String, sandbox: Bool) async throws {
        struct Body: Encodable { let token: String; let environment: String }
        let _: OK = try await request("PUT", "/api/push-token", body: Body(token: token, environment: sandbox ? "sandbox" : "production"))
    }

    static func checkin(_ body: CheckinRequest) async throws -> CheckinResponse {
        try await request("POST", "/api/checkin", body: body)
    }

    static func today() async throws -> TodayResponse {
        try await request("GET", "/api/today")
    }

    static func history(days: Int = 14) async throws -> HistoryResponse {
        try await request("GET", "/api/history?days=\(days)")
    }
}
