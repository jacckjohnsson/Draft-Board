import Foundation

/// Yahoo Finance chart endpoint (unofficial). Backtest only.
/// GET https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?range=10y&interval=1d
public struct YahooHistoryProvider: HistoryProvider {
    public let sourceName = "Yahoo Finance"
    let http: HTTPClient
    let scheduler: RequestScheduler
    let range: String

    public init(http: HTTPClient = URLSessionHTTPClient(), scheduler: RequestScheduler, range: String = "10y") {
        self.http = http
        self.scheduler = scheduler
        self.range = range
    }

    struct ChartResponse: Decodable {
        struct Chart: Decodable {
            let result: [Result]?
            let error: ChartError?
        }
        struct ChartError: Decodable { let code: String?; let description: String? }
        struct Result: Decodable {
            let timestamp: [Double]?
            let indicators: Indicators
        }
        struct Indicators: Decodable {
            let quote: [Quote]?
            let adjclose: [AdjClose]?
        }
        struct Quote: Decodable { let close: [Double?]? }
        struct AdjClose: Decodable { let adjclose: [Double?]? }
        let chart: Chart
    }

    public func history(for ticker: String) async throws -> HistorySeries {
        let symbol = SymbolFormat.dashed(ticker)
        let url = URL.make("https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)",
                           ["range": range, "interval": "1d", "events": "split,div"])
        let data = try await scheduler.run {
            // Yahoo rejects requests without a browser-like User-Agent.
            try await http.get(url, headers: ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"])
        }
        return try Self.parse(data, ticker: ticker)
    }

    static func parse(_ data: Data, ticker: String) throws -> HistorySeries {
        let r: ChartResponse
        do { r = try JSONDecoder().decode(ChartResponse.self, from: data) }
        catch { throw HTTPError.decoding("yahoo chart: \(error)") }
        if let e = r.chart.error { throw HTTPError.decoding(e.description ?? e.code ?? "chart error") }
        guard let res = r.chart.result?.first, let ts = res.timestamp, !ts.isEmpty else {
            throw ProviderError.emptyResponse("No Yahoo history for \(ticker)")
        }
        let closes = res.indicators.quote?.first?.close ?? []
        let adj = res.indicators.adjclose?.first?.adjclose ?? closes
        var dates: [String] = [], a: [Double] = [], c: [Double] = []
        for (i, t) in ts.enumerated() {
            let d = TradingCalendar.isoString(Date(timeIntervalSince1970: t))
            let av = i < adj.count ? adj[i] : nil
            let cv = i < closes.count ? closes[i] : nil
            guard let av, av > 0 else { continue }
            // Yahoo occasionally repeats the last bar; keep the latest value per date.
            if dates.last == d { a[a.count - 1] = av; c[c.count - 1] = cv ?? .nan; continue }
            dates.append(d); a.append(av); c.append(cv ?? .nan)
        }
        return HistorySeries(ticker: ticker, dates: dates, adjustedCloses: a, closes: c)
    }
}
