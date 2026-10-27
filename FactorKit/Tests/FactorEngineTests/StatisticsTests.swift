import XCTest
@testable import FactorEngine

final class StatisticsTests: XCTestCase {

    // MARK: Percentile / winsorization

    func testPercentileLinearInterpolation() {
        // 1..5: position for p = 0.25 is 0.25 * 4 = 1.0 → value 2.
        XCTAssertEqual(Stats.percentile([5, 1, 3, 2, 4], 0.25), 2, accuracy: 1e-12)
        // p = 0.1 → pos 0.4 → 1 + 0.4 * (2 - 1) = 1.4
        XCTAssertEqual(Stats.percentile([1, 2, 3, 4, 5], 0.1), 1.4, accuracy: 1e-12)
        XCTAssertEqual(Stats.median([1, 2, 3, 4]), 2.5, accuracy: 1e-12)
        XCTAssertTrue(Stats.percentile([], 0.5).isNaN)
    }

    func testWinsorizeClampsTails() {
        // 0...100 (101 values) plus an outlier of 10_000.
        // With 102 values, the 99th percentile position is 0.99 * 101 = 99.99
        // → 99 + 0.99 * (100 - 99) = 99.99. The 1st percentile is at pos 1.01 → 1.01.
        var x = (0...100).map(Double.init)
        x.append(10_000)
        let w = Stats.winsorize(x)
        XCTAssertEqual(w.last!, 99.99, accuracy: 1e-9)
        XCTAssertEqual(w.first!, 1.01, accuracy: 1e-9)
        XCTAssertEqual(w[50], 50)               // middle untouched
    }

    func testWinsorizeSkipsNaN() {
        let w = Stats.winsorize([1, .nan, 2, 3], lower: 0.0, upper: 0.5)
        // Valid values 1,2,3 → upper bound = median = 2.
        XCTAssertEqual(w[0], 1)
        XCTAssertTrue(w[1].isNaN)
        XCTAssertEqual(w[2], 2)
        XCTAssertEqual(w[3], 2)
    }

    // MARK: Z-scores

    func testZScoresHandChecked() {
        // mean 5, sample sd of [2,4,4,4,5,5,7,9] = sqrt(32/7)
        let x: [Double] = [2, 4, 4, 4, 5, 5, 7, 9]
        let sd = (32.0 / 7).squareRoot()
        let z = Stats.zScores(x)
        XCTAssertEqual(z[0], (2 - 5) / sd, accuracy: 1e-12)
        XCTAssertEqual(z[7], (9 - 5) / sd, accuracy: 1e-12)
        XCTAssertEqual(z.reduce(0, +), 0, accuracy: 1e-12)
    }

    func testZScoresConstantAndNaN() {
        XCTAssertEqual(Stats.zScores([3, 3, 3]), [0, 0, 0])
        let z = Stats.zScores([1, .nan, 3])
        XCTAssertEqual(z[0], -1 / 2.0.squareRoot(), accuracy: 1e-12) // mean 2, sd sqrt(2)
        XCTAssertTrue(z[1].isNaN)
    }

    func testSectorNeutralZScores() {
        // Tech values 10,20,30 → z -1,0,1. Energy 1,2,3 → z -1,0,1.
        // Cross-sectionally tech would dominate; sector-neutral makes them identical.
        let x: [Double] = [10, 20, 30, 1, 2, 3]
        let g = ["Tech", "Tech", "Tech", "Energy", "Energy", "Energy"]
        let z = Stats.groupZScores(x, groups: g)
        XCTAssertEqual(z[0], -1, accuracy: 1e-12)
        XCTAssertEqual(z[1], 0, accuracy: 1e-12)
        XCTAssertEqual(z[2], 1, accuracy: 1e-12)
        XCTAssertEqual(z[3], -1, accuracy: 1e-12)
        XCTAssertEqual(z[5], 1, accuracy: 1e-12)
    }

    func testSmallSectorFallsBackToCrossSectional() {
        let x: [Double] = [1, 2, 3, 100]
        let g = ["A", "A", "A", "B"]          // B has one stock
        let z = Stats.groupZScores(x, groups: g)
        let global = Stats.zScores(x)
        XCTAssertEqual(z[3], global[3], accuracy: 1e-12)
        XCTAssertEqual(z[1], 0, accuracy: 1e-12)
    }

    // MARK: Ranks and correlations

    func testRanksAverageTies() {
        XCTAssertEqual(Stats.ranks([10, 20, 20, 30]), [1, 2.5, 2.5, 4])
        XCTAssertEqual(Stats.percentileRanks([3, 1, 2]), [100, 0, 50])
    }

    func testSpearmanPerfectAndInverse() {
        XCTAssertEqual(Stats.spearman([1, 2, 3, 4, 5], [10, 20, 30, 40, 1000]), 1, accuracy: 1e-12)
        XCTAssertEqual(Stats.spearman([1, 2, 3, 4, 5], [5, 4, 3, 2, 1]), -1, accuracy: 1e-12)
    }

    func testSpearmanHandChecked() {
        // ranks x: 1,2,3,4,5; ranks y of [2,1,4,3,5]: 2,1,4,3,5
        // d² = 1+1+1+1+0 = 4 → ρ = 1 - 6·4 / (5·24) = 0.8
        XCTAssertEqual(Stats.spearman([1, 2, 3, 4, 5], [2, 1, 4, 3, 5]), 0.8, accuracy: 1e-12)
    }

    func testSpearmanSkipsMissingPairs() {
        let r = Stats.spearman([1, 2, .nan, 3, 4], [1, 2, 99, 3, 4])
        XCTAssertEqual(r, 1, accuracy: 1e-12)
        XCTAssertTrue(Stats.spearman([1, 2], [1, 2]).isNaN)
    }

    func testPearsonHandChecked() {
        // x = 1,2,3 ; y = 1,3,2 → cov terms: (-1)(-1)+0+1·0 = 1; var 2 and 2 → 0.5
        XCTAssertEqual(Stats.pearson([1, 2, 3], [1, 3, 2]), 0.5, accuracy: 1e-12)
    }

    func testCorrelationMatrixIsSymmetric() {
        let m = Stats.correlationMatrix([[1, 2, 3, 4], [2, 4, 6, 8], [4, 3, 2, 1]])
        XCTAssertEqual(m[0][1], 1, accuracy: 1e-12)
        XCTAssertEqual(m[0][2], -1, accuracy: 1e-12)
        XCTAssertEqual(m[2][0], m[0][2])
        XCTAssertEqual(m[1][1], 1)
    }

    func testVectorMathFallbackMatchesNaive() {
        let x: [Double] = [1, -2, 3.5]
        XCTAssertEqual(VectorMath.sum(x), 2.5, accuracy: 1e-12)
        XCTAssertEqual(VectorMath.dot(x, x), 1 + 4 + 12.25, accuracy: 1e-12)
        XCTAssertEqual(VectorMath.clip(x, lo: -1, hi: 3), [1, -1, 3])
    }
}
