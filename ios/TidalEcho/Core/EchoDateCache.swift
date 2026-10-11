import Foundation

/// Shared, pre-warmed date machinery for the chat list.
///
/// Every bubble needs its timestamp parsed and formatted, and the grouping rules
/// need it again for both neighbours. Allocating an `ISO8601DateFormatter` /
/// `DateFormatter` / `Calendar` per call — as the row code used to — costs tens
/// of microseconds each, which turns into milliseconds of main-thread work on
/// every scroll frame once a few hundred messages are on screen.
///
/// Formatters are only ever touched from the main actor (SwiftUI body passes),
/// and `DateFormatter`/`ISO8601DateFormatter` are documented as thread-safe for
/// parsing and formatting anyway.
enum EchoDateCache {
    static let shanghaiTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    static let shanghaiCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghaiTimeZone
        return calendar
    }()

    private static let fractionalParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainParser = ISO8601DateFormatter()

    private static var parsed: [String: Date] = [:]

    /// Parses a relay timestamp, memoising the result. Message timestamps are
    /// immutable once received, so the cache never goes stale; it is trimmed
    /// when it outgrows a few history pages.
    static func date(from raw: String) -> Date? {
        if let hit = parsed[raw] { return hit }
        guard let value = fractionalParser.date(from: raw) ?? plainParser.date(from: raw) else {
            return nil
        }
        if parsed.count > 4000 { parsed.removeAll(keepingCapacity: true) }
        parsed[raw] = value
        return value
    }

    private static let timeOnly = makeFormatter("HH:mm")
    private static let monthDay = makeFormatter("M/d HH:mm")
    private static let fullDate = makeFormatter("yyyy/M/d HH:mm")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = shanghaiTimeZone
        formatter.dateFormat = format
        return formatter
    }

    /// Bubble timestamp label: time of day for today, month/day this year, full
    /// date otherwise.
    static func bubbleTimeLabel(_ raw: String) -> String {
        guard let date = date(from: raw) else { return "" }
        let calendar = shanghaiCalendar
        if calendar.isDateInToday(date) {
            return timeOnly.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return monthDay.string(from: date)
        }
        return fullDate.string(from: date)
    }
}
