import XCTest
@testable import FactorData

actor MemoryStore: PriceStore, FundamentalsStore, HistoryStore {
    var days: [String: DailyBars] = [:]
    var closed: Set<String> = []
    var splits: [SplitEvent] = []
    var meta: [String: String] = [:]
    var fundamentals: [String: Fundamentals] = [:]
    var fundRecords: [String: FetchRecord] = [:]
    var history: [String: HistorySeries] = [:]
    var histRecords: [String: FetchRecord] = [:]

    func handledPriceDates() async throws -> Set<String> { Set(days.keys).union(closed) }
    func savePriceDay(_ bars: DailyBars) async throws { days[bars.date] = bars }
    func markMarketClosed(_ date: String) async throws { closed.insert(date) }
    func mergeTickerCloses(_ ticker: String, closes: [String: Double]) async throws {
        for (d, c) in closes { days[d, default: DailyBars(date: d, closes: [:])].closes[ticker] = c }
    }
    func closeCounts(tickers: Set<String>, from: String) async throws -> [String: Int] {
        var out: [String: Int] = [:]
        for (d, bars) in days where d >= from {
            for t in tickers where bars.closes[t] != nil { out[t, default: 0] += 1 }
        }
        return out
    }
    func replaceSplits(_ s: [SplitEvent]) async throws { splits = s }
    func metadata(_ key: String) async -> String? { meta[key] }
    func setMetadata(_ key: String, _ value: String?) async { meta[key] = value }

    func fundamentalsFetchRecords() async throws -> [String: FetchRecord] { fundRecords }
    func saveFundamentals(_ f: Fundamentals) async throws { fundamentals[f.ticker] = f; fundRecords[f.ticker] = FetchRecord(date: f.fetchedAt, failed: false) }
    func recordFundamentalsFailure(_ t: String, message: String, at: Date) async throws { fundRecords[t] = FetchRecord(date: at, failed: true) }

    func historyFetchRecords() async throws -> [String: FetchRecord] { histRecords }
    func saveHistory(_ h: HistorySeries) async throws { history[h.ticker] = h; histRecords[h.ticker] = FetchRecord(date: h.fetchedAt, failed: false) }
    func recordHistoryFailure(_ t: String, message: String, at: Date) async throws { histRecords[t] = FetchRecord(date: at, failed: true) }
}

struct FakePrices: PriceProvider {
    let sourceName = "Fake"
    let calls: CallCounter
    var tickerCalls = CallCounter()
    var emptyDates: Set<String> = []
    var failAfter: Int? = nil
    func dailyBars(for date: String) async throws -> DailyBars? {
        let n = await calls.increment()
        if let failAfter, n > failAfter { throw CancellationError() }
        if emptyDates.contains(date) { return nil }
        var closes: [String: Double] = ["AAA": 10, "SPY": 400, "JUNK": 1]
        for i in 0..<400 { closes["T\(i)"] = 20 }
        return DailyBars(date: date, closes: closes)
    }
    func splits(since: String) async throws -> [SplitEvent] {
        [SplitEvent(id: "s", ticker: "AAA", executionDate: since, splitFrom: 1, splitTo: 2)]
    }
    func tickerHistory(_ ticker: String, from: String, to: String) async throws -> [String: Double] {
        _ = await tickerCalls.increment()
        return Dictionary(uniqueKeysWithValues: TradingCalendar.tradingDays(from: from, to: to).map { ($0, 5.0) })
    }
}

actor CallCounter {
    var n = 0
    func increment() -> Int { n += 1; return n }
}

actor ProgressLog {
    var events: [SyncProgress] = []
    func add(_ p: SyncProgress) { events.append(p) }
}

struct FakeFundamentals: FundamentalsProvider {
    let sourceName = "FakeFMP"
    let scheduler: RequestScheduler
    func fundamentals(for ticker: String) async throws -> Fundamentals {
        try await scheduler.run {
            if ticker == "NOPE" { throw HTTPError.notFound }
            return Fundamentals(ticker: ticker, peRatio: 10)
        }
    }
}

final class SyncTests: XCTestCase {
    // Wednesday 2024-07-10, 8 pm New York.
    let now = Date(timeIntervalSince1970: 1_720_656_000)

    func testCalendarSkipsWeekendsAndHolidays() {
        let d = TradingCalendar.tradingDays(from: "2024-07-01", to: "2024-07-08")
        XCTAssertEqual(d, ["2024-07-01", "2024-07-02", "2024-07-03", "2024-07-05", "2024-07-08"])
        let h = TradingCalendar.holidays(year: 2024)
        XCTAssertTrue(h.contains("2024-03-29"))   // Good Friday
        XCTAssertTrue(h.contains("2024-05-27"))   // Memorial Day
        XCTAssertTrue(h.contains("2024-11-28"))   // Thanksgiving
        XCTAssertTrue(h.contains("2024-01-15"))   // MLK
        XCTAssertTrue(TradingCalendar.holidays(year: 2022).contains("2022-06-20"))  // Juneteenth observed
        XCTAssertFalse(TradingCalendar.holidays(year: 2022).contains("2021-12-31")) // NYSE skips Sat Jan 1 observance
        XCTAssertEqual(TradingCalendar.tradingDays(from: "2024-01-01", to: "2024-12-31").count, 252)
    }

    func testLatestCompleteTradingDay() {
        XCTAssertEqual(TradingCalendar.latestCompleteTradingDay(now: now), "2024-07-10")
        // 10 am the same day → previous session.
        XCTAssertEqual(TradingCalendar.latestCompleteTradingDay(now: now.addingTimeInterval(-10 * 3600)), "2024-07-09")
        // Saturday → Friday.
        XCTAssertEqual(TradingCalendar.latestCompleteTradingDay(now: now.addingTimeInterval(3 * 86_400)), "2024-07-12")
    }

    /// A universe bigger than the number of missing days, so grouped days are cheaper.
    let bigUniverse: Set<String> = Set((0..<400).map { "T\($0)" }).union(["AAA", "SPY"])

    func testFreshInstallWithSmallUniverseDownloadsPerTicker() async throws {
        let store = MemoryStore()
        let fixedNow = now
        let prices = FakePrices(calls: CallCounter())
        let sync = PriceSync(provider: prices, store: store, now: { fixedNow })
        let plan = try await sync.plan(universe: ["AAA", "SPY"])
        XCTAssertEqual(plan.perTicker, ["AAA", "SPY"])
        XCTAssertFalse(plan.groupedFirst)
        let log = ProgressLog()
        let r = await sync.run(tracked: ["AAA", "SPY"], universe: ["AAA", "SPY"], progress: { await log.add($0) })
        XCTAssertEqual(r.phase, .finished)
        let tickerCalls = await prices.tickerCalls.n
        let dayCalls = await prices.calls.n
        XCTAssertEqual(tickerCalls, 2)
        XCTAssertEqual(dayCalls, 0, "per-ticker data already covers every day")
        let days = await store.days
        XCTAssertGreaterThan(days.count, 270)
        XCTAssertEqual(days["2024-07-10"]?.closes["AAA"], 5)
        let events = await log.events
        XCTAssertEqual(events.last?.completed, events.last?.total)
        XCTAssertEqual(events.last?.total, 3, "2 tickers + splits")
    }

    func testBigUniverseUsesGroupedDaysAndResumes() async throws {
        let store = MemoryStore()
        let fixedNow = now
        // First run is interrupted after 10 days.
        let interrupted = PriceSync(provider: FakePrices(calls: CallCounter(), failAfter: 10), store: store, now: { fixedNow })
        let all = try await interrupted.missingDates()
        XCTAssertGreaterThan(all.count, 270)
        XCTAssertEqual(all.first, "2024-07-10", "newest first")
        let plan = try await interrupted.plan(universe: bigUniverse)
        XCTAssertTrue(plan.groupedFirst)
        XCTAssertEqual(plan.perTicker, [])
        let r1 = await interrupted.run(tracked: bigUniverse, universe: bigUniverse, progress: { _ in })
        XCTAssertEqual(r1.phase, .idle)
        let afterFirst = await store.days.count
        XCTAssertEqual(afterFirst, 10)

        // Relaunch: picks up where it stopped, never re-downloading stored days.
        let prices = FakePrices(calls: CallCounter())
        let log = ProgressLog()
        let resumed = PriceSync(provider: prices, store: store, now: { fixedNow })
        let r2 = await resumed.run(tracked: bigUniverse, universe: bigUniverse, progress: { await log.add($0) })
        XCTAssertEqual(r2.phase, .finished)
        let dayCalls = await prices.calls.n
        let tickerCalls = await prices.tickerCalls.n
        XCTAssertEqual(dayCalls, all.count - 10)
        XCTAssertEqual(tickerCalls, 0)
        let days = await store.days
        XCTAssertEqual(days.count, all.count)
        XCTAssertNil(days["2024-07-10"]?.closes["JUNK"], "untracked tickers are dropped")
        XCTAssertEqual(days["2024-07-10"]?.closes.count, bigUniverse.count)
        let splits = await store.splits
        XCTAssertEqual(splits.count, 1)
        let events = await log.events
        XCTAssertTrue(events.contains { $0.completed == 5 && $0.isRunning }, "reports X of N while running")

        // Same day again: nothing to do, splits already refreshed today.
        let idle = FakePrices(calls: CallCounter())
        let r3 = await PriceSync(provider: idle, store: store, now: { fixedNow }).run(tracked: bigUniverse, universe: bigUniverse, progress: { _ in })
        XCTAssertEqual(r3.detail, "Up to date")
        let idleCalls = await idle.calls.n
        let idleTickerCalls = await idle.tickerCalls.n
        XCTAssertEqual(idleCalls, 0)
        XCTAssertEqual(idleTickerCalls, 0)
    }

    func testDailyUpdateIsOneGroupedCall() async throws {
        let store = MemoryStore()
        let fixedNow = now
        _ = await PriceSync(provider: FakePrices(calls: CallCounter()), store: store, now: { fixedNow })
            .run(tracked: ["AAA", "SPY"], universe: ["AAA", "SPY"], progress: { _ in })
        // Next evening (Thursday 2024-07-11, 8 pm New York).
        let tomorrow = fixedNow.addingTimeInterval(86_400)
        let prices = FakePrices(calls: CallCounter())
        let r = await PriceSync(provider: prices, store: store, now: { tomorrow })
            .run(tracked: ["AAA", "SPY"], universe: ["AAA", "SPY"], progress: { _ in })
        XCTAssertEqual(r.phase, .finished)
        let dayCalls = await prices.calls.n
        let tickerCalls = await prices.tickerCalls.n
        XCTAssertEqual(dayCalls, 1)
        XCTAssertEqual(tickerCalls, 0)
    }

    func testNewTickerWithGapsGetsOneRequest() async throws {
        let store = MemoryStore()
        let fixedNow = now
        _ = await PriceSync(provider: FakePrices(calls: CallCounter()), store: store, now: { fixedNow })
            .run(tracked: bigUniverse, universe: bigUniverse, progress: { _ in })
        // ZZZ was never in the grouped downloads, and every day is already stored.
        let prices = FakePrices(calls: CallCounter())
        let sync = PriceSync(provider: prices, store: store, now: { fixedNow })
        let plan = try await sync.plan(universe: ["AAA", "SPY", "ZZZ"])
        XCTAssertEqual(plan.perTicker, ["ZZZ"])
        _ = await sync.run(tracked: ["AAA", "SPY", "ZZZ"], universe: ["AAA", "SPY", "ZZZ"], progress: { _ in })
        let tickerCalls = await prices.tickerCalls.n
        XCTAssertEqual(tickerCalls, 1)
        let z = await store.days["2024-07-10"]?.closes["ZZZ"]
        XCTAssertEqual(z, 5)
        // Marked as backfilled, so it is not requested again.
        let again = try await sync.plan(universe: ["AAA", "SPY", "ZZZ"])
        XCTAssertEqual(again.perTicker, [])
    }

    func testEmptyRecentDayIsRetriedButOldEmptyDayIsMarkedClosed() async throws {
        let store = MemoryStore()
        let fixedNow = now
        let p = FakePrices(calls: CallCounter(), emptyDates: ["2024-07-10", "2024-06-03"])
        _ = await PriceSync(provider: p, store: store, now: { fixedNow }).run(tracked: bigUniverse, universe: bigUniverse, progress: { _ in })
        let closed = await store.closed
        XCTAssertEqual(closed, ["2024-06-03"])
        let missing = try await PriceSync(provider: p, store: store, now: { fixedNow }).missingDates()
        XCTAssertEqual(missing, ["2024-07-10"])
    }

    func testFundamentalsSyncSkipsFreshAndPausesAtDailyQuota() async throws {
        let store = MemoryStore()
        let clock = TestClock()
        let usage = MemoryUsage()
        let sched = RequestScheduler(name: "fmp", config: .init(callsPerMinute: 100, dailyLimit: 3), clock: clock, usage: usage)
        let fixedNow = now
        try await store.saveFundamentals(Fundamentals(ticker: "FRESH", fetchedAt: fixedNow.addingTimeInterval(-86_400)))
        let sync = FundamentalsSync(provider: FakeFundamentals(scheduler: sched), store: store, now: { fixedNow })
        let r = await sync.run(tickers: ["FRESH", "A", "NOPE", "B", "C"], progress: { _ in })
        guard case .pausedForQuota = r.phase else { return XCTFail("expected quota pause, got \(r.phase)") }
        XCTAssertEqual(r.total, 4)
        XCTAssertEqual(r.completed, 3)
        XCTAssertEqual(r.failures.keys.sorted(), ["NOPE"])
        let saved = await store.fundamentals.keys.sorted()
        XCTAssertEqual(saved, ["A", "B", "FRESH"])

        // Next day: only C remains (NOPE failed today, so it waits a day before retrying).
        clock.day = "2026-10-28"
        let r2 = await sync.run(tickers: ["FRESH", "A", "NOPE", "B", "C"], progress: { _ in })
        XCTAssertEqual(r2.phase, .finished)
        XCTAssertEqual(r2.total, 1)
    }

    func testHistorySyncStopsAfterRepeatedFailuresWithoutThrowing() async {
        struct Broken: HistoryProvider {
            let sourceName = "Yahoo"
            func history(for ticker: String) async throws -> HistorySeries { throw HTTPError.server(status: 503) }
        }
        let store = MemoryStore()
        let r = await HistorySync(provider: Broken(), store: store).run(tickers: (0..<20).map { "T\($0)" }, progress: { _ in })
        guard case .failed(let msg) = r.phase else { return XCTFail() }
        XCTAssertTrue(msg.contains("Backtest"))
        XCTAssertEqual(r.failures.count, 10)
    }

    func testFetchRecordStaleness() {
        let n = Date()
        XCTAssertFalse(FetchRecord(date: n.addingTimeInterval(-2 * 86_400), failed: false).isStale(maxAge: Freshness.fundamentalsMaxAge, now: n))
        XCTAssertTrue(FetchRecord(date: n.addingTimeInterval(-2 * 86_400), failed: true).isStale(maxAge: Freshness.fundamentalsMaxAge, now: n))
        XCTAssertTrue(FetchRecord(date: n.addingTimeInterval(-31 * 86_400), failed: false).isStale(maxAge: Freshness.historyMaxAge, now: n))
    }
}
