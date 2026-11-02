import Foundation

/// 날짜/시간 표시. 모든 날짜는 한국 시간 기준.
enum Format {
    static let seoul = TimeZone(identifier: "Asia/Seoul")!

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = seoul
        return c
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = seoul
        f.dateFormat = "a h:mm"
        return f
    }()

    static func date(_ iso: String) -> Date? { self.iso.date(from: iso) }

    /// "2026-11-02T22:30:00.000Z" → "오전 7:30"
    static func time(_ iso: String) -> String {
        guard let d = date(iso) else { return "" }
        return timeFormatter.string(from: d)
    }

    /// 2분 이내에 시작된 시각인지
    static func isRecent(_ iso: String) -> Bool {
        guard let d = date(iso) else { return false }
        return Date().timeIntervalSince(d) < 120
    }

    /// 4500 → "1시간 15분", 1500 → "25분"
    static func duration(seconds: Int) -> String {
        let m = max(0, seconds) / 60
        let h = m / 60
        if h == 0 { return "\(m)분" }
        return m % 60 == 0 ? "\(h)시간" : "\(h)시간 \(m % 60)분"
    }

    static func duration(from start: String, to end: String?) -> String {
        guard let s = date(start) else { return "" }
        let e = end.flatMap(date) ?? Date()
        return duration(seconds: Int(e.timeIntervalSince(s)))
    }

    /// 경과 시간 "1:02:33"
    static func clock(since start: Date, now: Date) -> String {
        let t = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    /// "2026-11-03" → (day: 3, weekday: "화", label: "11월 3일 (화)")
    static func day(_ ymd: String) -> (day: Int, weekday: String, label: String) {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3,
              let date = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else {
            return (0, "", ymd)
        }
        let wd = weekdays[calendar.component(.weekday, from: date) - 1]
        return (p[2], wd, "\(p[1])월 \(p[2])일 (\(wd))")
    }

    static func ymd(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: 달 ("YYYY-MM")

    static func currentMonth() -> String { String(ymd(Date()).prefix(7)) }

    private static func parseMonth(_ ym: String) -> (year: Int, month: Int) {
        let p = ym.split(separator: "-").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : (2026, 1)
    }

    static func month(_ ym: String, adding offset: Int) -> String {
        let (y, m) = parseMonth(ym)
        let total = y * 12 + (m - 1) + offset
        return String(format: "%04d-%02d", total / 12, total % 12 + 1)
    }

    /// "2026-11" → "2026년 11월"
    static func monthTitle(_ ym: String) -> String {
        let (y, m) = parseMonth(ym)
        return "\(y)년 \(m)월"
    }

    /// 달력 칸: 1일 앞 빈칸(nil) + 그 달의 날짜들("YYYY-MM-DD")
    static func calendarCells(_ ym: String) -> [String?] {
        let (y, m) = parseMonth(ym)
        guard let first = calendar.date(from: DateComponents(year: y, month: m, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let leading = calendar.component(.weekday, from: first) - 1
        return Array(repeating: nil, count: leading)
            + range.map { String(format: "%04d-%02d-%02d", y, m, $0) }
    }
}
