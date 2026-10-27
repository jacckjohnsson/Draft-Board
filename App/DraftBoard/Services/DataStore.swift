import Foundation
import SwiftData
import FactorData
import FactorEngine

struct CacheStats: Sendable, Equatable {
    var priceDays = 0
    var oldestPriceDate: String?
    var latestPriceDate: String?
    var latestPriceFetch: Date?
    var fundamentalsCount = 0
    var fundamentalsFailed = 0
    var oldestFundamentalsFetch: Date?
    var newestFundamentalsFetch: Date?
    var historyCount = 0
    var historyFailed = 0
    var latestHistoryFetch: Date?
    var backtestResults = 0
    var bytes = 0
}

/// All cache reads and writes happen on this actor's own context, off the main thread.
/// It implements the FactorData store protocols so the sync jobs can write to it directly.
@ModelActor
actor DataStore: PriceStore, FundamentalsStore, HistoryStore {

    // MARK: PriceStore

    func handledPriceDates() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<PriceDay>()).map(\.date))
    }

    func savePriceDay(_ bars: DailyBars) throws {
        let payload = try CacheCoding.encode(bars.closes)
        let date = bars.date
        if let existing = try modelContext.fetch(FetchDescriptor<PriceDay>(predicate: #Predicate { $0.date == date })).first {
            existing.payload = payload
            existing.isClosed = false
            existing.fetchedAt = .now
        } else {
            modelContext.insert(PriceDay(date: date, isClosed: false, payload: payload))
        }
        try modelContext.save()
    }

    func markMarketClosed(_ date: String) throws {
        let d = date
        if try modelContext.fetch(FetchDescriptor<PriceDay>(predicate: #Predicate { $0.date == d })).isEmpty {
            modelContext.insert(PriceDay(date: date, isClosed: true, payload: nil))
            try modelContext.save()
        }
    }

    func mergeTickerCloses(_ ticker: String, closes: [String: Double]) throws {
        let days = try modelContext.fetch(FetchDescriptor<PriceDay>(predicate: #Predicate { !$0.isClosed }))
        for day in days {
            guard let c = closes[day.date] else { continue }
            var map = (day.payload.flatMap { try? CacheCoding.decode([String: Double].self, from: $0) }) ?? [:]
            map[ticker] = c
            day.payload = try CacheCoding.encode(map)
        }
        try modelContext.save()
    }

    func replaceSplits(_ splits: [SplitEvent]) throws {
        try modelContext.delete(model: SplitRecord.self)
        var seen = Set<String>()
        for s in splits where seen.insert(s.id).inserted {
            modelContext.insert(SplitRecord(s))
        }
        try modelContext.save()
    }

    func metadata(_ key: String) -> String? {
        let k = key
        return try? modelContext.fetch(FetchDescriptor<MetadataRecord>(predicate: #Predicate { $0.key == k })).first?.value
    }

    func setMetadata(_ key: String, _ value: String?) {
        let k = key
        let existing = try? modelContext.fetch(FetchDescriptor<MetadataRecord>(predicate: #Predicate { $0.key == k })).first
        if let value {
            if let existing { existing.value = value } else { modelContext.insert(MetadataRecord(key: key, value: value)) }
        } else if let existing {
            modelContext.delete(existing)
        }
        try? modelContext.save()
    }

    // MARK: FundamentalsStore

    func fundamentalsFetchRecords() throws -> [String: FetchRecord] {
        let rows = try modelContext.fetch(FetchDescriptor<FundamentalsRecord>())
        return Dictionary(rows.map { ($0.ticker, FetchRecord(date: $0.fetchedAt, failed: $0.failed)) }, uniquingKeysWith: { a, _ in a })
    }

    func saveFundamentals(_ f: Fundamentals) throws {
        let payload = try CacheCoding.encode(f)
        try upsertFundamentals(ticker: f.ticker, payload: payload, at: f.fetchedAt, failed: false, message: nil)
    }

    func recordFundamentalsFailure(_ ticker: String, message: String, at: Date) throws {
        // Keep older good data if there is any; only the timestamp and flag change.
        let t = ticker
        if let existing = try modelContext.fetch(FetchDescriptor<FundamentalsRecord>(predicate: #Predicate { $0.ticker == t })).first,
           existing.payload != nil {
            existing.message = message
            try modelContext.save()
            return
        }
        try upsertFundamentals(ticker: ticker, payload: nil, at: at, failed: true, message: message)
    }

    private func upsertFundamentals(ticker: String, payload: Data?, at: Date, failed: Bool, message: String?) throws {
        let t = ticker
        if let existing = try modelContext.fetch(FetchDescriptor<FundamentalsRecord>(predicate: #Predicate { $0.ticker == t })).first {
            existing.payload = payload
            existing.fetchedAt = at
            existing.failed = failed
            existing.message = message
        } else {
            modelContext.insert(FundamentalsRecord(ticker: ticker, payload: payload, fetchedAt: at, failed: failed, message: message))
        }
        try modelContext.save()
    }

    // MARK: HistoryStore

    func historyFetchRecords() throws -> [String: FetchRecord] {
        let rows = try modelContext.fetch(FetchDescriptor<HistoryRecord>())
        return Dictionary(rows.map { ($0.ticker, FetchRecord(date: $0.fetchedAt, failed: $0.failed)) }, uniquingKeysWith: { a, _ in a })
    }

    func saveHistory(_ h: HistorySeries) throws {
        try upsertHistory(ticker: h.ticker, payload: try CacheCoding.encode(h), at: h.fetchedAt, failed: false, message: nil)
    }

    func recordHistoryFailure(_ ticker: String, message: String, at: Date) throws {
        let t = ticker
        if let existing = try modelContext.fetch(FetchDescriptor<HistoryRecord>(predicate: #Predicate { $0.ticker == t })).first,
           existing.payload != nil {
            // Keep the previous download; the backtest can still use it.
            existing.message = message
            try modelContext.save()
            return
        }
        try upsertHistory(ticker: ticker, payload: nil, at: at, failed: true, message: message)
    }

    private func upsertHistory(ticker: String, payload: Data?, at: Date, failed: Bool, message: String?) throws {
        let t = ticker
        if let existing = try modelContext.fetch(FetchDescriptor<HistoryRecord>(predicate: #Predicate { $0.ticker == t })).first {
            existing.payload = payload
            existing.fetchedAt = at
            existing.failed = failed
            existing.message = message
        } else {
            modelContext.insert(HistoryRecord(ticker: ticker, payload: payload, fetchedAt: at, failed: failed, message: message))
        }
        try modelContext.save()
    }

    // MARK: Reads for the UI

    /// Split-adjusted Massive closes for `tickers`, aligned on the stored trading days.
    func livePanel(tickers: Set<String>) throws -> PricePanel {
        var descriptor = FetchDescriptor<PriceDay>(predicate: #Predicate { !$0.isClosed }, sortBy: [SortDescriptor(\.date)])
        descriptor.includePendingChanges = true
        let days = try modelContext.fetch(descriptor)
        var raw: [String: [String: Double]] = [:]
        var calendar: [String] = []
        for day in days {
            guard let p = day.payload, let closes = try? CacheCoding.decode([String: Double].self, from: p) else { continue }
            calendar.append(day.date)
            for t in tickers {
                if let c = closes[t] { raw[t, default: [:]][day.date] = c }
            }
        }
        let splits = try modelContext.fetch(FetchDescriptor<SplitRecord>())
        var byTicker: [String: [SplitEvent]] = [:]
        for s in splits where tickers.contains(s.ticker) {
            byTicker[s.ticker, default: []].append(
                SplitEvent(id: s.splitID, ticker: s.ticker, executionDate: s.executionDate, splitFrom: s.splitFrom, splitTo: s.splitTo))
        }
        var adjusted: [String: [String: Double]] = [:]
        for (t, series) in raw {
            adjusted[t] = SplitAdjuster.adjust(series: series, splits: byTicker[t] ?? [])
        }
        return PricePanel.aligned(calendar: calendar, series: adjusted)
    }

    func allFundamentals() throws -> [String: Fundamentals] {
        let rows = try modelContext.fetch(FetchDescriptor<FundamentalsRecord>())
        var out: [String: Fundamentals] = [:]
        for r in rows {
            if let p = r.payload, let f = try? CacheCoding.decode(Fundamentals.self, from: p) { out[r.ticker] = f }
        }
        return out
    }

    func fundamentalsFailures() throws -> [String: String] {
        let rows = try modelContext.fetch(FetchDescriptor<FundamentalsRecord>(predicate: #Predicate { $0.failed }))
        return Dictionary(rows.map { ($0.ticker, $0.message ?? "Failed") }, uniquingKeysWith: { a, _ in a })
    }

    func histories(tickers: Set<String>) throws -> [String: HistorySeries] {
        let rows = try modelContext.fetch(FetchDescriptor<HistoryRecord>())
        var out: [String: HistorySeries] = [:]
        for r in rows where tickers.contains(r.ticker) {
            if let p = r.payload, let h = try? CacheCoding.decode(HistorySeries.self, from: p) { out[r.ticker] = h }
        }
        return out
    }

    func historyFailures() throws -> [String: String] {
        let rows = try modelContext.fetch(FetchDescriptor<HistoryRecord>(predicate: #Predicate { $0.failed }))
        return Dictionary(rows.map { ($0.ticker, $0.message ?? "Failed") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Backtest cache

    func cachedBacktest(key: String) -> BacktestResult? {
        let k = key
        guard let r = try? modelContext.fetch(FetchDescriptor<BacktestRecord>(predicate: #Predicate { $0.key == k })).first else { return nil }
        return try? CacheCoding.decode(BacktestResult.self, from: r.payload)
    }

    func storeBacktest(_ result: BacktestResult, key: String) throws {
        let payload = try CacheCoding.encode(result)
        let k = key
        if let existing = try modelContext.fetch(FetchDescriptor<BacktestRecord>(predicate: #Predicate { $0.key == k })).first {
            existing.payload = payload
            existing.createdAt = .now
        } else {
            modelContext.insert(BacktestRecord(key: key, payload: payload))
        }
        try modelContext.save()
    }

    // MARK: Maintenance

    func stats() throws -> CacheStats {
        var s = CacheStats()
        let days = try modelContext.fetch(FetchDescriptor<PriceDay>(sortBy: [SortDescriptor(\.date)]))
        let open = days.filter { !$0.isClosed }
        s.priceDays = open.count
        s.oldestPriceDate = open.first?.date
        s.latestPriceDate = open.last?.date
        s.latestPriceFetch = days.map(\.fetchedAt).max()
        s.bytes += days.reduce(0) { $0 + ($1.payload?.count ?? 0) }

        let f = try modelContext.fetch(FetchDescriptor<FundamentalsRecord>())
        s.fundamentalsCount = f.filter { $0.payload != nil }.count
        s.fundamentalsFailed = f.filter(\.failed).count
        let good = f.filter { !$0.failed }.map(\.fetchedAt)
        s.oldestFundamentalsFetch = good.min()
        s.newestFundamentalsFetch = good.max()
        s.bytes += f.reduce(0) { $0 + ($1.payload?.count ?? 0) }

        let h = try modelContext.fetch(FetchDescriptor<HistoryRecord>())
        s.historyCount = h.filter { $0.payload != nil }.count
        s.historyFailed = h.filter(\.failed).count
        s.latestHistoryFetch = h.filter { !$0.failed }.map(\.fetchedAt).max()
        s.bytes += h.reduce(0) { $0 + ($1.payload?.count ?? 0) }

        let b = try modelContext.fetch(FetchDescriptor<BacktestRecord>())
        s.backtestResults = b.count
        s.bytes += b.reduce(0) { $0 + $1.payload.count }
        return s
    }

    /// Deletes all downloaded data. The watchlist is kept.
    func clearCache() throws {
        try modelContext.delete(model: PriceDay.self)
        try modelContext.delete(model: SplitRecord.self)
        try modelContext.delete(model: FundamentalsRecord.self)
        try modelContext.delete(model: HistoryRecord.self)
        try modelContext.delete(model: BacktestRecord.self)
        try modelContext.delete(model: MetadataRecord.self)
        try modelContext.save()
    }
}
