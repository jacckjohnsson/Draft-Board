import Foundation
import Observation
import FactorEngine
import FactorData

/// Correlations, clusters, sector mix and warnings for the saved basket.
/// Uses Massive daily returns only (the live price source).
struct SectorShare: Sendable, Hashable, Identifiable {
    var id: String { sector }
    let sector: String
    let share: Double
}

struct WatchlistAnalysis: Sendable {
    /// Tickers in heatmap order (clustered stocks next to each other).
    var ordered: [String]
    /// correlation[i][j] for `ordered`.
    var correlation: [[Double]]
    var clusters: [[String]]
    var sectorShares: [SectorShare]
    var warnings: [BasketWarning]
    /// Tickers without enough overlapping price history to correlate.
    var insufficientHistory: [String]

    static let minimumOverlap = 60

    static func compute(tickers: [String], dataset: LiveDataset) -> WatchlistAnalysis {
        let window = dataset.panel.suffix(Returns.tradingDaysPerYear + 1)
        var returns: [String: [Double]] = [:]
        var short: [String] = []
        for t in tickers {
            let r = Returns.simpleReturns(window.closes[t] ?? [])
            if r.filter({ !$0.isNaN }).count >= minimumOverlap { returns[t] = r } else { short.append(t) }
        }
        let usable = tickers.filter { returns[$0] != nil }
        let matrix = Stats.correlationMatrix(usable.map { returns[$0]! })
        let clustering = Clustering.hierarchical(correlation: matrix, threshold: 0.5)
        let order = Clustering.seriation(clustering)
        let ordered = order.map { usable[$0] }
        let reordered = order.map { i in order.map { j in matrix[i][j] } }
        let sectors = Dictionary(tickers.map { ($0, dataset.sector($0)) }, uniquingKeysWith: { a, _ in a })
        let shares = BasketDiagnostics.sectorShares(tickers: tickers, sectors: sectors)
            .sorted { $0.value > $1.value }
            .map { SectorShare(sector: $0.key, share: $0.value) }
        // Sector concentration counts every ticker, including those without enough price history.
        let warnings = BasketDiagnostics.correlationWarnings(tickers: ordered, correlation: reordered)
            + BasketDiagnostics.sectorWarnings(tickers: tickers, sectors: sectors)
        return WatchlistAnalysis(
            ordered: ordered,
            correlation: reordered,
            clusters: clustering.clusters.map { $0.map { usable[$0] } },
            sectorShares: shares,
            warnings: warnings,
            insufficientHistory: short
        )
    }
}

@Observable
@MainActor
final class WatchlistModel {
    private(set) var analysis: WatchlistAnalysis?
    private(set) var isComputing = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var key: String?

    func update(tickers: [String], dataset: LiveDataset, version: Int) {
        let k = "\(version)|" + tickers.joined(separator: ",")
        guard k != key else { return }
        key = k
        task?.cancel()
        isComputing = true
        task = Task { [weak self] in
            let a = await Task.detached(priority: .userInitiated) {
                WatchlistAnalysis.compute(tickers: tickers, dataset: dataset)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.analysis = a
            self.isComputing = false
        }
    }
}
