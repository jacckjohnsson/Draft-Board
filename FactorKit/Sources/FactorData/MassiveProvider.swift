import Foundation

/// Massive (formerly Polygon.io) REST client.
/// Docs: https://massive.com/docs/rest/stocks/aggregates/daily-market-summary
///       https://massive.com/docs/rest/stocks/corporate-actions/splits
public struct MassiveProvider: PriceProvider {
    public let sourceName = "Massive"
    public static let baseURL = "https://api.massive.com"

    let apiKey: @Sendable () -> String?
    let http: HTTPClient
    let scheduler: RequestScheduler

    public init(apiKey: @escaping @Sendable () -> String?, http: HTTPClient = URLSessionHTTPClient(),
                scheduler: RequestScheduler) {
        self.apiKey = apiKey
        self.http = http
        self.scheduler = scheduler
    }

    private func key() throws -> String {
        guard let k = apiKey(), !k.isEmpty else { throw ProviderError.missingAPIKey(provider: sourceName) }
        return k
    }

    // MARK: Grouped daily

    struct GroupedResponse: Decodable {
        struct Bar: Decodable {
            let T: String
            let c: Double?
            let v: Double?
            let otc: Bool?
        }
        let status: String?
        let resultsCount: Int?
        let results: [Bar]?
    }

    /// GET /v2/aggs/grouped/locale/us/market/stocks/{date}?adjusted=false
    /// We request UNADJUSTED bars and apply splits ourselves (see `SplitAdjuster`), so a
    /// split after the download never leaves stale prices in the cache.
    public func dailyBars(for date: String) async throws -> DailyBars? {
        let k = try key()
        let url = URL.make("\(Self.baseURL)/v2/aggs/grouped/locale/us/market/stocks/\(date)",
                           ["adjusted": "false", "include_otc": "false"])
        let data = try await scheduler.run {
            try await http.get(url, headers: ["Authorization": "Bearer \(k)"])
        }
        return try Self.parseGrouped(data, date: date)
    }

    static func parseGrouped(_ data: Data, date: String) throws -> DailyBars? {
        let r: GroupedResponse
        do { r = try JSONDecoder().decode(GroupedResponse.self, from: data) }
        catch { throw HTTPError.decoding("grouped daily: \(error)") }
        let bars = r.results ?? []
        guard !bars.isEmpty else { return nil }
        var closes: [String: Double] = [:], volumes: [String: Double] = [:]
        closes.reserveCapacity(bars.count)
        for b in bars where b.otc != true {
            guard let c = b.c, c > 0 else { continue }
            closes[b.T] = c
            if let v = b.v { volumes[b.T] = v }
        }
        return DailyBars(date: date, closes: closes, volumes: volumes)
    }

    // MARK: Splits

    struct SplitsResponse: Decodable {
        struct Item: Decodable {
            let id: String?
            let ticker: String
            let execution_date: String
            let split_from: Double
            let split_to: Double
        }
        let results: [Item]?
        let next_url: String?
    }

    /// GET /stocks/v1/splits?execution_date.gte={since}, following `next_url` pages.
    public func splits(since: String) async throws -> [SplitEvent] {
        let k = try key()
        var url: URL? = URL.make("\(Self.baseURL)/stocks/v1/splits",
                                 ["execution_date.gte": since, "limit": "5000", "sort": "execution_date.asc"])
        var out: [SplitEvent] = []
        var pages = 0
        while let u = url, pages < 20 {
            let data = try await scheduler.run {
                try await http.get(u, headers: ["Authorization": "Bearer \(k)"])
            }
            let (events, next) = try Self.parseSplits(data)
            out += events
            url = next.flatMap(URL.init(string:))
            pages += 1
        }
        return out
    }

    static func parseSplits(_ data: Data) throws -> ([SplitEvent], String?) {
        let r: SplitsResponse
        do { r = try JSONDecoder().decode(SplitsResponse.self, from: data) }
        catch { throw HTTPError.decoding("splits: \(error)") }
        let events = (r.results ?? []).map {
            SplitEvent(id: $0.id ?? "\($0.ticker)-\($0.execution_date)", ticker: $0.ticker,
                       executionDate: $0.execution_date, splitFrom: $0.split_from, splitTo: $0.split_to)
        }
        return (events, r.next_url)
    }

    // MARK: Per-ticker bars (custom-ticker backfill only)

    struct AggsResponse: Decodable {
        struct Bar: Decodable { let c: Double?; let t: Double }
        let results: [Bar]?
    }

    /// GET /v2/aggs/ticker/{ticker}/range/1/day/{from}/{to}?adjusted=false
    public func tickerHistory(_ ticker: String, from: String, to: String) async throws -> [String: Double] {
        let k = try key()
        let t = SymbolFormat.massive(ticker)
        let url = URL.make("\(Self.baseURL)/v2/aggs/ticker/\(t)/range/1/day/\(from)/\(to)",
                           ["adjusted": "false", "sort": "asc", "limit": "50000"])
        let data = try await scheduler.run {
            try await http.get(url, headers: ["Authorization": "Bearer \(k)"])
        }
        return try Self.parseAggs(data)
    }

    static func parseAggs(_ data: Data) throws -> [String: Double] {
        let r: AggsResponse
        do { r = try JSONDecoder().decode(AggsResponse.self, from: data) }
        catch { throw HTTPError.decoding("aggregates: \(error)") }
        var out: [String: Double] = [:]
        for b in r.results ?? [] {
            guard let c = b.c, c > 0 else { continue }
            out[TradingCalendar.isoString(Date(timeIntervalSince1970: b.t / 1000))] = c
        }
        return out
    }
}
