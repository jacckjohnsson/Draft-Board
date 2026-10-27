import Foundation
import Observation
import FactorEngine
import FactorData

/// Holds the latest scores for the live universe. Shared by Screener, Stock Detail,
/// Watchlist and Export. Rescoring runs on a background task and uses only the cached
/// dataset, so changing weights or filters never touches the network.
@Observable
@MainActor
final class ScoringModel {
    private(set) var result: ScoringResult?
    private(set) var isScoring = false
    private(set) var scoredVersion = -1
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastConfig: ScoringConfig?

    var scoresByTicker: [String: StockScore] {
        Dictionary((result?.scores ?? []).map { ($0.ticker, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func rescore(dataset: LiveDataset, version: Int, config: ScoringConfig) {
        if version == scoredVersion, config == lastConfig { return }
        task?.cancel()
        lastConfig = config
        isScoring = true
        task = Task { [weak self] in
            let r = await Task.detached(priority: .userInitiated) {
                ScoringEngine.score(dataset.inputs(), config: config)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.result = r
            self.scoredVersion = version
            self.isScoring = false
        }
    }

    /// Rows after search and filters. Ranks stay relative to the whole universe.
    func rows(dataset: LiveDataset, filters: ScreenerFilters, search: String) -> [StockScore] {
        guard let scores = result?.scores else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return scores.filter { s in
            if !q.isEmpty && !s.ticker.lowercased().contains(q) && !dataset.name(s.ticker).lowercased().contains(q) { return false }
            return Self.passes(s.ticker, dataset: dataset, filters: filters)
        }
    }

    static func passes(_ t: String, dataset: LiveDataset, filters: ScreenerFilters) -> Bool {
        let f = dataset.fundamentals[t]
        if !filters.sectors.isEmpty && !filters.sectors.contains(dataset.sector(t)) { return false }
        if let min = filters.minMarketCapBillions {
            guard let mc = f?.marketCap, mc >= min * 1e9 else { return false }
        }
        if let max = filters.maxPE {
            guard let pe = f?.peRatio, pe > 0, pe <= max else { return false }
        }
        if let min = filters.minDividendYieldPercent {
            guard let y = f?.dividendYield, y * 100 >= min else { return false }
        }
        if let max = filters.maxBeta {
            guard let b = dataset.beta(t), b <= max else { return false }
        }
        return true
    }
}

/// Which tab is showing; lets empty states jump to Settings.
@Observable
@MainActor
final class Router {
    enum Tab: Hashable { case screener, backtest, watchlist, export, settings }
    var tab: Tab = .screener
}
