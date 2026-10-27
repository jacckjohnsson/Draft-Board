import Foundation

/// Financial Modeling Prep "stable" API. Two calls per ticker:
///   /stable/profile?symbol=     → name, sector, industry, market cap, beta, price, dividend
///   /stable/ratios-ttm?symbol=  → P/E, P/B, EV/EBITDA, gross margin, D/E, dividend yield, ROE inputs
/// The free plan allows 250 calls/day, so the scheduler carries a daily cap and the
/// sync resumes the next day where it stopped.
public struct FMPProvider: FundamentalsProvider {
    public let sourceName = "Financial Modeling Prep"
    public static let baseURL = "https://financialmodelingprep.com/stable"

    let apiKey: @Sendable () -> String?
    let http: HTTPClient
    let scheduler: RequestScheduler

    public init(apiKey: @escaping @Sendable () -> String?, http: HTTPClient = URLSessionHTTPClient(),
                scheduler: RequestScheduler) {
        self.apiKey = apiKey
        self.http = http
        self.scheduler = scheduler
    }

    public func fundamentals(for ticker: String) async throws -> Fundamentals {
        guard let k = apiKey(), !k.isEmpty else { throw ProviderError.missingAPIKey(provider: sourceName) }
        let symbol = SymbolFormat.dashed(ticker)
        let profileURL = URL.make("\(Self.baseURL)/profile", ["symbol": symbol, "apikey": k])
        let ratiosURL = URL.make("\(Self.baseURL)/ratios-ttm", ["symbol": symbol, "apikey": k])
        let profile = try await scheduler.run { try await http.get(profileURL, headers: [:]) }
        let ratios = try await scheduler.run { try await http.get(ratiosURL, headers: [:]) }
        return try Self.parse(profile: profile, ratios: ratios, ticker: ticker)
    }

    /// FMP returns an array with one object. Field names changed between the legacy v3
    /// API and "stable", so each value is looked up under every known spelling.
    static func parse(profile: Data, ratios: Data, ticker: String, now: Date = Date()) throws -> Fundamentals {
        let p = try firstObject(profile, label: "profile")
        let r = (try? firstObject(ratios, label: "ratios")) ?? [:]

        func num(_ o: [String: Any], _ keys: String...) -> Double? {
            for k in keys {
                if let v = o[k] as? Double, v.isFinite { return v }
                if let v = o[k] as? Int { return Double(v) }
                if let s = o[k] as? String, let v = Double(s), v.isFinite { return v }
            }
            return nil
        }
        func str(_ o: [String: Any], _ k: String) -> String? {
            (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        let price = num(p, "price")
        var dividendYield = num(r, "dividendYieldTTM", "dividendYielTTM", "dividendYieldPercentageTTM")
        if dividendYield == nil, let d = num(p, "lastDividend", "lastDiv"), let price, price > 0 {
            dividendYield = d / price
        }
        var roe = num(r, "returnOnEquityTTM")
        if roe == nil, let ni = num(r, "netIncomePerShareTTM"), let eq = num(r, "shareholdersEquityPerShareTTM"), eq != 0 {
            roe = ni / eq
        }

        return Fundamentals(
            ticker: ticker,
            name: str(p, "companyName"),
            sector: str(p, "sector"),
            industry: str(p, "industry"),
            marketCap: num(p, "marketCap", "mktCap"),
            price: price,
            beta: num(p, "beta"),
            peRatio: num(r, "priceToEarningsRatioTTM", "peRatioTTM", "priceEarningsRatioTTM"),
            priceToBook: num(r, "priceToBookRatioTTM", "priceBookValueRatioTTM"),
            evToEbitda: num(r, "enterpriseValueMultipleTTM", "evToEBITDATTM"),
            roe: roe,
            grossMargin: num(r, "grossProfitMarginTTM"),
            debtToEquity: num(r, "debtToEquityRatioTTM", "debtEquityRatioTTM"),
            dividendYield: dividendYield,
            fetchedAt: now
        )
    }

    static func firstObject(_ data: Data, label: String) throws -> [String: Any] {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { throw HTTPError.decoding("FMP \(label): \(error.localizedDescription)") }
        if let arr = json as? [[String: Any]] {
            guard let first = arr.first else { throw ProviderError.emptyResponse("FMP \(label) was empty") }
            return first
        }
        if let obj = json as? [String: Any] {
            if let msg = obj["Error Message"] as? String {
                if msg.localizedCaseInsensitiveContains("limit") { throw HTTPError.rateLimited(retryAfter: nil) }
                throw HTTPError.client(status: 200, body: msg)
            }
            return obj
        }
        throw HTTPError.decoding("FMP \(label): unexpected JSON")
    }
}
