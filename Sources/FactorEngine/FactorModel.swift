import Foundation

// MARK: - Metrics and factors

/// A raw input metric. Every metric is oriented so that, after `transform`,
/// HIGHER is BETTER. "Inverted" metrics from the methodology (EV/EBITDA,
/// debt-to-equity, volatility, beta, size) are handled here.
public enum Metric: String, CaseIterable, Codable, Sendable, Hashable {
    case earningsYield      // E/P = 1 / (P/E)
    case ebitdaToEV         // EV/EBITDA inverted as EBITDA/EV, which ranks negative EBITDA correctly
    case bookToMarket       // B/M = 1 / (P/B)
    case roe                // return on equity
    case grossMargin
    case debtToEquity       // lower is better
    case momentum12_1       // 12-month return excluding the latest month
    case volatility         // 1y annualized realized vol, lower is better
    case beta               // vs SPY, lower is better
    case marketCap          // log market cap, smaller is better (size tilt)

    public var factor: Factor {
        switch self {
        case .earningsYield, .ebitdaToEV, .bookToMarket: return .value
        case .roe, .grossMargin, .debtToEquity: return .quality
        case .momentum12_1: return .momentum
        case .volatility, .beta: return .lowVolatility
        case .marketCap: return .size
        }
    }

    /// +1 when a larger raw value is better, -1 when a smaller one is.
    public var direction: Double {
        switch self {
        case .debtToEquity, .volatility, .beta, .marketCap: return -1
        default: return 1
        }
    }

    /// True for metrics computed from prices (usable in the backtest without look-ahead).
    public var isPriceBased: Bool {
        switch self {
        case .momentum12_1, .volatility, .beta: return true
        default: return false
        }
    }

    /// Converts a raw value to the value that is winsorized and z-scored.
    /// Returns nil when the raw value cannot be scored meaningfully.
    public func transform(_ raw: Double) -> Double? {
        guard raw.isFinite else { return nil }
        switch self {
        case .debtToEquity:
            // Negative D/E means negative equity; ranking it as "low leverage" would be wrong.
            return raw < 0 ? nil : raw
        case .marketCap:
            return raw > 0 ? log(raw) : nil
        case .volatility:
            return raw >= 0 ? raw : nil
        default:
            return raw
        }
    }
}

public enum Factor: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case value, quality, momentum, lowVolatility, size
    public var id: String { rawValue }

    public var metrics: [Metric] { Metric.allCases.filter { $0.factor == self } }

    public var displayName: String {
        switch self {
        case .value: return "Value"
        case .quality: return "Quality"
        case .momentum: return "Momentum"
        case .lowVolatility: return "Low Volatility"
        case .size: return "Size"
        }
    }

    public var isPriceBased: Bool { metrics.allSatisfy(\.isPriceBased) }
}

// MARK: - Weights and presets

/// User weights per factor. Stored as raw slider values; `normalized` scales them to sum to 1.
public struct FactorWeights: Codable, Sendable, Hashable {
    public var raw: [Factor: Double]

    public init(_ raw: [Factor: Double]) {
        self.raw = raw
    }

    public init(value: Double = 0, quality: Double = 0, momentum: Double = 0,
                lowVolatility: Double = 0, size: Double = 0) {
        raw = [.value: value, .quality: quality, .momentum: momentum,
               .lowVolatility: lowVolatility, .size: size]
    }

    public subscript(f: Factor) -> Double {
        get { raw[f] ?? 0 }
        set { raw[f] = max(0, newValue) }
    }

    /// Weights scaled to sum to 1. All-zero input returns all zeros.
    public var normalized: [Factor: Double] {
        let total = Factor.allCases.reduce(0) { $0 + max(0, self[$1]) }
        guard total > 0 else { return Dictionary(uniqueKeysWithValues: Factor.allCases.map { ($0, 0) }) }
        return Dictionary(uniqueKeysWithValues: Factor.allCases.map { ($0, max(0, self[$0]) / total) })
    }

    /// Normalized weights restricted to the given factors (e.g. price-only for the backtest).
    public func normalized(restrictedTo factors: Set<Factor>) -> [Factor: Double] {
        var w = FactorWeights([:])
        for f in factors { w[f] = self[f] }
        return w.normalized
    }

    public var activeFactors: [Factor] { Factor.allCases.filter { self[$0] > 0 } }
}

public enum Preset: String, CaseIterable, Codable, Sendable, Identifiable {
    case balanced, value, quality, momentum, defensive
    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }

    public var weights: FactorWeights {
        switch self {
        case .balanced:  return FactorWeights(value: 25, quality: 25, momentum: 25, lowVolatility: 25, size: 0)
        case .value:     return FactorWeights(value: 60, quality: 20, momentum: 10, lowVolatility: 10, size: 0)
        case .quality:   return FactorWeights(value: 15, quality: 55, momentum: 15, lowVolatility: 15, size: 0)
        case .momentum:  return FactorWeights(value: 10, quality: 15, momentum: 65, lowVolatility: 10, size: 0)
        case .defensive: return FactorWeights(value: 10, quality: 35, momentum: 5, lowVolatility: 50, size: 0)
        }
    }

    public var summary: String {
        switch self {
        case .balanced: return "Equal weight on value, quality, momentum and low volatility."
        case .value: return "Favors cheap stocks relative to earnings, cash flow and book value."
        case .quality: return "Favors profitable companies with strong margins and low debt."
        case .momentum: return "Favors stocks that have outperformed over the past year."
        case .defensive: return "Favors steady, lower-risk, profitable companies."
        }
    }
}

public enum Neutralization: String, Codable, Sendable, CaseIterable {
    /// Z-score each metric within its GICS sector (default).
    case sector
    /// Z-score each metric across the whole universe.
    case crossSectional
}

// MARK: - Scoring

public struct StockInput: Sendable, Hashable {
    public var ticker: String
    public var sector: String
    /// Raw (untransformed) metric values. Missing metrics are simply absent.
    public var metrics: [Metric: Double]

    public init(ticker: String, sector: String, metrics: [Metric: Double]) {
        self.ticker = ticker
        self.sector = sector
        self.metrics = metrics
    }
}

public struct ScoringConfig: Sendable, Hashable {
    public var weights: FactorWeights
    public var neutralization: Neutralization
    public var winsorLower: Double
    public var winsorUpper: Double
    /// A stock must have at least this fraction of the metrics used by active
    /// factors, or it is excluded from scoring.
    public var minimumCoverage: Double

    public init(weights: FactorWeights = Preset.balanced.weights,
                neutralization: Neutralization = .sector,
                winsorLower: Double = 0.01, winsorUpper: Double = 0.99,
                minimumCoverage: Double = 0.6) {
        self.weights = weights
        self.neutralization = neutralization
        self.winsorLower = winsorLower
        self.winsorUpper = winsorUpper
        self.minimumCoverage = minimumCoverage
    }
}

public struct StockScore: Sendable, Hashable, Identifiable {
    public var id: String { ticker }
    public var ticker: String
    public var sector: String
    public var composite: Double
    /// Factor scores in z-units (average of the factor's metric z-scores).
    public var factorScores: [Factor: Double]
    /// Per-metric z-scores after winsorizing and direction adjustment.
    public var metricScores: [Metric: Double]
    /// 1 = best.
    public var rank: Int
    /// Percentile of the composite across the scored universe, 0–100.
    public var percentile: Double
    /// Percentile of the composite within the stock's sector, 0–100.
    public var sectorPercentile: Double
    public var missingMetrics: [Metric]
}

public struct ExcludedStock: Sendable, Hashable {
    public var ticker: String
    public var coverage: Double
    public var missingMetrics: [Metric]
}

public struct ScoringResult: Sendable {
    public var scores: [StockScore]          // sorted best first
    public var excluded: [ExcludedStock]
    /// Median factor score per sector, for the Stock Detail comparison chart.
    public var sectorMedians: [String: [Factor: Double]]
}

public enum ScoringEngine {

    /// Scores a universe. Pure and deterministic; safe to call from any thread.
    ///
    /// Steps per metric: transform → winsorize (1st/99th pct, across the universe) →
    /// z-score (within sector or cross-sectional) → multiply by direction.
    /// Factor score = mean of available metric z-scores. Composite = weighted mean of
    /// available factor scores using normalized weights (re-normalized over the factors
    /// the stock actually has).
    public static func score(_ inputs: [StockInput], config: ScoringConfig) -> ScoringResult {
        let weights = config.weights.normalized
        let active = Factor.allCases.filter { (weights[$0] ?? 0) > 0 }
        let activeMetrics = active.flatMap(\.metrics)
        guard !inputs.isEmpty, !activeMetrics.isEmpty else {
            return ScoringResult(scores: [], excluded: [], sectorMedians: [:])
        }

        // 1. Coverage filter.
        var kept: [StockInput] = []
        var excluded: [ExcludedStock] = []
        for s in inputs {
            let missing = activeMetrics.filter { m in s.metrics[m].flatMap(m.transform) == nil }
            let coverage = Double(activeMetrics.count - missing.count) / Double(activeMetrics.count)
            if coverage + 1e-9 >= config.minimumCoverage {
                kept.append(s)
            } else {
                excluded.append(ExcludedStock(ticker: s.ticker, coverage: coverage, missingMetrics: missing))
            }
        }
        guard !kept.isEmpty else {
            return ScoringResult(scores: [], excluded: excluded, sectorMedians: [:])
        }

        // 2. Per-metric z-scores.
        let sectors = kept.map(\.sector)
        var z: [Metric: [Double]] = [:]
        for m in activeMetrics {
            let x = kept.map { s in s.metrics[m].flatMap(m.transform) ?? .nan }
            let w = Stats.winsorize(x, lower: config.winsorLower, upper: config.winsorUpper)
            let zz: [Double]
            switch config.neutralization {
            case .sector: zz = Stats.groupZScores(w, groups: sectors)
            case .crossSectional: zz = Stats.zScores(w)
            }
            z[m] = zz.map { $0 * m.direction }
        }

        // 3. Factor and composite scores.
        struct Partial { var input: StockInput; var composite: Double; var factors: [Factor: Double]; var metrics: [Metric: Double]; var missing: [Metric] }
        var partials: [Partial] = []
        partials.reserveCapacity(kept.count)
        for (i, s) in kept.enumerated() {
            var metricScores: [Metric: Double] = [:]
            var missing: [Metric] = []
            for m in activeMetrics {
                let v = z[m]![i]
                if v.isNaN { missing.append(m) } else { metricScores[m] = v }
            }
            var factorScores: [Factor: Double] = [:]
            var num = 0.0, den = 0.0
            for f in active {
                let vals = f.metrics.compactMap { metricScores[$0] }
                guard !vals.isEmpty else { continue }
                let fs = VectorMath.mean(vals)
                factorScores[f] = fs
                num += fs * weights[f]!
                den += weights[f]!
            }
            let composite = den > 0 ? num / den : .nan
            partials.append(Partial(input: s, composite: composite, factors: factorScores, metrics: metricScores, missing: missing))
        }

        partials.sort { a, b in
            if a.composite == b.composite { return a.input.ticker < b.input.ticker }
            return a.composite > b.composite
        }
        let composites = partials.map(\.composite)
        let pct = Stats.percentileRanks(composites)

        var sectorIdx: [String: [Int]] = [:]
        for (i, p) in partials.enumerated() { sectorIdx[p.input.sector, default: []].append(i) }
        var sectorPct = [Double](repeating: 50, count: partials.count)
        var sectorMedians: [String: [Factor: Double]] = [:]
        for (sector, idx) in sectorIdx {
            let r = Stats.percentileRanks(idx.map { composites[$0] })
            for (k, i) in idx.enumerated() { sectorPct[i] = r[k] }
            var med: [Factor: Double] = [:]
            for f in active {
                let vals = idx.compactMap { partials[$0].factors[f] }
                if !vals.isEmpty { med[f] = Stats.median(vals) }
            }
            sectorMedians[sector] = med
        }

        let scores = partials.enumerated().map { i, p in
            StockScore(ticker: p.input.ticker, sector: p.input.sector, composite: p.composite,
                       factorScores: p.factors, metricScores: p.metrics, rank: i + 1,
                       percentile: pct[i], sectorPercentile: sectorPct[i], missingMetrics: p.missing)
        }
        return ScoringResult(scores: scores, excluded: excluded, sectorMedians: sectorMedians)
    }
}
