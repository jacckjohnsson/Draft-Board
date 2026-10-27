import Foundation
import Observation
import FactorEngine
import FactorData

/// Runs the price-only quintile backtest on Yahoo history. Never touches Massive data.
@Observable
@MainActor
final class BacktestModel {
    enum State: Equatable {
        case idle
        case downloading
        case running(Double)
        case done
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var result: BacktestResult?
    private(set) var resultConfig: BacktestConfig?
    private(set) var tickersUsed = 0
    private(set) var historyFailures: [String: String] = [:]
    private(set) var fromCache = false

    func run(coordinator: DataCoordinator) async {
        guard state != .downloading, !isRunning else { return }
        state = .downloading
        await coordinator.syncHistory()

        let settings = coordinator.settings
        let config = BacktestConfig(weights: settings.weights, lookbackYears: settings.backtestYears,
                                    neutralization: settings.neutralization, benchmark: Universe.benchmark)
        let members = coordinator.universeMembers()
        let sectors = Dictionary(members.map { ($0.ticker, $0.sector) }, uniquingKeysWith: { a, _ in a })
        let tickers = Set(members.map(\.ticker)).union([Universe.benchmark])
        let store = coordinator.store

        do {
            let histories = try await store.histories(tickers: tickers)
            historyFailures = (try? await store.historyFailures()) ?? [:]
            guard let spy = histories[Universe.benchmark] else {
                state = .failed(historyFailures[Universe.benchmark].map { "Couldn't download SPY history from Yahoo Finance: \($0)" }
                                ?? "SPY history from Yahoo Finance isn't available yet.")
                return
            }
            // Cache key: parameters + universe + which data it ran on.
            let stamp = histories.values.map(\.fetchedAt).max().map { String(Int($0.timeIntervalSince1970 / 86_400)) } ?? "0"
            let key = "\(config.cacheKey)|u=\(settings.universe.rawValue)|n=\(histories.count)|d=\(stamp)"
            if let cached = await store.cachedBacktest(key: key) {
                result = cached
                resultConfig = config
                tickersUsed = histories.count - 1
                fromCache = true
                state = .done
                return
            }

            state = .running(0)
            let calendar = spy.dates
            let series = histories.mapValues(\.adjustedByDate)
            let progressSink = ProgressSink(model: self)
            let r = try await Task.detached(priority: .userInitiated) {
                let panel = PricePanel.aligned(calendar: calendar, series: series)
                return try BacktestEngine.run(panel: panel, sectors: sectors, config: config) { f in
                    progressSink.report(f)
                }
            }.value
            try? await store.storeBacktest(r, key: key)
            result = r
            resultConfig = config
            tickersUsed = histories.count - 1
            fromCache = false
            state = .done
        } catch BacktestError.insufficientHistory(let months) {
            state = .failed("Only \(months) months of usable history. The backtest needs at least 14 months (12 to warm up plus 2 to trade).")
        } catch BacktestError.noPriceFactorsWeighted {
            state = .failed("The backtest uses only momentum and low volatility. Give at least one of them a weight above 0%.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    fileprivate func setProgress(_ f: Double) {
        if case .running = state { state = .running(f) }
    }
}

/// Forwards progress from the background backtest to the main actor, throttled to 1% steps.
private final class ProgressSink: @unchecked Sendable {
    weak var model: BacktestModel?
    private var last = -1.0
    private let lock = NSLock()
    init(model: BacktestModel) { self.model = model }
    func report(_ f: Double) {
        let send: Bool = lock.withLock {
            guard f - last >= 0.01 || f >= 1 else { return false }
            last = f
            return true
        }
        guard send else { return }
        let target = model
        Task { @MainActor in target?.setProgress(f) }
    }
}
