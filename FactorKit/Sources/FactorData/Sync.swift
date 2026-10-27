import Foundation

/// Progress of one sync job, for the "X of N loaded" UI.
public struct SyncProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case running
        /// Stopped by a daily quota; resumes automatically on the next run after reset.
        case pausedForQuota(String)
        case finished
        case failed(String)
    }
    public var source: String
    public var completed: Int
    public var total: Int
    public var phase: Phase
    public var detail: String
    public var failures: [String: String]

    public init(source: String, completed: Int = 0, total: Int = 0, phase: Phase = .idle,
                detail: String = "", failures: [String: String] = [:]) {
        self.source = source; self.completed = completed; self.total = total
        self.phase = phase; self.detail = detail; self.failures = failures
    }

    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : (phase == .finished ? 1 : 0) }
    public var isRunning: Bool { phase == .running }
}

public typealias ProgressHandler = @Sendable (SyncProgress) async -> Void

// MARK: - Storage protocols (implemented with SwiftData in the app, in memory in tests)

public protocol PriceStore: Sendable {
    /// Every date already handled, including known market closures.
    func handledPriceDates() async throws -> Set<String>
    func savePriceDay(_ bars: DailyBars) async throws
    func markMarketClosed(_ date: String) async throws
    /// Merges one ticker's closes into the stored days, creating any day that doesn't exist yet.
    func mergeTickerCloses(_ ticker: String, closes: [String: Double]) async throws
    /// For each ticker, how many stored trading days on or after `from` have a close for it.
    func closeCounts(tickers: Set<String>, from: String) async throws -> [String: Int]
    func replaceSplits(_ splits: [SplitEvent]) async throws
    func metadata(_ key: String) async -> String?
    func setMetadata(_ key: String, _ value: String?) async
}

/// When a ticker was last fetched, and whether that attempt failed.
public struct FetchRecord: Sendable, Equatable {
    public var date: Date
    public var failed: Bool
    public init(date: Date, failed: Bool) { self.date = date; self.failed = failed }

    /// Successes expire after `maxAge`; failures are retried after a day.
    public func isStale(maxAge: TimeInterval, now: Date) -> Bool {
        Freshness.stale(date, maxAge: failed ? min(maxAge, Freshness.failureRetryAfter) : maxAge, now: now)
    }
}

public protocol FundamentalsStore: Sendable {
    func fundamentalsFetchRecords() async throws -> [String: FetchRecord]
    func saveFundamentals(_ f: Fundamentals) async throws
    func recordFundamentalsFailure(_ ticker: String, message: String, at: Date) async throws
}

public protocol HistoryStore: Sendable {
    func historyFetchRecords() async throws -> [String: FetchRecord]
    func saveHistory(_ h: HistorySeries) async throws
    func recordHistoryFailure(_ ticker: String, message: String, at: Date) async throws
}

// MARK: - Freshness policy

public enum Freshness {
    /// ~13 months of trading days for 12-1 momentum and 1y vol/beta.
    public static let priceWindowCalendarDays = 400
    public static let fundamentalsMaxAge: TimeInterval = 7 * 86_400
    public static let historyMaxAge: TimeInterval = 30 * 86_400
    /// After a failure, wait this long before retrying a ticker.
    public static let failureRetryAfter: TimeInterval = 86_400
    /// An empty grouped response this recent might just be "not published yet".
    public static let closureConfirmationDays = 3

    public static func stale(_ fetched: Date?, maxAge: TimeInterval, now: Date) -> Bool {
        guard let fetched else { return true }
        return now.timeIntervalSince(fetched) > maxAge
    }
}

// MARK: - Price sync (Massive)

public struct PriceSync: Sendable {
    let provider: PriceProvider
    let store: PriceStore
    let now: @Sendable () -> Date

    public init(provider: PriceProvider, store: PriceStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.store = store
        self.now = now
    }

    /// Dates in the live window that still need downloading, newest first so the most
    /// recent prices show up quickly.
    public func missingDates() async throws -> [String] {
        let end = TradingCalendar.latestCompleteTradingDay(now: now())
        let start = TradingCalendar.adding(days: -Freshness.priceWindowCalendarDays, to: end)
        let handled = try await store.handledPriceDates()
        return TradingCalendar.tradingDays(from: start, to: end).filter { !handled.contains($0) }.reversed()
    }

    /// A ticker counts as covered when it has closes on at least this share of the window's trading days.
    static let coverageThreshold = 0.9

    /// How a sync run will fetch what's missing.
    public struct Plan: Sendable, Equatable {
        /// Tickers to download one request each, over the whole window.
        public var perTicker: [String]
        /// Whether grouped days come before the per-ticker requests.
        public var groupedFirst: Bool
        public var missingDays: Int
    }

    /// Chooses the cheaper of two strategies, counting API calls:
    ///  - per ticker first: one request per under-covered ticker, then grouped calls for any
    ///    days still missing (usually none). Best for a fresh install with a small universe.
    ///  - grouped first: one request per missing day, which fills every tracked ticker, then
    ///    per-ticker requests only for tickers with gaps inside already-stored days. Best for
    ///    daily updates and big universes.
    public func plan(universe: Set<String>) async throws -> Plan {
        let (start, end) = window()
        let missing = try await missingDates()
        let expected = Double(TradingCalendar.tradingDays(from: start, to: end).count)
        let needed = expected * Self.coverageThreshold
        let counts = try await store.closeCounts(tickers: universe, from: start)
        var needing: [String] = []
        for t in universe.sorted() where Double(counts[t] ?? 0) < needed {
            if await store.metadata("backfilled.\(t)") == nil { needing.append(t) }
        }
        let gap = needing.filter { Double((counts[$0] ?? 0) + missing.count) < needed }
        if needing.count < missing.count + gap.count {
            return Plan(perTicker: needing, groupedFirst: false, missingDays: missing.count)
        }
        return Plan(perTicker: gap, groupedFirst: true, missingDays: missing.count)
    }

    private func window() -> (start: String, end: String) {
        let end = TradingCalendar.latestCompleteTradingDay(now: now())
        return (TradingCalendar.adding(days: -Freshness.priceWindowCalendarDays, to: end), end)
    }

    /// Fills the live price window for `universe` with as few calls as possible, then
    /// refreshes splits once a day. Grouped days keep every `tracked` ticker. Safe to call
    /// repeatedly: stored data is skipped, so an interrupted run resumes where it stopped.
    public func run(tracked: Set<String>, universe: Set<String>, progress: ProgressHandler) async -> SyncProgress {
        var p = SyncProgress(source: provider.sourceName, phase: .running, detail: "Checking cache…")
        do {
            let plan = try await plan(universe: universe)
            p.total = plan.perTicker.count + plan.missingDays + 1   // + splits refresh
            await progress(p)

            if plan.groupedFirst {
                try await fetchGroupedDays(tracked: tracked, progress: &p, handler: progress)
                try await fetchTickers(plan.perTicker, progress: &p, handler: progress)
            } else {
                try await fetchTickers(plan.perTicker, progress: &p, handler: progress)
                // Per-ticker data usually covers every day; fetch whatever is still missing.
                let before = p.completed
                try await fetchGroupedDays(tracked: tracked, progress: &p, handler: progress)
                p.total = p.total - plan.missingDays + (p.completed - before)
            }

            let today = TradingCalendar.isoString(now())
            if await store.metadata("splits.refreshed") != today {
                p.detail = "Stock splits"
                await progress(p)
                let since = TradingCalendar.adding(days: -Freshness.priceWindowCalendarDays - 30, to: today)
                let splits = try await provider.splits(since: since)
                try await store.replaceSplits(splits)
                await store.setMetadata("splits.refreshed", today)
            }
            p.completed = p.total
            p.phase = .finished
            p.detail = p.total <= 1 ? "Up to date" : "Prices loaded"
        } catch is CancellationError {
            p.phase = .idle
            p.detail = "Paused. Will resume where it left off."
        } catch {
            p.phase = .failed(Self.describe(error))
        }
        await progress(p)
        return p
    }

    /// One grouped call per missing day, newest first.
    private func fetchGroupedDays(tracked: Set<String>, progress p: inout SyncProgress, handler: ProgressHandler) async throws {
        let dates = try await missingDates()
        let today = TradingCalendar.isoString(now())
        let closureCutoff = TradingCalendar.adding(days: -Freshness.closureConfirmationDays, to: today)
        for d in dates {
            try Task.checkCancellation()
            p.detail = "Prices for \(d)"
            await handler(p)
            if let bars = try await provider.dailyBars(for: d) {
                try await store.savePriceDay(bars.filtered(to: tracked))
            } else if d < closureCutoff {
                try await store.markMarketClosed(d)
            }
            p.completed += 1
            await handler(p)
        }
    }

    /// One request per ticker over the whole window. A failing ticker is recorded, not fatal.
    private func fetchTickers(_ tickers: [String], progress p: inout SyncProgress, handler: ProgressHandler) async throws {
        let (start, end) = window()
        for t in tickers {
            try Task.checkCancellation()
            p.detail = "Price history for \(t)"
            await handler(p)
            do {
                let closes = try await provider.tickerHistory(t, from: start, to: end)
                try await store.mergeTickerCloses(t, closes: closes)
                await store.setMetadata("backfilled.\(t)", end)
            } catch let e as ProviderError {
                if case .missingAPIKey = e { throw e }
                p.failures[t] = Self.describe(e)
            } catch let e as HTTPError where e != .unauthorized {
                p.failures[t] = e.userMessage
            }
            p.completed += 1
            await handler(p)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as HTTPError: return e.userMessage
        case let e as SchedulerError:
            switch e {
            case .dailyLimitReached(let l): return "Daily limit of \(l) calls reached."
            case .retriesExhausted(let h): return h.userMessage
            }
        case let e as ProviderError:
            switch e {
            case .missingAPIKey(let p): return "Add your \(p) API key in Settings."
            case .emptyResponse(let m): return m
            }
        default: return error.localizedDescription
        }
    }
}

// MARK: - Fundamentals sync (FMP)

public struct FundamentalsSync: Sendable {
    let provider: FundamentalsProvider
    let store: FundamentalsStore
    let now: @Sendable () -> Date

    public init(provider: FundamentalsProvider, store: FundamentalsStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.store = store
        self.now = now
    }

    public func staleTickers(_ tickers: [String]) async throws -> [String] {
        let records = try await store.fundamentalsFetchRecords()
        return tickers.filter { records[$0]?.isStale(maxAge: Freshness.fundamentalsMaxAge, now: now()) ?? true }
    }

    public func run(tickers: [String], progress: ProgressHandler) async -> SyncProgress {
        var p = SyncProgress(source: provider.sourceName, phase: .running, detail: "Checking cache…")
        do {
            let todo = try await staleTickers(tickers)
            p.total = todo.count
            await progress(p)
            for t in todo {
                try Task.checkCancellation()
                p.detail = "Fundamentals for \(t)"
                await progress(p)
                do {
                    try await store.saveFundamentals(try await provider.fundamentals(for: t))
                } catch let e as SchedulerError {
                    if case .dailyLimitReached = e {
                        p.phase = .pausedForQuota("Daily FMP limit reached. \(p.total - p.completed) tickers will load tomorrow.")
                        await progress(p)
                        return p
                    }
                    throw e
                } catch let e as ProviderError {
                    if case .missingAPIKey = e { throw e }
                    p.failures[t] = PriceSync.describe(e)
                    try await store.recordFundamentalsFailure(t, message: PriceSync.describe(e), at: now())
                } catch let e as HTTPError where e == .unauthorized {
                    throw e
                } catch let e as HTTPError {
                    p.failures[t] = e.userMessage
                    try await store.recordFundamentalsFailure(t, message: e.userMessage, at: now())
                }
                p.completed += 1
                await progress(p)
            }
            p.phase = .finished
            p.detail = todo.isEmpty ? "Up to date" : "Loaded \(todo.count - p.failures.count) of \(todo.count)"
        } catch is CancellationError {
            p.phase = .idle
            p.detail = "Paused. Will resume where it left off."
        } catch {
            p.phase = .failed(PriceSync.describe(error))
        }
        await progress(p)
        return p
    }
}

// MARK: - History sync (Yahoo, backtest only)

public struct HistorySync: Sendable {
    let provider: HistoryProvider
    let store: HistoryStore
    let now: @Sendable () -> Date

    public init(provider: HistoryProvider, store: HistoryStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.store = store
        self.now = now
    }

    public func staleTickers(_ tickers: [String]) async throws -> [String] {
        let records = try await store.historyFetchRecords()
        return tickers.filter { records[$0]?.isStale(maxAge: Freshness.historyMaxAge, now: now()) ?? true }
    }

    /// Failures are per ticker and never abort the run: Yahoo is unofficial, and a broken
    /// endpoint should only degrade the Backtest tab.
    public func run(tickers: [String], progress: ProgressHandler) async -> SyncProgress {
        var p = SyncProgress(source: provider.sourceName, phase: .running, detail: "Checking cache…")
        do {
            let todo = try await staleTickers(tickers)
            p.total = todo.count
            await progress(p)
            var consecutiveFailures = 0
            for t in todo {
                try Task.checkCancellation()
                p.detail = "History for \(t)"
                await progress(p)
                do {
                    try await store.saveHistory(try await provider.history(for: t))
                    consecutiveFailures = 0
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let msg = PriceSync.describe(error)
                    p.failures[t] = msg
                    try await store.recordHistoryFailure(t, message: msg, at: now())
                    consecutiveFailures += 1
                    if consecutiveFailures >= 10 {
                        p.phase = .failed("Yahoo Finance isn't responding (\(msg)). The Backtest tab will use whatever history is cached.")
                        await progress(p)
                        return p
                    }
                }
                p.completed += 1
                await progress(p)
            }
            p.phase = .finished
            p.detail = todo.isEmpty ? "Up to date" : "Loaded \(todo.count - p.failures.count) of \(todo.count)"
        } catch is CancellationError {
            p.phase = .idle
            p.detail = "Paused. Will resume where it left off."
        } catch {
            p.phase = .failed(PriceSync.describe(error))
        }
        await progress(p)
        return p
    }
}
