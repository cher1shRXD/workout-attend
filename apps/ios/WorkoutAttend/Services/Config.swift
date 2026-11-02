import CoreLocation
import Foundation

nonisolated enum AppConfig {
    /// Info.plist 의 API_BASE_URL (project.yml 의 configs 에서 Debug/Release 별로 지정)
    static let apiBaseURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String ?? ""
        return URL(string: raw.trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://localhost:3000")!
    }()
}

/// 앨리스휘트니스 인천논현 (인천 남동구 논고개로123번길 17, 아이플렉스 509~511호)
/// 서버(apps/server/src/shared.ts)의 GYM 값과 맞춰야 한다.
nonisolated enum Gym {
    static let name = "앨리스휘트니스 인천논현"
    static let coordinate = CLLocationCoordinate2D(latitude: 37.40163, longitude: 126.72276)
    static let radius: CLLocationDistance = 100
}
