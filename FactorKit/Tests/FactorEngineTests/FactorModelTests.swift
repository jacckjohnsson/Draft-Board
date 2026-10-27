import XCTest
@testable import FactorEngine

final class FactorModelTests: XCTestCase {

    func testWeightsNormalizeTo100Percent() {
        let w = FactorWeights(value: 30, quality: 10, momentum: 0, lowVolatility: 10, size: 0).normalized
        XCTAssertEqual(w[.value]!, 0.6, accuracy: 1e-12)
        XCTAssertEqual(w[.quality]!, 0.2, accuracy: 1e-12)
        XCTAssertEqual(w.values.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(FactorWeights().normalized.values.reduce(0, +), 0)
    }

    func testPresetsAllSumTo100() {
        for p in Preset.allCases {
            let total = Factor.allCases.reduce(0) { $0 + p.weights[$1] }
            XCTAssertEqual(total, 100, accuracy: 1e-9, "\(p)")
        }
    }

    func testMetricTransforms() {
        XCTAssertNil(Metric.debtToEquity.transform(-1))
        XCTAssertEqual(Metric.marketCap.transform(exp(2))!, 2, accuracy: 1e-12)
        XCTAssertNil(Metric.roe.transform(.nan))
        XCTAssertEqual(Metric.beta.direction, -1)
        XCTAssertEqual(Metric.earningsYield.direction, 1)
    }

    /// Three stocks, momentum only, cross-sectional: z of [0.1, 0.2, 0.3] = [-1, 0, 1].
    func testSingleFactorScoringHandChecked() {
        let inputs = [
            StockInput(ticker: "A", sector: "X", metrics: [.momentum12_1: 0.1]),
            StockInput(ticker: "B", sector: "X", metrics: [.momentum12_1: 0.2]),
            StockInput(ticker: "C", sector: "X", metrics: [.momentum12_1: 0.3]),
        ]
        let cfg = ScoringConfig(weights: FactorWeights(momentum: 1), neutralization: .crossSectional,
                                winsorLower: 0, winsorUpper: 1)
        let r = ScoringEngine.score(inputs, config: cfg)
        XCTAssertEqual(r.scores.map(\.ticker), ["C", "B", "A"])
        XCTAssertEqual(r.scores[0].composite, 1, accuracy: 1e-12)
        XCTAssertEqual(r.scores[2].composite, -1, accuracy: 1e-12)
        XCTAssertEqual(r.scores[0].rank, 1)
        XCTAssertEqual(r.scores[0].percentile, 100)
    }

    func testInvertedMetricRanksLowerBetter() {
        let inputs = ["A": 0.1, "B": 0.2, "C": 0.3].map {
            StockInput(ticker: $0.key, sector: "X", metrics: [.volatility: $0.value, .beta: 1])
        }
        let r = ScoringEngine.score(inputs, config: ScoringConfig(weights: FactorWeights(lowVolatility: 1),
                                                                   neutralization: .crossSectional))
        XCTAssertEqual(r.scores.first?.ticker, "A")
    }

    func testCompositeWeightsFactors() {
        // A: best momentum (z=+1), worst value (z=-1). B: middle. C: opposite of A.
        // With 75% momentum / 25% value: A = 0.75 - 0.25 = 0.5, C = -0.5.
        let inputs = [
            StockInput(ticker: "A", sector: "X", metrics: [.momentum12_1: 0.3, .earningsYield: 0.01, .ebitdaToEV: 0.01, .bookToMarket: 0.01]),
            StockInput(ticker: "B", sector: "X", metrics: [.momentum12_1: 0.2, .earningsYield: 0.02, .ebitdaToEV: 0.02, .bookToMarket: 0.02]),
            StockInput(ticker: "C", sector: "X", metrics: [.momentum12_1: 0.1, .earningsYield: 0.03, .ebitdaToEV: 0.03, .bookToMarket: 0.03]),
        ]
        let cfg = ScoringConfig(weights: FactorWeights(value: 25, momentum: 75), neutralization: .crossSectional)
        let r = ScoringEngine.score(inputs, config: cfg)
        let a = r.scores.first { $0.ticker == "A" }!
        XCTAssertEqual(a.composite, 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.factorScores[.value]!, -1, accuracy: 1e-9)
        XCTAssertEqual(r.scores.first { $0.ticker == "C" }!.composite, -0.5, accuracy: 1e-9)
    }

    func testStocksMissingTooManyMetricsAreExcluded() {
        let full: [Metric: Double] = [.momentum12_1: 0.1, .volatility: 0.2, .beta: 1]
        let inputs = [
            StockInput(ticker: "A", sector: "X", metrics: full),
            StockInput(ticker: "B", sector: "X", metrics: full.mapValues { $0 * 2 }),
            StockInput(ticker: "C", sector: "X", metrics: full.mapValues { $0 * 3 }),
            StockInput(ticker: "D", sector: "X", metrics: [.beta: 1]),       // 1/3 coverage
            StockInput(ticker: "E", sector: "X", metrics: [.beta: 1, .volatility: 0.1]), // 2/3 ≥ 0.6
        ]
        let cfg = ScoringConfig(weights: FactorWeights(momentum: 50, lowVolatility: 50), neutralization: .crossSectional)
        let r = ScoringEngine.score(inputs, config: cfg)
        XCTAssertEqual(r.excluded.map(\.ticker), ["D"])
        XCTAssertEqual(r.excluded[0].missingMetrics.sorted { $0.rawValue < $1.rawValue }, [.momentum12_1, .volatility])
        XCTAssertEqual(r.scores.count, 4)
        let e = r.scores.first { $0.ticker == "E" }!
        XCTAssertEqual(e.missingMetrics, [.momentum12_1])
        XCTAssertNil(e.factorScores[.momentum])
        XCTAssertFalse(e.composite.isNaN)
    }

    func testSectorNeutralVsCrossSectional() {
        // Energy is cheap across the board; sector-neutral scoring should rank the best
        // stock within each sector equally.
        func s(_ t: String, _ sec: String, _ ey: Double) -> StockInput {
            StockInput(ticker: t, sector: sec, metrics: [.earningsYield: ey, .ebitdaToEV: ey, .bookToMarket: ey])
        }
        let inputs = [s("T1", "Tech", 0.01), s("T2", "Tech", 0.02), s("T3", "Tech", 0.03),
                      s("E1", "Energy", 0.10), s("E2", "Energy", 0.11), s("E3", "Energy", 0.12)]
        // Winsorizing is universe-wide, so it is switched off here to keep each sector symmetric.
        let neutral = ScoringEngine.score(inputs, config: ScoringConfig(weights: FactorWeights(value: 1),
                                                                        winsorLower: 0, winsorUpper: 1))
        let t3 = neutral.scores.first { $0.ticker == "T3" }!.composite
        let e3 = neutral.scores.first { $0.ticker == "E3" }!.composite
        XCTAssertEqual(t3, e3, accuracy: 1e-9)
        XCTAssertEqual(neutral.scores.first { $0.ticker == "T3" }!.sectorPercentile, 100)

        let cross = ScoringEngine.score(inputs, config: ScoringConfig(weights: FactorWeights(value: 1), neutralization: .crossSectional))
        XCTAssertEqual(Set(cross.scores.prefix(3).map(\.ticker)), ["E1", "E2", "E3"])
        XCTAssertNotNil(neutral.sectorMedians["Tech"]?[.value])
    }

    func testWinsorizationLimitsOutlierInfluence() {
        // One absurd momentum value shouldn't push everyone else into a tiny band.
        // 999 ordinary stocks plus one outlier. The 99th percentile sits inside the ordinary
        // range, so the outlier is clamped to about 0.989.
        var inputs = (0..<999).map { StockInput(ticker: "S\($0)", sector: "X", metrics: [.momentum12_1: Double($0) / 1000]) }
        inputs.append(StockInput(ticker: "OUT", sector: "X", metrics: [.momentum12_1: 1_000]))
        let r = ScoringEngine.score(inputs, config: ScoringConfig(weights: FactorWeights(momentum: 1), neutralization: .crossSectional))
        XCTAssertEqual(r.scores[0].ticker, "OUT")
        XCTAssertLessThan(r.scores[0].composite, 2)   // without winsorizing it would be ~31
    }
}
