import Foundation

public struct BacktestConfig: Sendable, Hashable, Codable {
    /// Weights for the price-based factors. Non-price factors are ignored.
    public var weights: FactorWeights
    public var lookbackYears: Int
    public var quantiles: Int
    public var neutralization: Neutralization
    public var benchmark: String

    public init(weights: FactorWeights = Preset.balanced.weights, lookbackYears: Int = 10,
                quantiles: Int = 5, neutralization: Neutralization = .crossSectional,
                benchmark: String = "SPY") {
        self.weights = weights
        self.lookbackYears = lookbackYears
        self.quantiles = quantiles
        self.neutralization = neutralization
        self.benchmark = benchmark
    }

    /// Stable key for caching results (weights rounded so slider jitter doesn't miss the cache).
    public var cacheKey: String {
        let w = weights.normalized(restrictedTo: Set(Factor.allCases.filter(\.isPriceBased)))
        let parts = Factor.allCases.filter(\.isPriceBased).map { f in
            "\(f.rawValue)=\(String(format: "%.3f", w[f] ?? 0))"
        }
        return (parts + ["y=\(lookbackYears)", "q=\(quantiles)", "n=\(neutralization.rawValue)", "b=\(benchmark)"])
            .joined(separator: "|")
    }
}

public struct QuantileStats: Sendable, Hashable, Codable {
    public var annualizedReturn: Double
    public var annualizedVolatility: Double
    public var sharpe: Double
    public var maxDrawdown: Double
}

public struct BacktestResult: Sendable, Codable, Equatable {
    /// Month-end date of each holding period's END (yyyy-MM-dd).
    public var periodEnds: [String]
    /// monthlyReturns[q][t], q = 0 is the top-scored quantile.
    public var monthlyReturns: [[Double]]
    public var cumulative: [[Double]]
    /// Top minus bottom quantile, monthly.
    public var spreadReturns: [Double]
    public var spreadCumulative: [Double]
    public var stats: [QuantileStats]
    public var spreadStats: QuantileStats
    /// Spearman rank IC of score vs next-month return, one per rebalance.
    public var informationCoefficients: [Double]
    public var meanIC: Double
    public var months: Int
    public var averageStocksPerRebalance: Double
    /// True when fewer than 36 months were available.
    public var isTooShort: Bool

    public static let minimumMeaningfulMonths = 36
}

public enum BacktestError: Error, Equatable, Sendable {
    case missingBenchmark
    case noPriceFactorsWeighted
    case insufficientHistory(months: Int)
}

/// Assigns items (already sorted best-first) to `q` equal-sized buckets.
/// Bucket of position i (0-based) in a list of n is floor(i * q / n), so sizes differ by at most one.
public enum Quantiles {
    public static func assign(count n: Int, quantiles q: Int) -> [Int] {
        guard n > 0, q > 0 else { return [] }
        return (0..<n).map { min(q - 1, $0 * q / n) }
    }

    /// Groups indices of `scores` into quantile buckets, highest score in bucket 0.
    /// Ties are broken by input order so results are deterministic.
    public static func form(scores: [Double], quantiles q: Int) -> [[Int]] {
        let order = scores.indices.sorted { a, b in
            scores[a] == scores[b] ? a < b : scores[a] > scores[b]
        }
        let labels = assign(count: order.count, quantiles: q)
        var buckets = [[Int]](repeating: [], count: q)
        for (pos, i) in order.enumerated() { buckets[labels[pos]].append(i) }
        return buckets
    }
}

public enum BacktestEngine {

    /// Runs a monthly-rebalanced quantile backtest on price-based factors only.
    ///
    /// At each month-end t (after a 12-month warm-up): compute 12-1 momentum from
    /// month-end prices, 1-year realized vol and beta from daily prices up to t, score
    /// with the configured price-factor weights, form equal-weight quantiles, and hold
    /// for one month (return from month-end t to month-end t+1).
    ///
    /// - Parameters:
    ///   - panel: daily adjusted closes aligned to the benchmark's calendar.
    ///   - sectors: ticker → sector, used only when neutralization is `.sector`.
    ///   - progress: called with a fraction in [0, 1].
    public static func run(panel: PricePanel, sectors: [String: String] = [:],
                           config: BacktestConfig,
                           progress: (@Sendable (Double) -> Void)? = nil) throws -> BacktestResult {
        guard let market = panel.closes[config.benchmark] else { throw BacktestError.missingBenchmark }
        let priceFactors = Set(Factor.allCases.filter(\.isPriceBased))
        let w = config.weights.normalized(restrictedTo: priceFactors)
        guard priceFactors.contains(where: { (w[$0] ?? 0) > 0 }) else { throw BacktestError.noPriceFactorsWeighted }
        let scoring = ScoringConfig(weights: FactorWeights(w), neutralization: config.neutralization,
                                    minimumCoverage: 1.0)

        let monthEnds = panel.monthEndIndices
        let tickers = panel.tickers.filter { $0 != config.benchmark }
        // Need 12 prior month-ends for momentum and one following month-end to measure the return.
        let firstRebalance = 12
        let lastRebalance = monthEnds.count - 2
        guard lastRebalance >= firstRebalance else {
            throw BacktestError.insufficientHistory(months: max(0, monthEnds.count - 13))
        }
        let maxMonths = config.lookbackYears * 12
        let startRebalance = max(firstRebalance, lastRebalance - maxMonths + 1)

        let q = config.quantiles
        var monthly = [[Double]](repeating: [], count: q)
        var ics: [Double] = []
        var ends: [String] = []
        var stockCounts: [Int] = []
        let totalSteps = Double(lastRebalance - startRebalance + 1)

        for (step, m) in (startRebalance...lastRebalance).enumerated() {
            let t = monthEnds[m], tNext = monthEnds[m + 1]
            let monthPrices = monthEnds[(m - 12)...m]
            var inputs: [StockInput] = []
            var forward: [Double] = []
            let marketWindow = Array(market[max(0, t - Returns.tradingDaysPerYear)...t])

            for tk in tickers {
                guard let p = panel.closes[tk] else { continue }
                let p0 = p[t], p1 = p[tNext]
                guard p0.isFinite, p1.isFinite, p0 > 0 else { continue }
                let me = monthPrices.map { p[$0] }
                let window = Array(p[max(0, t - Returns.tradingDaysPerYear)...t])
                var metrics: [Metric: Double] = [:]
                let mom = Returns.monthlyMomentum12_1(me)
                if mom.isFinite { metrics[.momentum12_1] = mom }
                let vol = Returns.realizedVolatility(window)
                if vol.isFinite { metrics[.volatility] = vol }
                let b = Returns.beta(stock: window, market: marketWindow)
                if b.isFinite { metrics[.beta] = b }
                inputs.append(StockInput(ticker: tk, sector: sectors[tk] ?? "Unknown", metrics: metrics))
                forward.append(p1 / p0 - 1)
            }

            let fwdByTicker = Dictionary(uniqueKeysWithValues: zip(inputs.map(\.ticker), forward))
            let result = ScoringEngine.score(inputs, config: scoring)
            let scored = result.scores
            ends.append(panel.dates[tNext])
            stockCounts.append(scored.count)

            if scored.count >= q {
                let scores = scored.map(\.composite)
                let rets = scored.map { fwdByTicker[$0.ticker]! }
                let buckets = Quantiles.form(scores: scores, quantiles: q)
                for b in 0..<q {
                    monthly[b].append(VectorMath.mean(buckets[b].map { rets[$0] }))
                }
                ics.append(Stats.spearman(scores, rets))
            } else {
                for b in 0..<q { monthly[b].append(.nan) }
                ics.append(.nan)
            }
            progress?(Double(step + 1) / totalSteps)
        }

        let spread = zip(monthly[0], monthly[q - 1]).map { $0 - $1 }
        func stats(_ r: [Double]) -> QuantileStats {
            QuantileStats(annualizedReturn: Returns.annualizedReturn(r),
                          annualizedVolatility: Returns.annualizedVolatility(r),
                          sharpe: Returns.sharpe(r),
                          maxDrawdown: Returns.maxDrawdown(returns: r))
        }
        let validIC = ics.filter { !$0.isNaN }
        return BacktestResult(
            periodEnds: ends,
            monthlyReturns: monthly,
            cumulative: monthly.map(Returns.cumulative),
            spreadReturns: spread,
            spreadCumulative: Returns.cumulative(spread),
            stats: monthly.map(stats),
            spreadStats: stats(spread),
            informationCoefficients: ics,
            meanIC: validIC.isEmpty ? .nan : VectorMath.mean(validIC),
            months: ends.count,
            averageStocksPerRebalance: stockCounts.isEmpty ? 0 : Double(stockCounts.reduce(0, +)) / Double(stockCounts.count),
            isTooShort: ends.count < BacktestResult.minimumMeaningfulMonths
        )
    }
}
