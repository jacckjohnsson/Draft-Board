import Foundation

public enum WeightingScheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case equal
    /// Weight proportional to the stock's composite percentile in the universe (min 1).
    case score
    public var id: String { rawValue }
    public var displayName: String { self == .equal ? "Equal weight" : "Score weighted" }
}

public enum ShareRounding: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Round down to whole shares; the remainder stays as cash.
    case whole
    /// Fractional shares to 4 decimals.
    case fractional
    public var id: String { rawValue }
}

public struct Holding: Sendable, Hashable, Identifiable {
    public var id: String { ticker }
    public var ticker: String
    public var weight: Double
    public var price: Double
    public var shares: Double
    public var value: Double { shares * price }
}

public struct ShareAllocation: Sendable, Hashable {
    public var holdings: [Holding]
    public var invested: Double
    public var cash: Double
    /// Tickers dropped because they had no usable price.
    public var unpriced: [String]
}

public enum Portfolio {

    /// Target weights summing to 1. `percentiles` maps ticker → composite percentile (0–100);
    /// tickers without a score get the median (50) under score weighting.
    public static func weights(tickers: [String], scheme: WeightingScheme,
                               percentiles: [String: Double] = [:]) -> [String: Double] {
        guard !tickers.isEmpty else { return [:] }
        switch scheme {
        case .equal:
            let w = 1 / Double(tickers.count)
            return Dictionary(uniqueKeysWithValues: tickers.map { ($0, w) })
        case .score:
            let raw = tickers.map { max(1, percentiles[$0] ?? 50) }
            let total = raw.reduce(0, +)
            return Dictionary(uniqueKeysWithValues: zip(tickers, raw.map { $0 / total }))
        }
    }

    /// Converts weights to share counts for a portfolio of `amount` dollars.
    public static func allocate(weights: [String: Double], prices: [String: Double],
                                amount: Double, rounding: ShareRounding) -> ShareAllocation {
        var holdings: [Holding] = []
        var unpriced: [String] = []
        // Re-normalize over priced tickers so an unpriced name doesn't leave a hole.
        let priced = weights.filter { (prices[$0.key] ?? 0) > 0 && (prices[$0.key] ?? .nan).isFinite }
        unpriced = weights.keys.filter { priced[$0] == nil }.sorted()
        let total = priced.values.reduce(0, +)
        for (t, w) in priced.sorted(by: { $0.key < $1.key }) {
            let p = prices[t]!
            let nw = total > 0 ? w / total : 0
            let exact = amount * nw / p
            let shares: Double
            switch rounding {
            case .whole: shares = exact.rounded(.down)
            case .fractional: shares = (exact * 10_000).rounded(.down) / 10_000
            }
            holdings.append(Holding(ticker: t, weight: nw, price: p, shares: shares))
        }
        let invested = holdings.reduce(0) { $0 + $1.value }
        return ShareAllocation(holdings: holdings, invested: invested, cash: amount - invested, unpriced: unpriced)
    }

    /// CSV in Shock Lab's import format: `ticker,shares`.
    public static func shockLabCSV(_ allocation: ShareAllocation, rounding: ShareRounding) -> String {
        var lines = ["ticker,shares"]
        for h in allocation.holdings where h.shares > 0 {
            let s: String
            switch rounding {
            case .whole: s = String(Int(h.shares))
            case .fractional: s = formatFractional(h.shares)
            }
            lines.append("\(csvEscape(h.ticker)),\(s)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func formatFractional(_ x: Double) -> String {
        var s = String(format: "%.4f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func csvEscape(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

// MARK: - Basket diagnostics

public struct BasketWarning: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case highCorrelation(a: String, b: String, correlation: Double)
        case sectorConcentration(sector: String, share: Double)
    }
    public var kind: Kind
    public var id: String {
        switch kind {
        case let .highCorrelation(a, b, _): return "corr-\(a)-\(b)"
        case let .sectorConcentration(s, _): return "sector-\(s)"
        }
    }
}

public enum BasketDiagnostics {
    public static let correlationLimit = 0.8
    public static let sectorLimit = 0.4

    /// Sector share of the basket by weight (equal weight when `weights` is empty).
    public static func sectorShares(tickers: [String], sectors: [String: String],
                                    weights: [String: Double] = [:]) -> [String: Double] {
        guard !tickers.isEmpty else { return [:] }
        var out: [String: Double] = [:]
        let w = weights.isEmpty ? Portfolio.weights(tickers: tickers, scheme: .equal) : weights
        for t in tickers { out[sectors[t] ?? "Unknown", default: 0] += w[t] ?? 0 }
        return out
    }

    public static func warnings(tickers: [String], correlation: [[Double]],
                                sectors: [String: String], weights: [String: Double] = [:]) -> [BasketWarning] {
        var out: [BasketWarning] = []
        for i in tickers.indices {
            for j in (i + 1)..<tickers.count {
                let c = correlation[i][j]
                if c.isFinite && c > correlationLimit {
                    out.append(BasketWarning(kind: .highCorrelation(a: tickers[i], b: tickers[j], correlation: c)))
                }
            }
        }
        for (s, share) in sectorShares(tickers: tickers, sectors: sectors, weights: weights).sorted(by: { $0.key < $1.key })
        where share > sectorLimit + 1e-12 {
            out.append(BasketWarning(kind: .sectorConcentration(sector: s, share: share)))
        }
        return out
    }
}

// MARK: - Source consistency

public enum ConsistencyCheck {
    public struct Mismatch: Sendable, Hashable {
        public var ticker: String
        public var date: String
        public var primary: Double
        public var secondary: Double
        public var relativeDifference: Double
    }

    /// Compares split-adjusted closes from two sources on their most recent `days` common
    /// dates and reports the worst date per ticker where they differ by more than `tolerance`.
    public static func compare(primary: [String: [String: Double]], secondary: [String: [String: Double]],
                               days: Int = 5, tolerance: Double = 0.01) -> [Mismatch] {
        var out: [Mismatch] = []
        for (t, a) in primary {
            guard let b = secondary[t] else { continue }
            let common = Set(a.keys).intersection(b.keys).sorted().suffix(days)
            var worst: Mismatch?
            for d in common {
                let x = a[d]!, y = b[d]!
                guard x > 0, y > 0 else { continue }
                let rel = abs(x - y) / y
                if rel > tolerance && rel > (worst?.relativeDifference ?? 0) {
                    worst = Mismatch(ticker: t, date: d, primary: x, secondary: y, relativeDifference: rel)
                }
            }
            if let w = worst { out.append(w) }
        }
        return out.sorted { $0.ticker < $1.ticker }
    }
}
