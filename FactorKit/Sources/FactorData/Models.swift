import Foundation
import FactorEngine

/// One trading day of closes for every US stock, from Massive's grouped daily endpoint.
/// Prices are stored UNADJUSTED; `SplitAdjuster` applies splits at read time so the
/// cache never needs re-downloading when a new split happens.
public struct DailyBars: Codable, Sendable, Equatable {
    public var date: String
    public var closes: [String: Double]
    public var volumes: [String: Double]

    public init(date: String, closes: [String: Double], volumes: [String: Double] = [:]) {
        self.date = date
        self.closes = closes
        self.volumes = volumes
    }

    /// Keeps only the given tickers, to keep the cache small.
    public func filtered(to tickers: Set<String>) -> DailyBars {
        DailyBars(date: date, closes: closes.filter { tickers.contains($0.key) },
                  volumes: volumes.filter { tickers.contains($0.key) })
    }
}

public struct SplitEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var ticker: String
    /// First trading day on the post-split basis.
    public var executionDate: String
    public var splitFrom: Double
    public var splitTo: Double

    public init(id: String, ticker: String, executionDate: String, splitFrom: Double, splitTo: Double) {
        self.id = id
        self.ticker = ticker
        self.executionDate = executionDate
        self.splitFrom = splitFrom
        self.splitTo = splitTo
    }

    /// Multiply a pre-split price by this to put it on the post-split basis (2-for-1 → 0.5).
    public var priceFactor: Double { splitTo > 0 ? splitFrom / splitTo : 1 }
}

/// Fundamentals for one company. Every number is optional: providers omit fields
/// and the UI flags what is missing.
public struct Fundamentals: Codable, Sendable, Equatable {
    public var ticker: String
    public var name: String?
    public var sector: String?
    public var industry: String?
    public var marketCap: Double?
    public var price: Double?
    public var beta: Double?
    public var peRatio: Double?
    public var priceToBook: Double?
    public var evToEbitda: Double?
    public var roe: Double?
    public var grossMargin: Double?
    public var debtToEquity: Double?
    public var dividendYield: Double?
    public var fetchedAt: Date

    public init(ticker: String, name: String? = nil, sector: String? = nil, industry: String? = nil,
                marketCap: Double? = nil, price: Double? = nil, beta: Double? = nil, peRatio: Double? = nil,
                priceToBook: Double? = nil, evToEbitda: Double? = nil, roe: Double? = nil,
                grossMargin: Double? = nil, debtToEquity: Double? = nil, dividendYield: Double? = nil,
                fetchedAt: Date = Date()) {
        self.ticker = ticker; self.name = name; self.sector = sector; self.industry = industry
        self.marketCap = marketCap; self.price = price; self.beta = beta; self.peRatio = peRatio
        self.priceToBook = priceToBook; self.evToEbitda = evToEbitda; self.roe = roe
        self.grossMargin = grossMargin; self.debtToEquity = debtToEquity
        self.dividendYield = dividendYield; self.fetchedAt = fetchedAt
    }

    /// Raw factor-model inputs derived from these fundamentals.
    /// E/P, EBITDA/EV and B/M are reciprocals; a zero denominator leaves the metric missing.
    public var metrics: [Metric: Double] {
        var m: [Metric: Double] = [:]
        func inv(_ x: Double?) -> Double? { guard let x, x != 0, x.isFinite else { return nil }; return 1 / x }
        m[.earningsYield] = inv(peRatio)
        m[.ebitdaToEV] = inv(evToEbitda)
        m[.bookToMarket] = inv(priceToBook)
        m[.roe] = roe
        m[.grossMargin] = grossMargin
        m[.debtToEquity] = debtToEquity
        m[.marketCap] = marketCap
        return m.filter { $0.value.isFinite }
    }
}

/// Long daily history from Yahoo, for the backtest only.
public struct HistorySeries: Codable, Sendable, Equatable {
    public var ticker: String
    public var dates: [String]
    /// Split- and dividend-adjusted closes (Yahoo "adjclose"), used for returns.
    public var adjustedCloses: [Double]
    /// Split-adjusted (not dividend-adjusted) closes, used for the cross-source check.
    public var closes: [Double]
    public var fetchedAt: Date

    public init(ticker: String, dates: [String], adjustedCloses: [Double], closes: [Double], fetchedAt: Date = Date()) {
        self.ticker = ticker; self.dates = dates; self.adjustedCloses = adjustedCloses
        self.closes = closes; self.fetchedAt = fetchedAt
    }

    public var adjustedByDate: [String: Double] {
        Dictionary(zip(dates, adjustedCloses).filter { $0.1.isFinite }, uniquingKeysWith: { _, b in b })
    }
    public var closesByDate: [String: Double] {
        Dictionary(zip(dates, closes).filter { $0.1.isFinite }, uniquingKeysWith: { _, b in b })
    }
}

/// Symbol spellings differ by provider: Massive uses "BRK.B", Yahoo and FMP use "BRK-B".
public enum SymbolFormat {
    public static func massive(_ t: String) -> String { t.replacingOccurrences(of: "-", with: ".") }
    public static func dashed(_ t: String) -> String { t.replacingOccurrences(of: ".", with: "-") }
}

/// JSON coding that tolerates NaN/Infinity (they appear in backtest output and price panels).
public enum CacheCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
    public static func encode<T: Encodable>(_ v: T) throws -> Data { try encoder.encode(v) }
    public static func decode<T: Decodable>(_ t: T.Type, from d: Data) throws -> T { try decoder.decode(t, from: d) }
}
