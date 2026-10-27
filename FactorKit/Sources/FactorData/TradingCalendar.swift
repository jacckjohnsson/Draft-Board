import Foundation

/// US equity trading days. Dates are "yyyy-MM-dd" in America/New_York.
/// Full-day NYSE holidays are skipped so they never cost an API call; any other
/// closure (e.g. a national day of mourning) is learned from an empty response.
public enum TradingCalendar {
    public static let newYork = TimeZone(identifier: "America/New_York")!

    static func gregorian(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    public static func isoString(_ date: Date, timeZone: TimeZone = newYork) -> String {
        let c = gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func date(fromISO s: String, timeZone: TimeZone = newYork) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return gregorian(timeZone).date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    /// Trading days in [from, to], both inclusive, oldest first.
    public static func tradingDays(from: String, to: String) -> [String] {
        guard var d = date(fromISO: from), let end = date(fromISO: to) else { return [] }
        let cal = gregorian(newYork)
        var out: [String] = []
        var holidayCache: [Int: Set<String>] = [:]
        while d <= end {
            let s = isoString(d)
            let year = cal.component(.year, from: d)
            let wd = cal.component(.weekday, from: d)   // 1 = Sunday, 7 = Saturday
            let hol = holidayCache[year] ?? holidays(year: year)
            holidayCache[year] = hol
            if wd != 1 && wd != 7 && !hol.contains(s) { out.append(s) }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }

    /// The most recent trading day whose end-of-day data should be published.
    /// Before 6 pm New York time, today's bar is not final yet, so it is excluded.
    public static func latestCompleteTradingDay(now: Date = Date()) -> String {
        let cal = gregorian(newYork)
        let hour = cal.component(.hour, from: now)
        var d = hour >= 18 ? now : cal.date(byAdding: .day, value: -1, to: now)!
        for _ in 0..<10 {
            let s = isoString(d)
            if tradingDays(from: s, to: s).count == 1 { return s }
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }
        return isoString(d)
    }

    public static func adding(days: Int, to iso: String) -> String {
        guard let d = date(fromISO: iso) else { return iso }
        return isoString(gregorian(newYork).date(byAdding: .day, value: days, to: d)!)
    }

    // MARK: NYSE holiday rules

    public static func holidays(year y: Int) -> Set<String> {
        let cal = gregorian(newYork)
        func ymd(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
        func s(_ d: Date) -> String { isoString(d) }
        func observed(_ m: Int, _ d: Int) -> Date {
            let date = ymd(m, d)
            switch cal.component(.weekday, from: date) {
            case 7: return cal.date(byAdding: .day, value: -1, to: date)!   // Saturday → Friday
            case 1: return cal.date(byAdding: .day, value: 1, to: date)!    // Sunday → Monday
            default: return date
            }
        }
        /// n-th given weekday of a month (n = -1 for last).
        func nth(_ n: Int, weekday: Int, month: Int) -> Date {
            if n > 0 {
                var d = ymd(month, 1)
                while cal.component(.weekday, from: d) != weekday { d = cal.date(byAdding: .day, value: 1, to: d)! }
                return cal.date(byAdding: .day, value: 7 * (n - 1), to: d)!
            }
            var d = cal.date(byAdding: .day, value: -1, to: ymd(month + 1 > 12 ? 1 : month + 1, 1))!
            if month == 12 { d = ymd(12, 31) }
            while cal.component(.weekday, from: d) != weekday { d = cal.date(byAdding: .day, value: -1, to: d)! }
            return d
        }

        var out: Set<String> = []
        // New Year's Day: NYSE does not observe it on the prior Friday when Jan 1 is a Saturday.
        let ny = ymd(1, 1)
        if cal.component(.weekday, from: ny) != 7 { out.insert(s(observed(1, 1))) }
        out.insert(s(nth(3, weekday: 2, month: 1)))     // MLK Day
        out.insert(s(nth(3, weekday: 2, month: 2)))     // Washington's Birthday
        out.insert(s(cal.date(byAdding: .day, value: -2, to: easter(y))!)) // Good Friday
        out.insert(s(nth(-1, weekday: 2, month: 5)))    // Memorial Day
        if y >= 2022 { out.insert(s(observed(6, 19))) } // Juneteenth
        out.insert(s(observed(7, 4)))                   // Independence Day
        out.insert(s(nth(1, weekday: 2, month: 9)))     // Labor Day
        out.insert(s(nth(4, weekday: 5, month: 11)))    // Thanksgiving
        out.insert(s(observed(12, 25)))                 // Christmas
        return out
    }

    /// Western Easter Sunday (anonymous Gregorian algorithm).
    static func easter(_ y: Int) -> Date {
        let a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return gregorian(newYork).date(from: DateComponents(year: y, month: month, day: day, hour: 12))!
    }
}
