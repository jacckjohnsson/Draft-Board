import Foundation

/// Cross-sectional and time-series statistics used by the factor model.
/// All functions are pure. NaN marks a missing value and is skipped where noted.
public enum Stats {

    // MARK: Basics

    public static func mean(_ x: [Double]) -> Double { VectorMath.mean(x) }

    /// Sample standard deviation (n - 1). Returns NaN for fewer than 2 values.
    public static func standardDeviation(_ x: [Double]) -> Double {
        guard x.count >= 2 else { return .nan }
        let m = VectorMath.mean(x)
        return (VectorMath.sumSquaredDeviations(x, from: m) / Double(x.count - 1)).squareRoot()
    }

    public static func median(_ x: [Double]) -> Double {
        percentile(x, 0.5)
    }

    /// Percentile with linear interpolation between closest ranks
    /// (same definition as numpy's default and Excel's PERCENTILE.INC).
    /// `p` is in [0, 1]. Returns NaN for an empty array.
    public static func percentile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return .nan }
        let s = x.sorted()
        if s.count == 1 { return s[0] }
        let pos = min(max(p, 0), 1) * Double(s.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        let frac = pos - Double(lo)
        return s[lo] + (s[hi] - s[lo]) * frac
    }

    // MARK: Cross-sectional transforms

    /// Clamp values to the [lower, upper] percentiles of the non-NaN values.
    /// NaNs pass through unchanged.
    public static func winsorize(_ x: [Double], lower: Double = 0.01, upper: Double = 0.99) -> [Double] {
        let valid = x.filter { !$0.isNaN }
        guard valid.count >= 2 else { return x }
        let lo = percentile(valid, lower)
        let hi = percentile(valid, upper)
        return x.map { $0.isNaN ? $0 : min(max($0, lo), hi) }
    }

    /// Standard scores using the sample standard deviation of the non-NaN values.
    /// If every value is equal (sd == 0) all scores are 0. NaNs pass through.
    public static func zScores(_ x: [Double]) -> [Double] {
        let valid = x.filter { !$0.isNaN }
        guard valid.count >= 2 else { return x.map { $0.isNaN ? .nan : 0 } }
        let m = VectorMath.mean(valid)
        let sd = standardDeviation(valid)
        guard sd > 0, sd.isFinite else { return x.map { $0.isNaN ? .nan : 0 } }
        return x.map { $0.isNaN ? .nan : ($0 - m) / sd }
    }

    /// Z-scores computed separately inside each group (e.g. GICS sector).
    /// Groups with fewer than `minGroupSize` valid values fall back to the
    /// cross-sectional z-score so a lone stock in a sector is still scored.
    public static func groupZScores(_ x: [Double], groups: [String], minGroupSize: Int = 3) -> [Double] {
        precondition(x.count == groups.count, "groupZScores: length mismatch")
        let global = zScores(x)
        var out = global
        var byGroup: [String: [Int]] = [:]
        for (i, g) in groups.enumerated() { byGroup[g, default: []].append(i) }
        for (_, idx) in byGroup {
            let validCount = idx.reduce(0) { $0 + (x[$1].isNaN ? 0 : 1) }
            guard validCount >= minGroupSize else { continue }
            let z = zScores(idx.map { x[$0] })
            for (k, i) in idx.enumerated() { out[i] = z[k] }
        }
        return out
    }

    /// Fractional ranks (1-based), ties get the average rank.
    public static func ranks(_ x: [Double]) -> [Double] {
        let order = x.indices.sorted { x[$0] < x[$1] }
        var r = [Double](repeating: 0, count: x.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && x[order[j + 1]] == x[order[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[order[k]] = avg }
            i = j + 1
        }
        return r
    }

    /// Percentile rank in [0, 100] of each value within the array (ties averaged).
    public static func percentileRanks(_ x: [Double]) -> [Double] {
        guard x.count > 1 else { return x.map { _ in 50 } }
        return ranks(x).map { ($0 - 1) / Double(x.count - 1) * 100 }
    }

    // MARK: Correlation

    /// Pearson correlation over pairs where both values are present.
    /// Returns NaN with fewer than 3 overlapping points or zero variance.
    public static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count, "pearson: length mismatch")
        var xa: [Double] = [], xb: [Double] = []
        xa.reserveCapacity(a.count); xb.reserveCapacity(b.count)
        for i in a.indices where !a[i].isNaN && !b[i].isNaN {
            xa.append(a[i]); xb.append(b[i])
        }
        guard xa.count >= 3 else { return .nan }
        let ma = VectorMath.mean(xa), mb = VectorMath.mean(xb)
        let da = VectorMath.subtract(xa, scalar: ma), db = VectorMath.subtract(xb, scalar: mb)
        let cov = VectorMath.dot(da, db)
        let va = VectorMath.dot(da, da), vb = VectorMath.dot(db, db)
        guard va > 0, vb > 0 else { return .nan }
        return cov / (va * vb).squareRoot()
    }

    /// Spearman rank correlation: Pearson correlation of the (tie-averaged) ranks,
    /// over pairs where both values are present.
    public static func spearman(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count, "spearman: length mismatch")
        var xa: [Double] = [], xb: [Double] = []
        for i in a.indices where !a[i].isNaN && !b[i].isNaN {
            xa.append(a[i]); xb.append(b[i])
        }
        guard xa.count >= 3 else { return .nan }
        return pearson(ranks(xa), ranks(xb))
    }

    /// Symmetric correlation matrix of the given series (each the same length).
    public static func correlationMatrix(_ series: [[Double]]) -> [[Double]] {
        let n = series.count
        var m = [[Double]](repeating: [Double](repeating: .nan, count: n), count: n)
        for i in 0..<n {
            m[i][i] = 1
            for j in (i + 1)..<max(i + 1, n) {
                let c = pearson(series[i], series[j])
                m[i][j] = c; m[j][i] = c
            }
        }
        return m
    }
}
