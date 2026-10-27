import Foundation

// Each data source sits behind a protocol so it can be swapped (or mocked in tests).

/// Live prices (Massive). Used by Screener, Stock Detail, Watchlist and Export.
public protocol PriceProvider: Sendable {
    var sourceName: String { get }
    /// All US stocks for one trading day, unadjusted. Returns nil for a market holiday
    /// (the provider answered with no results).
    func dailyBars(for date: String) async throws -> DailyBars?
    /// Split events executed on or after `since`.
    func splits(since: String) async throws -> [SplitEvent]
    /// Unadjusted daily closes for one ticker over [from, to]. Only used to backfill a
    /// custom ticker that wasn't tracked when the grouped days were downloaded.
    func tickerHistory(_ ticker: String, from: String, to: String) async throws -> [String: Double]
}

/// Long history (Yahoo). Used by the Backtest tab only.
public protocol HistoryProvider: Sendable {
    var sourceName: String { get }
    func history(for ticker: String) async throws -> HistorySeries
}

/// Company fundamentals (FMP).
public protocol FundamentalsProvider: Sendable {
    var sourceName: String { get }
    func fundamentals(for ticker: String) async throws -> Fundamentals
}

public enum ProviderError: Error, Equatable, Sendable {
    case missingAPIKey(provider: String)
    case emptyResponse(String)
}

/// Applies split events to unadjusted closes.
public enum SplitAdjuster {
    /// Adjusted close on `date` = raw close × Π priceFactor of every split for the ticker
    /// whose execution date is after `date`.
    public static func adjust(series: [String: Double], splits: [SplitEvent]) -> [String: Double] {
        let sorted = splits.sorted { $0.executionDate < $1.executionDate }
        guard !sorted.isEmpty else { return series }
        var out: [String: Double] = [:]
        out.reserveCapacity(series.count)
        for (d, p) in series {
            var f = 1.0
            for s in sorted where s.executionDate > d { f *= s.priceFactor }
            out[d] = p * f
        }
        return out
    }
}
