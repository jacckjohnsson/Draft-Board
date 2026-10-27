import Foundation
import FactorEngine
import FactorData

/// Everything the live tabs need, loaded once from the cache. Rescoring after a weight,
/// filter or watchlist change works from this snapshot, never from the network.
struct LiveDataset: Sendable {
    var universeTitle: String
    var members: [UniverseMember]
    /// Split-adjusted Massive closes for the universe plus SPY.
    var panel: PricePanel
    var fundamentals: [String: Fundamentals]
    var priceMetrics: [String: PriceMetrics.Result]
    var fundamentalsFailures: [String: String]
    private let memberByTicker: [String: UniverseMember]

    init(universeTitle: String, members: [UniverseMember], panel: PricePanel,
         fundamentals: [String: Fundamentals], priceMetrics: [String: PriceMetrics.Result],
         fundamentalsFailures: [String: String]) {
        self.universeTitle = universeTitle
        self.members = members
        self.panel = panel
        self.fundamentals = fundamentals
        self.priceMetrics = priceMetrics
        self.fundamentalsFailures = fundamentalsFailures
        self.memberByTicker = Dictionary(members.map { ($0.ticker, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static let empty = LiveDataset(universeTitle: "", members: [], panel: PricePanel(dates: [], closes: [:]),
                                   fundamentals: [:], priceMetrics: [:], fundamentalsFailures: [:])

    var tickers: [String] { members.map(\.ticker) }
    var latestDate: String? { panel.dates.last }
    var tradingDays: Int { panel.dates.count }
    var isEmpty: Bool { panel.dates.isEmpty && fundamentals.isEmpty }

    func member(_ ticker: String) -> UniverseMember? { memberByTicker[ticker] }

    /// GICS sector from the bundled universe, else FMP's sector, else "Unknown".
    func sector(_ ticker: String) -> String {
        if let s = member(ticker)?.sector, !s.isEmpty, s != "Unknown" { return s }
        return fundamentals[ticker]?.sector ?? "Unknown"
    }

    func name(_ ticker: String) -> String {
        member(ticker)?.name ?? fundamentals[ticker]?.name ?? ticker
    }

    func lastClose(_ ticker: String) -> Double? {
        guard let v = priceMetrics[ticker]?.lastClose, v.isFinite else { return nil }
        return v
    }

    /// Effective beta for filtering: Massive-computed, falling back to FMP's.
    func beta(_ ticker: String) -> Double? {
        if let b = priceMetrics[ticker]?.beta, b.isFinite { return b }
        return fundamentals[ticker]?.beta
    }

    func inputs() -> [StockInput] {
        members.map { m in
            var metrics = fundamentals[m.ticker]?.metrics ?? [:]
            if let p = priceMetrics[m.ticker] {
                if p.momentum12_1.isFinite { metrics[.momentum12_1] = p.momentum12_1 }
                if p.volatility.isFinite { metrics[.volatility] = p.volatility }
                if p.beta.isFinite { metrics[.beta] = p.beta }
            }
            return StockInput(ticker: m.ticker, sector: sector(m.ticker), metrics: metrics)
        }
    }

    /// Daily closes for one ticker as (date, close) pairs, skipping gaps.
    func priceSeries(_ ticker: String) -> [(date: String, close: Double)] {
        guard let s = panel.closes[ticker] else { return [] }
        return zip(panel.dates, s).filter { $0.1.isFinite }.map { (date: $0.0, close: $0.1) }
    }
}
