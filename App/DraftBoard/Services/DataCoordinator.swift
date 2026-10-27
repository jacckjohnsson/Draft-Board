import Foundation
import Observation
import SwiftData
import FactorEngine
import FactorData

/// Owns the providers, their request schedulers and the sync jobs, and publishes the
/// cached `LiveDataset` the tabs render from. One instance for the app's lifetime.
@Observable
@MainActor
final class DataCoordinator {
    let settings: AppSettings
    let store: DataStore

    // One scheduler per provider, so each has its own calls-per-minute budget.
    private let massiveScheduler: RequestScheduler
    private let fmpScheduler: RequestScheduler
    private let yahooScheduler: RequestScheduler
    private let massive: MassiveProvider
    private let fmp: FMPProvider
    private let yahoo: YahooHistoryProvider

    var priceProgress = SyncProgress(source: "Massive")
    var fundamentalsProgress = SyncProgress(source: "Financial Modeling Prep")
    var historyProgress = SyncProgress(source: "Yahoo Finance")

    private(set) var dataset: LiveDataset = .empty
    private(set) var isLoadingDataset = false
    private(set) var datasetError: String?
    /// Bumped whenever `dataset` is replaced, so view models know to rescore.
    private(set) var datasetVersion = 0
    private(set) var stats = CacheStats()
    /// Bumped when API keys change (Keychain reads are not observable).
    private(set) var keysVersion = 0

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var lastRebuildCount = 0
    @ObservationIgnored private var refreshQueued = false

    /// Creates the coordinator. The DataStore is built off the main thread: a ModelActor
    /// created on the main thread would run its work there and stall the UI.
    static func make(container: ModelContainer, settings: AppSettings) async -> DataCoordinator {
        let store = await Task.detached { DataStore(modelContainer: container) }.value
        return DataCoordinator(store: store, settings: settings)
    }

    private init(store: DataStore, settings: AppSettings) {
        self.settings = settings
        self.store = store
        let usage = UserDefaultsUsageStore()
        massiveScheduler = RequestScheduler(name: "massive", config: .init(callsPerMinute: settings.massiveCallsPerMinute))
        fmpScheduler = RequestScheduler(name: "fmp", config: .init(callsPerMinute: settings.fmpCallsPerMinute,
                                                                   dailyLimit: settings.fmpDailyLimit), usage: usage)
        yahooScheduler = RequestScheduler(name: "yahoo", config: .init(callsPerMinute: settings.yahooCallsPerMinute, maxRetries: 3))
        massive = MassiveProvider(apiKey: { Keychain.get(.massive) }, scheduler: massiveScheduler)
        fmp = FMPProvider(apiKey: { Keychain.get(.fmp) }, scheduler: fmpScheduler)
        yahoo = YahooHistoryProvider(scheduler: yahooScheduler)
    }

    // MARK: Keys

    var hasMassiveKey: Bool { _ = keysVersion; return Keychain.has(.massive) }
    var hasFMPKey: Bool { _ = keysVersion; return Keychain.has(.fmp) }

    func saveKeys(massive: String, fmp: String) {
        Keychain.set(massive, for: .massive)
        Keychain.set(fmp, for: .fmp)
        keysVersion += 1
        refreshLive()
    }

    // MARK: Universe

    func universeMembers() -> [UniverseMember] {
        switch settings.universe {
        case .custom:
            let dir = UniverseLoader.directory()
            return UniverseLoader.parseCustom(settings.customTickers).map {
                dir[$0] ?? UniverseMember(ticker: $0, name: $0, sector: "Unknown")
            }
        default:
            return (try? UniverseLoader.load(settings.universe).members) ?? []
        }
    }

    /// Tickers kept from each grouped-daily download: every S&P 500 member, custom tickers,
    /// and SPY. Switching between bundled universes then needs no new price downloads.
    var trackedTickers: Set<String> {
        let sp = (try? UniverseLoader.load(.sp500).members.map(\.ticker)) ?? []
        return Set(sp).union(UniverseLoader.parseCustom(settings.customTickers)).union([Universe.benchmark])
    }

    func universeChanged() {
        Task {
            await reloadDataset()
            refreshLive()
        }
    }

    // MARK: Lifecycle

    func start() async {
        await reloadDataset()
        refreshLive()
    }

    var isSyncingLive: Bool { priceProgress.isRunning || fundamentalsProgress.isRunning }

    /// Fetches whatever is missing or stale. Safe to call often; does nothing if already running.
    func refreshLive() {
        guard liveTask == nil else {
            // Something changed mid-sync (e.g. the universe); run again when this pass ends.
            refreshQueued = true
            return
        }
        liveTask = Task {
            await runLiveSync()
            liveTask = nil
            if refreshQueued && !Task.isCancelled {
                refreshQueued = false
                refreshLive()
            }
        }
    }

    func cancelSync() {
        refreshQueued = false
        liveTask?.cancel()
        historyTask?.cancel()
    }

    func applyRateLimits() {
        let m = settings.massiveCallsPerMinute, f = settings.fmpCallsPerMinute
        let fd = settings.fmpDailyLimit, y = settings.yahooCallsPerMinute
        Task {
            await massiveScheduler.update(callsPerMinute: m)
            await fmpScheduler.update(callsPerMinute: f)
            await fmpScheduler.update(dailyLimit: fd)
            await yahooScheduler.update(callsPerMinute: y)
        }
    }

    private func runLiveSync() async {
        applyRateLimits()
        if hasMassiveKey {
            let sync = PriceSync(provider: massive, store: store)
            lastRebuildCount = 0
            let universe = Set(universeMembers().map(\.ticker)).union([Universe.benchmark])
            _ = await sync.run(tracked: trackedTickers, universe: universe) { [weak self] p in
                await self?.handlePriceProgress(p)
            }
        } else {
            priceProgress = SyncProgress(source: massive.sourceName, phase: .failed("Add your Massive API key in Settings to load prices."))
        }
        guard !Task.isCancelled else { return }

        if hasFMPKey {
            let sync = FundamentalsSync(provider: fmp, store: store)
            lastRebuildCount = 0
            _ = await sync.run(tickers: universeMembers().map(\.ticker)) { [weak self] p in
                await self?.handleFundamentalsProgress(p)
            }
        } else {
            fundamentalsProgress = SyncProgress(source: fmp.sourceName, phase: .failed("Add your FMP API key in Settings to load fundamentals."))
        }
        await reloadDataset()
    }

    private func handlePriceProgress(_ p: SyncProgress) async {
        priceProgress = p
        // Show partial results while a long backfill runs.
        if p.completed - lastRebuildCount >= 25 {
            lastRebuildCount = p.completed
            await reloadDataset()
        }
    }

    private func setHistoryProgress(_ p: SyncProgress) { historyProgress = p }

    private func handleFundamentalsProgress(_ p: SyncProgress) async {
        fundamentalsProgress = p
        if p.completed - lastRebuildCount >= 20 {
            lastRebuildCount = p.completed
            await reloadDataset()
        }
    }

    // MARK: Dataset

    func reloadDataset() async {
        isLoadingDataset = true
        defer { isLoadingDataset = false }
        let members = universeMembers()
        let tickers = Set(members.map(\.ticker)).union([Universe.benchmark])
        let store = self.store
        let title = settings.universe.title
        do {
            let ds = try await Task.detached(priority: .userInitiated) {
                let panel = try await store.livePanel(tickers: tickers)
                let fundamentals = try await store.allFundamentals()
                let failures = try await store.fundamentalsFailures()
                let metrics = PriceMetrics.compute(panel: panel, benchmark: Universe.benchmark)
                return LiveDataset(universeTitle: title, members: members, panel: panel,
                                   fundamentals: fundamentals, priceMetrics: metrics,
                                   fundamentalsFailures: failures)
            }.value
            dataset = ds
            datasetError = nil
            datasetVersion += 1
        } catch {
            datasetError = "Couldn't read the local cache: \(error.localizedDescription)"
        }
        await refreshStats()
    }

    func refreshStats() async {
        if let s = try? await store.stats() { stats = s }
    }

    func clearCache() async {
        cancelSync()
        try? await store.clearCache()
        priceProgress = SyncProgress(source: massive.sourceName)
        fundamentalsProgress = SyncProgress(source: fmp.sourceName)
        historyProgress = SyncProgress(source: yahoo.sourceName)
        await reloadDataset()
    }

    // MARK: Backtest history (Yahoo only)

    var isSyncingHistory: Bool { historyProgress.isRunning }

    /// Downloads 10y Yahoo history for the universe + SPY (monthly refresh).
    func syncHistory() async {
        if let historyTask {
            await historyTask.value
            return
        }
        let tickers = [Universe.benchmark] + universeMembers().map(\.ticker)
        let sync = HistorySync(provider: yahoo, store: store)
        // The coordinator lives for the whole app session, so a strong capture is fine here.
        let task = Task {
            _ = await sync.run(tickers: tickers) { [weak self] p in
                await self?.setHistoryProgress(p)
            }
        }
        historyTask = task
        await task.value
        historyTask = nil
        await refreshStats()
    }

    // MARK: Cross-source check

    /// Compares recent Massive closes with Yahoo's split-adjusted (not dividend-adjusted)
    /// closes and returns tickers that differ by more than 1%.
    func consistencyCheck() async -> [ConsistencyCheck.Mismatch] {
        let panel = dataset.panel
        let tickers = Set(dataset.tickers)
        let store = self.store
        return await Task.detached {
            let hist = (try? await store.histories(tickers: tickers)) ?? [:]
            var massive: [String: [String: Double]] = [:]
            let recent = Array(panel.dates.suffix(10))
            for (t, s) in panel.closes where hist[t] != nil {
                var m: [String: Double] = [:]
                for (i, d) in panel.dates.enumerated().suffix(recent.count) where s[i].isFinite { m[d] = s[i] }
                massive[t] = m
            }
            let yahoo = hist.mapValues(\.closesByDate)
            return ConsistencyCheck.compare(primary: massive, secondary: yahoo, days: 5, tolerance: 0.01)
        }.value
    }
}
