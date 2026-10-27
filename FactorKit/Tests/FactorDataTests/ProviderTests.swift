import XCTest
@testable import FactorData
@testable import FactorEngine

/// Serves canned responses by URL substring.
final class MockHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    var routes: [(String, Result<Data, HTTPError>)] = []
    private(set) var requested: [URL] = []
    private(set) var headers: [[String: String]] = []

    func on(_ fragment: String, json: String) { routes.append((fragment, .success(Data(json.utf8)))) }
    func on(_ fragment: String, error: HTTPError) { routes.append((fragment, .failure(error))) }

    func get(_ url: URL, headers h: [String: String]) async throws -> Data {
        let match = lock.withLock {
            requested.append(url); headers.append(h)
            return routes.first { url.absoluteString.contains($0.0) }
        }
        guard let match else { throw HTTPError.notFound }
        return try match.1.get()
    }
}

final class ProviderTests: XCTestCase {
    func scheduler() -> RequestScheduler { RequestScheduler(name: "t", config: .init(callsPerMinute: 1000), clock: TestClock()) }

    func testMassiveGroupedDailyParsingAndRequest() async throws {
        let http = MockHTTP()
        http.on("/v2/aggs/grouped/locale/us/market/stocks/2024-03-01", json: """
        {"adjusted":false,"queryCount":3,"resultsCount":3,"status":"OK","results":[
          {"T":"AAPL","o":1,"h":2,"l":0.5,"c":179.66,"v":73488997,"vw":179.9,"n":1,"t":1709326800000},
          {"T":"OTCX","c":1.0,"v":1,"t":1709326800000,"otc":true},
          {"T":"BAD","c":0,"t":1709326800000}
        ]}
        """)
        let p = MassiveProvider(apiKey: { "KEY" }, http: http, scheduler: scheduler())
        let bars = try await p.dailyBars(for: "2024-03-01")
        XCTAssertEqual(bars?.closes, ["AAPL": 179.66])
        XCTAssertEqual(bars?.volumes["AAPL"], 73488997)
        let url = http.requested[0].absoluteString
        XCTAssertTrue(url.hasPrefix("https://api.massive.com/v2/aggs/grouped/locale/us/market/stocks/2024-03-01?"))
        XCTAssertTrue(url.contains("adjusted=false"))
        XCTAssertFalse(url.contains("KEY"), "key goes in the Authorization header, not the URL")
        XCTAssertEqual(http.headers[0]["Authorization"], "Bearer KEY")
    }

    func testMassiveHolidayReturnsNil() async throws {
        let http = MockHTTP()
        http.on("stocks/2024-12-25", json: #"{"adjusted":false,"queryCount":0,"resultsCount":0,"status":"OK"}"#)
        let p = MassiveProvider(apiKey: { "K" }, http: http, scheduler: scheduler())
        let bars = try await p.dailyBars(for: "2024-12-25")
        XCTAssertNil(bars)
    }

    func testMassiveMissingKey() async {
        let p = MassiveProvider(apiKey: { nil }, http: MockHTTP(), scheduler: scheduler())
        do { _ = try await p.dailyBars(for: "2024-03-01"); XCTFail() }
        catch { XCTAssertEqual(error as? ProviderError, .missingAPIKey(provider: "Massive")) }
    }

    func testMassiveSplitsPagination() async throws {
        let http = MockHTTP()
        http.on("cursor=2", json: """
        {"status":"OK","results":[{"adjustment_type":"forward_split","execution_date":"2024-06-10","historical_adjustment_factor":0.1,"id":"b","split_from":1,"split_to":10,"ticker":"NVDA"}]}
        """)
        http.on("/stocks/v1/splits", json: """
        {"status":"OK","next_url":"https://api.massive.com/stocks/v1/splits?cursor=2","results":[{"adjustment_type":"forward_split","execution_date":"2024-06-07","id":"a","split_from":1,"split_to":4,"ticker":"AVGO"}]}
        """)
        let p = MassiveProvider(apiKey: { "K" }, http: http, scheduler: scheduler())
        let s = try await p.splits(since: "2024-01-01")
        XCTAssertEqual(s.map(\.ticker), ["AVGO", "NVDA"])
        XCTAssertEqual(s[1].priceFactor, 0.1, accuracy: 1e-12)
        XCTAssertTrue(http.requested[0].absoluteString.contains("execution_date.gte=2024-01-01"))
    }

    func testMassiveTickerAggs() async throws {
        let http = MockHTTP()
        // 2024-03-01 00:00 New York = 05:00 UTC = 1709269200000 ms
        http.on("/v2/aggs/ticker/BRK.B/range/1/day/", json: #"{"results":[{"c":400.5,"t":1709269200000}]}"#)
        let p = MassiveProvider(apiKey: { "K" }, http: http, scheduler: scheduler())
        let h = try await p.tickerHistory("BRK-B", from: "2024-01-01", to: "2024-03-01")
        XCTAssertEqual(h, ["2024-03-01": 400.5])
    }

    func testSplitAdjustment() {
        // 2-for-1 split executing 2024-01-03: earlier prices halve, later ones unchanged.
        let raw = ["2024-01-02": 200.0, "2024-01-03": 101.0, "2024-01-04": 102.0]
        let split = SplitEvent(id: "x", ticker: "X", executionDate: "2024-01-03", splitFrom: 1, splitTo: 2)
        let adj = SplitAdjuster.adjust(series: raw, splits: [split])
        XCTAssertEqual(adj["2024-01-02"], 100)
        XCTAssertEqual(adj["2024-01-03"], 101)
        // Two splits compound.
        let s2 = SplitEvent(id: "y", ticker: "X", executionDate: "2024-01-04", splitFrom: 1, splitTo: 3)
        XCTAssertEqual(SplitAdjuster.adjust(series: raw, splits: [split, s2])["2024-01-02"]!, 200.0 / 6, accuracy: 1e-12)
    }

    func testYahooParsing() async throws {
        let http = MockHTTP()
        // 2024-01-02 and 2024-01-03 14:30 UTC, one null value.
        http.on("/v8/finance/chart/BRK-B", json: """
        {"chart":{"result":[{"meta":{},"timestamp":[1704205800,1704292200,1704378600],
          "indicators":{"quote":[{"close":[100.0,101.0,null]}],"adjclose":[{"adjclose":[98.0,99.0,null]}]}}],"error":null}}
        """)
        let y = YahooHistoryProvider(http: http, scheduler: scheduler())
        let h = try await y.history(for: "BRK.B")
        XCTAssertEqual(h.dates, ["2024-01-02", "2024-01-03"])
        XCTAssertEqual(h.adjustedCloses, [98, 99])
        XCTAssertEqual(h.closes, [100, 101])
        XCTAssertTrue(http.requested[0].absoluteString.contains("range=10y"))
        XCTAssertNotNil(http.headers[0]["User-Agent"])
    }

    func testYahooErrorPayload() {
        let data = Data(#"{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found, symbol may be delisted"}}}"#.utf8)
        XCTAssertThrowsError(try YahooHistoryProvider.parse(data, ticker: "ZZZ"))
    }

    func testFMPParsingStableFieldNames() async throws {
        let http = MockHTTP()
        http.on("/stable/profile", json: """
        [{"symbol":"AAPL","price":200.0,"marketCap":3000000000000,"beta":1.2,"lastDividend":1.0,
          "companyName":"Apple Inc.","sector":"Technology","industry":"Consumer Electronics"}]
        """)
        http.on("/stable/ratios-ttm", json: """
        [{"symbol":"AAPL","grossProfitMarginTTM":0.46,"priceToEarningsRatioTTM":30.0,"priceToBookRatioTTM":50.0,
          "debtToEquityRatioTTM":1.5,"dividendYieldTTM":0.005,"enterpriseValueMultipleTTM":20.0,
          "netIncomePerShareTTM":6.0,"shareholdersEquityPerShareTTM":4.0}]
        """)
        let fmp = FMPProvider(apiKey: { "K" }, http: http, scheduler: scheduler())
        let f = try await fmp.fundamentals(for: "AAPL")
        XCTAssertEqual(f.name, "Apple Inc.")
        XCTAssertEqual(f.marketCap, 3e12)
        XCTAssertEqual(f.peRatio, 30)
        XCTAssertEqual(f.roe!, 1.5, accuracy: 1e-12)          // derived 6 / 4
        XCTAssertEqual(f.dividendYield, 0.005)
        let m = f.metrics
        XCTAssertEqual(m[.earningsYield]!, 1.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(m[.ebitdaToEV]!, 0.05, accuracy: 1e-12)
        XCTAssertEqual(m[.bookToMarket]!, 0.02, accuracy: 1e-12)
        XCTAssertTrue(http.requested.allSatisfy { $0.absoluteString.contains("apikey=K") })
    }

    func testFMPLegacyNamesAndMissingFields() throws {
        let profile = Data(#"[{"symbol":"X","mktCap":5e9,"price":10,"lastDiv":0.5}]"#.utf8)
        let ratios = Data(#"[{"peRatioTTM":-5,"debtEquityRatioTTM":0.3,"returnOnEquityTTM":0.12}]"#.utf8)
        let f = try FMPProvider.parse(profile: profile, ratios: ratios, ticker: "X")
        XCTAssertEqual(f.marketCap, 5e9)
        XCTAssertEqual(f.dividendYield!, 0.05, accuracy: 1e-12)
        XCTAssertEqual(f.roe, 0.12)
        XCTAssertNil(f.grossMargin)
        XCTAssertNil(f.metrics[.grossMargin])
        XCTAssertEqual(f.metrics[.earningsYield]!, -0.2, accuracy: 1e-12)  // negative earnings → negative yield
    }

    func testFMPLimitMessageIsRateLimit() {
        let d = Data(#"{"Error Message":"Limit Reach . Please upgrade your plan"}"#.utf8)
        XCTAssertThrowsError(try FMPProvider.firstObject(d, label: "p")) { e in
            XCTAssertEqual(e as? HTTPError, .rateLimited(retryAfter: nil))
        }
    }

    func testHTTPStatusMapping() {
        XCTAssertThrowsError(try URLSessionHTTPClient.check(status: 429, retryAfter: "12", body: Data())) {
            XCTAssertEqual($0 as? HTTPError, .rateLimited(retryAfter: 12))
        }
        XCTAssertThrowsError(try URLSessionHTTPClient.check(status: 401, retryAfter: nil, body: Data())) {
            XCTAssertEqual($0 as? HTTPError, .unauthorized)
        }
        XCTAssertNoThrow(try URLSessionHTTPClient.check(status: 200, retryAfter: nil, body: Data()))
    }

    func testUniversesLoad() throws {
        let dow = try UniverseLoader.load(.dow30)
        XCTAssertEqual(dow.members.count, 30)
        let top = try UniverseLoader.load(.top100)
        XCTAssertEqual(top.members.count, 100)
        let sp = try UniverseLoader.load(.sp500)
        XCTAssertGreaterThan(sp.members.count, 495)
        XCTAssertTrue(sp.members.allSatisfy { !$0.sector.isEmpty })
        XCTAssertEqual(UniverseLoader.parseCustom("aapl, brk-b\nMSFT aapl $$"), ["AAPL", "BRK.B", "MSFT"])
    }
}
