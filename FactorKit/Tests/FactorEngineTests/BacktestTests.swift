import XCTest
@testable import FactorEngine

final class BacktestTests: XCTestCase {

    // MARK: Quintile formation

    func testQuintileAssignmentEvenSplit() {
        XCTAssertEqual(Quantiles.assign(count: 10, quantiles: 5), [0, 0, 1, 1, 2, 2, 3, 3, 4, 4])
    }

    func testQuintileAssignmentUneven() {
        // 7 into 5: floor(i·5/7) = 0,0,1,2,2,3,4
        XCTAssertEqual(Quantiles.assign(count: 7, quantiles: 5), [0, 0, 1, 2, 2, 3, 4])
    }

    func testQuintileFormationSortsBestFirst() {
        let scores: [Double] = [0.1, 0.9, 0.5, 0.3, 0.7, 0.2, 0.8, 0.4, 0.6, 0.0]
        let b = Quantiles.form(scores: scores, quantiles: 5)
        XCTAssertEqual(b[0], [1, 6])   // 0.9, 0.8
        XCTAssertEqual(b[4], [0, 9])   // 0.1, 0.0
        XCTAssertEqual(b.flatMap { $0 }.count, 10)
    }

    // MARK: Engine

    /// Synthetic market where momentum persists: each stock has a constant monthly
    /// drift, so last year's winners are next month's winners. The top quintile must
    /// beat the bottom and the IC must be +1.
    private func persistentMomentumPanel(months: Int, stocks: Int = 10) -> PricePanel {
        var dates: [String] = []
        var closes: [String: [Double]] = ["SPY": []]
        for s in 0..<stocks { closes["S\(s)"] = [] }
        var price: [String: Double] = closes.mapValues { _ in 100 }
        var day = 0
        for m in 0..<months {
            let y = 2010 + m / 12, mo = m % 12 + 1
            for d in 1...20 {
                dates.append(String(format: "%04d-%02d-%02d", y, mo, d))
                // Tiny alternating noise keeps volatility non-zero and identical across stocks.
                let noise = day % 2 == 0 ? 0.002 : -0.002
                price["SPY"]! *= 1 + 0.0005 + noise
                closes["SPY"]!.append(price["SPY"]!)
                for s in 0..<stocks {
                    let drift = Double(s) * 0.0005        // S9 strongest
                    price["S\(s)"]! *= 1 + drift + noise
                    closes["S\(s)"]!.append(price["S\(s)"]!)
                }
                day += 1
            }
        }
        return PricePanel(dates: dates, closes: closes)
    }

    func testMomentumBacktestTopBeatsBottom() throws {
        let panel = persistentMomentumPanel(months: 60)
        let cfg = BacktestConfig(weights: FactorWeights(momentum: 1), lookbackYears: 10)
        let r = try BacktestEngine.run(panel: panel, config: cfg)
        // 60 month-ends, 12 warm-up, last one has no forward month → 47 rebalances.
        XCTAssertEqual(r.months, 47)
        XCTAssertGreaterThan(r.cumulative[0].last!, r.cumulative[4].last!)
        XCTAssertGreaterThan(r.spreadStats.annualizedReturn, 0)
        XCTAssertEqual(r.meanIC, 1, accuracy: 1e-9)
        XCTAssertFalse(r.isTooShort)
        XCTAssertEqual(r.averageStocksPerRebalance, 10)
        // Spread is top minus bottom each month.
        XCTAssertEqual(r.spreadReturns[0], r.monthlyReturns[0][0] - r.monthlyReturns[4][0], accuracy: 1e-12)
    }

    func testLookbackLimitsMonths() throws {
        let panel = persistentMomentumPanel(months: 60)
        let r = try BacktestEngine.run(panel: panel, config: BacktestConfig(weights: FactorWeights(momentum: 1), lookbackYears: 2))
        XCTAssertEqual(r.months, 24)
        XCTAssertTrue(r.isTooShort)
    }

    func testShortHistoryThrows() {
        let panel = persistentMomentumPanel(months: 12)
        XCTAssertThrowsError(try BacktestEngine.run(panel: panel, config: BacktestConfig(weights: FactorWeights(momentum: 1))))
    }

    func testRequiresPriceFactor() {
        let panel = persistentMomentumPanel(months: 30)
        XCTAssertThrowsError(try BacktestEngine.run(panel: panel, config: BacktestConfig(weights: FactorWeights(value: 1)))) { e in
            XCTAssertEqual(e as? BacktestError, .noPriceFactorsWeighted)
        }
    }

    func testMissingBenchmarkThrows() {
        var panel = persistentMomentumPanel(months: 30)
        panel.closes["SPY"] = nil
        XCTAssertThrowsError(try BacktestEngine.run(panel: panel, config: BacktestConfig())) { e in
            XCTAssertEqual(e as? BacktestError, .missingBenchmark)
        }
    }

    func testCacheKeyIgnoresNonPriceWeights() {
        let a = BacktestConfig(weights: FactorWeights(value: 50, momentum: 50, lowVolatility: 50))
        let b = BacktestConfig(weights: FactorWeights(quality: 10, momentum: 1, lowVolatility: 1))
        XCTAssertEqual(a.cacheKey, b.cacheKey)
        XCTAssertNotEqual(a.cacheKey, BacktestConfig(weights: FactorWeights(momentum: 1)).cacheKey)
    }

    // MARK: Clustering & diagnostics

    func testHierarchicalClusteringGroupsCorrelatedPairs() {
        // A,B highly correlated; C,D highly correlated; across groups ~0.
        let c: [[Double]] = [
            [1, 0.9, 0.1, 0.0],
            [0.9, 1, 0.0, 0.1],
            [0.1, 0.0, 1, 0.85],
            [0.0, 0.1, 0.85, 1],
        ]
        let out = Clustering.hierarchical(correlation: c, threshold: 0.5)
        XCTAssertEqual(Set(out.clusters.map { Set($0) }), [Set([0, 1]), Set([2, 3])])
        XCTAssertEqual(out.merges.first!.distance, 0.1, accuracy: 1e-12)
        XCTAssertEqual(Clustering.seriation(out).count, 4)
    }

    func testBasketWarnings() {
        let tickers = ["A", "B", "C"]
        let corr: [[Double]] = [[1, 0.85, 0.2], [0.85, 1, 0.1], [0.2, 0.1, 1]]
        let sectors = ["A": "Tech", "B": "Tech", "C": "Energy"]
        let w = BasketDiagnostics.warnings(tickers: tickers, correlation: corr, sectors: sectors)
        XCTAssertTrue(w.contains { if case .highCorrelation("A", "B", _) = $0.kind { return true }; return false })
        XCTAssertTrue(w.contains { if case let .sectorConcentration("Tech", s) = $0.kind { return abs(s - 2.0/3) < 1e-9 }; return false })
        XCTAssertEqual(w.count, 2)
    }

    // MARK: Export

    func testWholeShareAllocationAndCSV() {
        let w = Portfolio.weights(tickers: ["AAA", "BBB"], scheme: .equal)
        let alloc = Portfolio.allocate(weights: w, prices: ["AAA": 30, "BBB": 400], amount: 10_000, rounding: .whole)
        // 5000/30 = 166.67 → 166 ; 5000/400 = 12.5 → 12
        XCTAssertEqual(alloc.holdings.map(\.shares), [166, 12])
        XCTAssertEqual(alloc.invested, 166 * 30 + 12 * 400, accuracy: 1e-9)
        XCTAssertEqual(alloc.cash, 10_000 - 9_780, accuracy: 1e-9)
        XCTAssertEqual(Portfolio.shockLabCSV(alloc, rounding: .whole), "ticker,shares\nAAA,166\nBBB,12\n")
    }

    func testFractionalAllocationAndScoreWeights() {
        let w = Portfolio.weights(tickers: ["AAA", "BBB"], scheme: .score, percentiles: ["AAA": 75, "BBB": 25])
        XCTAssertEqual(w["AAA"]!, 0.75, accuracy: 1e-12)
        let alloc = Portfolio.allocate(weights: w, prices: ["AAA": 3, "BBB": 7, ], amount: 100, rounding: .fractional)
        XCTAssertEqual(alloc.holdings[0].shares, 25)
        XCTAssertEqual(alloc.holdings[1].shares, 3.5714)
        XCTAssertEqual(Portfolio.shockLabCSV(alloc, rounding: .fractional), "ticker,shares\nAAA,25\nBBB,3.5714\n")
    }

    func testUnpricedTickersAreReported() {
        let w = Portfolio.weights(tickers: ["AAA", "ZZZ"], scheme: .equal)
        let alloc = Portfolio.allocate(weights: w, prices: ["AAA": 10], amount: 100, rounding: .whole)
        XCTAssertEqual(alloc.unpriced, ["ZZZ"])
        XCTAssertEqual(alloc.holdings.first?.shares, 10)
    }

    func testConsistencyCheckFlagsOver1Percent() {
        let massive = ["AAA": ["2024-01-02": 100.0, "2024-01-03": 101.0], "BBB": ["2024-01-02": 50.0]]
        let yahoo = ["AAA": ["2024-01-02": 100.2, "2024-01-03": 103.0], "BBB": ["2024-01-02": 50.1]]
        let m = ConsistencyCheck.compare(primary: massive, secondary: yahoo)
        XCTAssertEqual(m.map(\.ticker), ["AAA"])
        XCTAssertEqual(m[0].date, "2024-01-03")
        XCTAssertEqual(m[0].relativeDifference, 2.0 / 103.0, accuracy: 1e-12)
    }
}
