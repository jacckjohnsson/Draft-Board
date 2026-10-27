import Foundation

/// Daily closes for many tickers aligned on one shared calendar.
/// `closes[ticker][i]` is the close on `dates[i]`, or NaN if missing.
/// Dates are ISO "yyyy-MM-dd" strings (US/Eastern trading dates), which sort chronologically.
public struct PricePanel: Sendable, Codable, Equatable {
    public var dates: [String]
    public var closes: [String: [Double]]

    public init(dates: [String], closes: [String: [Double]]) {
        self.dates = dates
        self.closes = closes
    }

    public var tickers: [String] { closes.keys.sorted() }

    public func series(_ ticker: String) -> [Double]? { closes[ticker] }

    /// Builds a panel from per-ticker (date → close) maps, aligned on `calendar`
    /// (typically the benchmark's dates).
    public static func aligned(calendar: [String], series: [String: [String: Double]]) -> PricePanel {
        var out: [String: [Double]] = [:]
        for (t, m) in series {
            out[t] = calendar.map { m[$0] ?? .nan }
        }
        return PricePanel(dates: calendar, closes: out)
    }

    /// Indices of the last trading day of each calendar month.
    public var monthEndIndices: [Int] {
        guard !dates.isEmpty else { return [] }
        var idx: [Int] = []
        for i in 0..<dates.count {
            let isLast = i == dates.count - 1 || dates[i].prefix(7) != dates[i + 1].prefix(7)
            if isLast { idx.append(i) }
        }
        return idx
    }

    /// Keeps only the last `count` dates.
    public func suffix(_ count: Int) -> PricePanel {
        let n = min(count, dates.count)
        return PricePanel(dates: Array(dates.suffix(n)), closes: closes.mapValues { Array($0.suffix(n)) })
    }
}

/// Price-based metrics for the live model, from Massive prices only.
public enum PriceMetrics {
    public struct Result: Sendable, Hashable {
        public var momentum12_1: Double
        public var volatility: Double
        public var beta: Double
        public var lastClose: Double
    }

    /// Computes 12-1 momentum, 1y realized vol and 1y beta for every ticker in the
    /// panel against `benchmark` (SPY). Values are NaN when history is too short.
    public static func compute(panel: PricePanel, benchmark: String = "SPY") -> [String: Result] {
        let market = panel.closes[benchmark] ?? [Double](repeating: .nan, count: panel.dates.count)
        var out: [String: Result] = [:]
        for (t, p) in panel.closes {
            // Momentum uses the latest valid price as "today"; trailing NaNs (e.g. a
            // missing last day) are trimmed so one gap doesn't blank the metric.
            var end = p.count
            while end > 0 && p[end - 1].isNaN { end -= 1 }
            let trimmed = Array(p[..<end])
            out[t] = Result(
                momentum12_1: Returns.momentum12_1(trimmed),
                volatility: Returns.realizedVolatility(p),
                beta: t == benchmark ? 1 : Returns.beta(stock: p, market: market),
                lastClose: trimmed.last ?? .nan
            )
        }
        return out
    }
}
