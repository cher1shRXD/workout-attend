import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
            case .loggedOut:
                JoinView()
            case .loggedIn:
                HomeView()
            }
        }
        .task { await model.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.me != nil {
                Task { await model.onForeground() }
            }
        }
    }
}

enum Format {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        f.dateFormat = "a h:mm"
        return f
    }()

    /// "2026-11-02T22:30:00.000Z" → "오전 7:30"
    static func time(_ iso: String) -> String {
        guard let d = self.iso.date(from: iso) else { return "" }
        return time.string(from: d)
    }

    static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    /// "2026-11-03" → (day: 3, weekday: "화", label: "11월 3일 (화)")
    static func day(_ ymd: String) -> (day: Int, weekday: String, label: String) {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return (0, "", ymd) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let date = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
        let wd = weekdays[cal.component(.weekday, from: date) - 1]
        return (p[2], wd, "\(p[1])월 \(p[2])일 (\(wd))")
    }
}
