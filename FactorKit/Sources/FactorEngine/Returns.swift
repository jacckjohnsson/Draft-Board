import Foundation

/// Price-series and performance metrics. Prices are assumed to be split-adjusted
/// closes in chronological order, one per trading day unless noted.
public enum Returns {
    public static let tradingDaysPerYear = 252
    /// Trading days in one month, used for the "skip the most recent month" leg of 12-1 momentum.
    public static let tradingDaysPerMonth = 21

    /// Simple returns r[t] = p[t] / p[t-1] - 1. Output has count - 1 elements.
    /// A NaN or non-positive price on either side yields NaN for that return.
    public static func simpleReturns(_ prices: [Double]) -> [Double] {
        guard prices.count >= 2 else { return [] }
        var r = [Double](repeating: .nan, count: prices.count - 1)
        for t in 1..<prices.count {
            let a = prices[t - 1], b = prices[t]
            if a.isFinite, b.isFinite, a > 0, b > 0 { r[t - 1] = b / a - 1 }
        }
        return r
    }

    /// 12-1 momentum from daily prices: the return from 12 months ago to 1 month ago,
    /// p[t - 21] / p[t - 252] - 1, where t is the last index. Skipping the most recent
    /// month avoids the short-term reversal effect. Needs at least 253 prices.
    public static func momentum12_1(_ prices: [Double],
                                    lookback: Int = tradingDaysPerYear,
                                    skip: Int = tradingDaysPerMonth) -> Double {
        let t = prices.count - 1
        guard t - lookback >= 0 else { return .nan }
        let start = prices[t - lookback], end = prices[t - skip]
        guard start.isFinite, end.isFinite, start > 0 else { return .nan }
        return end / start - 1
    }

    /// 12-1 momentum from month-end prices: m[t-1] / m[t-12] - 1.
    public static func monthlyMomentum12_1(_ monthEnd: [Double]) -> Double {
        let t = monthEnd.count - 1
        guard t - 12 >= 0 else { return .nan }
        let start = monthEnd[t - 12], end = monthEnd[t - 1]
        guard start.isFinite, end.isFinite, start > 0 else { return .nan }
        return end / start - 1
    }

    /// Annualized realized volatility: sample stdev of daily simple returns × √252.
    /// Uses the last `window` returns (NaNs skipped). Needs at least `minObservations`.
    public static func realizedVolatility(_ prices: [Double],
                                          window: Int = tradingDaysPerYear,
                                          minObservations: Int = 120,
                                          periodsPerYear: Int = tradingDaysPerYear) -> Double {
        let r = simpleReturns(prices).suffix(window).filter { !$0.isNaN }
        guard r.count >= minObservations else { return .nan }
        return Stats.standardDeviation(Array(r)) * Double(periodsPerYear).squareRoot()
    }

    /// Beta = cov(stock, market) / var(market) over the last `window` days where both
    /// returns are present. `stock` and `market` must be aligned on the same dates.
    public static func beta(stock: [Double], market: [Double],
                            window: Int = tradingDaysPerYear,
                            minObservations: Int = 120) -> Double {
        precondition(stock.count == market.count, "beta: series must be aligned")
        let rs = Array(simpleReturns(stock).suffix(window))
        let rm = Array(simpleReturns(market).suffix(window))
        var xs: [Double] = [], xm: [Double] = []
        for i in rs.indices where !rs[i].isNaN && !rm[i].isNaN {
            xs.append(rs[i]); xm.append(rm[i])
        }
        guard xs.count >= minObservations else { return .nan }
        let ms = VectorMath.mean(xs), mm = VectorMath.mean(xm)
        let ds = VectorMath.subtract(xs, scalar: ms), dm = VectorMath.subtract(xm, scalar: mm)
        let varM = VectorMath.dot(dm, dm)
        guard varM > 0 else { return .nan }
        return VectorMath.dot(ds, dm) / varM
    }

    /// Simple moving average; the first `window - 1` outputs are NaN.
    public static func movingAverage(_ x: [Double], window: Int) -> [Double] {
        guard window > 0 else { return x }
        var out = [Double](repeating: .nan, count: x.count)
        var sum = 0.0, count = 0
        for i in x.indices {
            sum += x[i]; count += 1
            if count > window { sum -= x[i - window]; count -= 1 }
            if count == window { out[i] = sum / Double(window) }
        }
        return out
    }

    // MARK: Performance statistics (periodic returns, e.g. monthly)

    /// Growth of $1: c[i] = Π(1 + r[0...i]). NaN returns count as 0 (flat).
    public static func cumulative(_ r: [Double]) -> [Double] {
        var w = 1.0
        return r.map { w *= 1 + ($0.isNaN ? 0 : $0); return w }
    }

    /// Maximum peak-to-trough decline of a wealth curve, as a positive fraction.
    /// The curve implicitly starts at 1.0 before the first point.
    public static func maxDrawdown(wealth: [Double]) -> Double {
        var peak = 1.0, mdd = 0.0
        for w in wealth {
            peak = max(peak, w)
            mdd = max(mdd, 1 - w / peak)
        }
        return mdd
    }

    public static func maxDrawdown(returns r: [Double]) -> Double {
        maxDrawdown(wealth: cumulative(r))
    }

    /// Geometric annualized return: (Π(1 + r))^(periodsPerYear / n) - 1.
    public static func annualizedReturn(_ r: [Double], periodsPerYear: Int = 12) -> Double {
        let v = r.filter { !$0.isNaN }
        guard !v.isEmpty else { return .nan }
        let growth = v.reduce(1.0) { $0 * (1 + $1) }
        guard growth > 0 else { return -1 }
        return pow(growth, Double(periodsPerYear) / Double(v.count)) - 1
    }

    public static func annualizedVolatility(_ r: [Double], periodsPerYear: Int = 12) -> Double {
        Stats.standardDeviation(r.filter { !$0.isNaN }) * Double(periodsPerYear).squareRoot()
    }

    /// Annualized Sharpe ratio: mean(r - rf) / sd(r) × √periodsPerYear.
    /// `riskFreePerPeriod` defaults to 0.
    public static func sharpe(_ r: [Double], periodsPerYear: Int = 12, riskFreePerPeriod: Double = 0) -> Double {
        let v = r.filter { !$0.isNaN }.map { $0 - riskFreePerPeriod }
        let sd = Stats.standardDeviation(v)
        // Treat floating-point noise around zero as zero volatility.
        guard sd > 1e-12, sd.isFinite else { return .nan }
        return VectorMath.mean(v) / sd * Double(periodsPerYear).squareRoot()
    }
}
