import CoreLocation
import Foundation

nonisolated enum AppConfig {
    /// Info.plist 의 API_BASE_URL (project.yml 의 configs 에서 Debug/Release 별로 지정)
    static let apiBaseURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // 빌드 설정이 비어 있으면 실서버로
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return URL(string: "https://workout-attend.vercel.app")!
        }
        return url
    }()
}

/// 앨리스휘트니스 인천논현 (인천 남동구 논고개로123번길 17, 아이플렉스 509~511호)
/// 서버(apps/server/src/shared.ts)의 GYM 값과 맞춰야 한다.
nonisolated enum Gym {
    static let name = "앨리스휘트니스 인천논현"
    static let coordinate = CLLocationCoordinate2D(latitude: 37.40163, longitude: 126.72276)
    static let radius: CLLocationDistance = 50
    /// 해발고도(m)가 이 범위 안이어야 헬스장 층(5층)에 있는 걸로 본다.
    /// 입실 = 반경 안 AND 이 고도, 퇴실 = 그 조건이 깨짐 (예: 1층으로 내려감).
    static let altitudeRange: ClosedRange<CLLocationDistance> = 15...22

    /// 헬스장 층 고도인지. 고도를 못 받았으면 false.
    static func isOnFloor(_ location: CLLocation) -> Bool {
        location.verticalAccuracy >= 0 && altitudeRange.contains(location.altitude)
    }
}
