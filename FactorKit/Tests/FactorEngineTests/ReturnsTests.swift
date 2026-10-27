import XCTest
@testable import FactorEngine

final class ReturnsTests: XCTestCase {

    func testSimpleReturns() {
        let r = Returns.simpleReturns([100, 110, 99, .nan, 120])
        XCTAssertEqual(r[0], 0.10, accuracy: 1e-12)
        XCTAssertEqual(r[1], -0.10, accuracy: 1e-12)
        XCTAssertTrue(r[2].isNaN)
        XCTAssertTrue(r[3].isNaN)
    }

    func testMomentum12_1SkipsLastMonth() {
        // 253 prices: p[0] = 100 (t-252), p[231] = 150 (t-21), last month rallies to 300.
        var p = [Double](repeating: 120, count: 253)
        p[0] = 100
        p[231] = 150
        for i in 232...252 { p[i] = 300 }
        XCTAssertEqual(Returns.momentum12_1(p), 0.5, accuracy: 1e-12)
        // Not enough history.
        XCTAssertTrue(Returns.momentum12_1(Array(p.prefix(252))).isNaN)
    }

    func testMonthlyMomentum12_1() {
        // 13 month-ends: m[0] = 50 (t-12), m[11] = 60 (t-1), m[12] = 1 (ignored).
        var m = [Double](repeating: 55, count: 13)
        m[0] = 50; m[11] = 60; m[12] = 1
        XCTAssertEqual(Returns.monthlyMomentum12_1(m), 0.2, accuracy: 1e-12)
    }

    func testRealizedVolatilityHandChecked() {
        // Alternating +1% / -1% returns. Over an even number n of returns the mean is 0
        // and the sample sd is 0.01·sqrt(n/(n-1)). Annualized ×√252.
        var p = [100.0]
        for i in 0..<200 { p.append(p.last! * (i % 2 == 0 ? 1.01 : 0.99)) }
        let n = 200.0
        let expected = 0.01 * (n / (n - 1)).squareRoot() * 252.0.squareRoot()
        XCTAssertEqual(Returns.realizedVolatility(p), expected, accuracy: 1e-12)
        // Too few observations.
        XCTAssertTrue(Returns.realizedVolatility(Array(p.prefix(50))).isNaN)
    }

    func testBetaOfScaledSeriesIsTheScale() {
        // Stock returns are exactly 2× market returns → beta 2.
        var m = [100.0], s = [50.0]
        for i in 0..<150 {
            let r = (i % 3 == 0 ? 0.01 : -0.004) + Double(i % 5) * 0.001
            m.append(m.last! * (1 + r))
            s.append(s.last! * (1 + 2 * r))
        }
        XCTAssertEqual(Returns.beta(stock: s, market: m), 2, accuracy: 1e-12)
        XCTAssertEqual(Returns.beta(stock: m, market: m), 1, accuracy: 1e-12)
    }

    func testBetaHandChecked() {
        // Market returns +1%, -1%, +2%; stock +2%, 0%, +1% (minObservations lowered).
        // mean m = 0.006667, mean s = 0.01
        // dm = .003333, -.016667, .013333 ; ds = .01, -.01, 0
        // cov sum = .0000333 + .0001667 + 0 = .0002 ; var sum = .0000111+.0002778+.0001778=.0004667
        // beta = .0002 / .00046667 = 0.428571...
        let m = [100, 101, 99.99, 101.9898]
        let s = [100, 102, 102, 103.02]
        XCTAssertEqual(Returns.beta(stock: s, market: m, minObservations: 3), 3.0 / 7.0, accuracy: 1e-9)
    }

    func testMovingAverage() {
        let ma = Returns.movingAverage([1, 2, 3, 4, 5], window: 3)
        XCTAssertTrue(ma[0].isNaN && ma[1].isNaN)
        XCTAssertEqual(Array(ma[2...]), [2, 3, 4])
    }

    func testMaxDrawdownHandChecked() {
        // Wealth 1.1, 1.21, 0.847 (−30% from peak), 1.0
        let r = [0.10, 0.10, -0.30, 1.0 / 0.847 - 1]
        XCTAssertEqual(Returns.maxDrawdown(returns: r), 0.30, accuracy: 1e-12)
        XCTAssertEqual(Returns.maxDrawdown(returns: [0.05, 0.02]), 0)
        // Loss in the first period is measured from the starting $1.
        XCTAssertEqual(Returns.maxDrawdown(returns: [-0.2, 0.1]), 0.2, accuracy: 1e-12)
    }

    func testAnnualizedStats() {
        // 12 months of +1% → (1.01^12) - 1
        let r = [Double](repeating: 0.01, count: 12)
        XCTAssertEqual(Returns.annualizedReturn(r), pow(1.01, 12) - 1, accuracy: 1e-12)
        XCTAssertEqual(Returns.annualizedVolatility(r), 0, accuracy: 1e-12)
        XCTAssertTrue(Returns.sharpe(r).isNaN)  // zero volatility
        // Returns +2%, 0%: mean 1%, sd sqrt(0.0002) → Sharpe = 0.01/0.014142·√12
        let s = Returns.sharpe([0.02, 0.0])
        XCTAssertEqual(s, 0.01 / 0.0002.squareRoot() * 12.0.squareRoot(), accuracy: 1e-9)
    }

    func testPriceMetricsOnPanel() {
        var dates: [String] = []
        var spy: [Double] = [], aaa: [Double] = []
        var p1 = 100.0, p2 = 100.0
        for i in 0..<260 {
            dates.append(String(format: "2024-%02d-%02d", i / 28 + 1, i % 28 + 1))
            let r = i % 2 == 0 ? 0.01 : -0.009
            p1 *= 1 + r; p2 *= 1 + 1.5 * r
            spy.append(p1); aaa.append(p2)
        }
        aaa[259] = .nan  // last day missing: momentum should still compute
        let panel = PricePanel(dates: dates, closes: ["SPY": spy, "AAA": aaa])
        let m = PriceMetrics.compute(panel: panel)
        XCTAssertEqual(m["SPY"]!.beta, 1)
        XCTAssertEqual(m["AAA"]!.beta, 1.5, accuracy: 1e-9)
        XCTAssertFalse(m["AAA"]!.momentum12_1.isNaN)
        XCTAssertEqual(m["AAA"]!.lastClose, aaa[258])
    }

    func testMonthEndIndices() {
        let panel = PricePanel(dates: ["2024-01-30", "2024-01-31", "2024-02-01", "2024-02-29", "2024-03-01"], closes: [:])
        XCTAssertEqual(panel.monthEndIndices, [1, 3, 4])
    }
}
