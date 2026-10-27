import SwiftUI
import SwiftData
import Charts
import FactorEngine
import FactorData

struct StockDetailView: View {
    let ticker: String
    @Environment(DataCoordinator.self) private var data
    @Environment(ScoringModel.self) private var scoring
    @Environment(\.modelContext) private var context
    @Query private var watchlist: [WatchlistItem]
    @State private var range: PriceRange = .oneYear
    @State private var hapticTrigger = 0

    enum PriceRange: String, CaseIterable, Identifiable {
        case oneMonth = "1M", threeMonths = "3M", sixMonths = "6M", oneYear = "1Y", all = "All"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .oneMonth: return 21
            case .threeMonths: return 63
            case .sixMonths: return 126
            case .oneYear: return 252
            case .all: return nil
            }
        }
    }

    private var dataset: LiveDataset { data.dataset }
    private var score: StockScore? { scoring.scoresByTicker[ticker] }
    private var fundamentals: Fundamentals? { dataset.fundamentals[ticker] }
    private var inWatchlist: Bool { watchlist.contains { $0.ticker == ticker } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                SourceBadge(text: "Prices: Massive · Fundamentals: FMP")
                factorSection
                priceSection
                fundamentalsSection
                metricsSection
            }
            .padding()
        }
        .navigationTitle(ticker)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { toggleWatch() } label: {
                    Label(inWatchlist ? "Remove from watchlist" : "Add to watchlist",
                          systemImage: inWatchlist ? "star.fill" : "star")
                }
            }
        }
        .sensoryFeedback(.success, trigger: hapticTrigger)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dataset.name(ticker)).font(.title2.bold())
            Text(dataset.sector(ticker)).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Format.money(dataset.lastClose(ticker))).font(.title3.monospacedDigit())
                if let s = score {
                    ScoreBadge(score: s.composite)
                    Text("Rank \(s.rank) of \(scoring.result?.scores.count ?? 0)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let s = score {
                HStack(spacing: 4) {
                    Text("Scores better than \(Int(s.sectorPercentile.rounded()))% of its sector")
                    InfoButton(Explain.sectorPercentile)
                }
                .font(.subheadline)
                ProgressView(value: s.sectorPercentile / 100)
                    .tint(s.sectorPercentile >= 50 ? .green : .orange)
                    .accessibilityLabel("Sector percentile \(Int(s.sectorPercentile))")
            } else if let ex = scoring.result?.excluded.first(where: { $0.ticker == ticker }) {
                Label("Not scored: \(ex.missingMetrics.count) metrics missing (\(Format.percent(ex.coverage, digits: 0)) coverage)",
                      systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Factor scores vs sector median

    private struct FactorBar: Identifiable {
        var id: String { factor.rawValue + series }
        let factor: Factor
        let series: String
        let value: Double
    }

    @ViewBuilder
    private var factorSection: some View {
        let factors = data.settings.weights.activeFactors
        let medians = scoring.result?.sectorMedians[dataset.sector(ticker)] ?? [:]
        let bars: [FactorBar] = factors.flatMap { f -> [FactorBar] in
            var out: [FactorBar] = []
            if let v = score?.factorScores[f] { out.append(FactorBar(factor: f, series: ticker, value: v)) }
            if let m = medians[f] { out.append(FactorBar(factor: f, series: "Sector median", value: m)) }
            return out
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Factor scores vs sector").font(.headline)
                InfoButton(Explain.composite)
            }
            if bars.isEmpty {
                Text("Factor scores appear once this stock has enough data.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(bars) { b in
                    BarMark(x: .value("Factor", b.factor.displayName), y: .value("Score", b.value))
                        .foregroundStyle(by: .value("Series", b.series))
                        .position(by: .value("Series", b.series))
                }
                .chartYAxisLabel("z-score")
                .frame(height: 200)
                .accessibilityLabel("Factor scores compared with the sector median")
            }
        }
    }

    // MARK: Price chart

    private struct PricePoint: Identifiable {
        var id: String { iso + series }
        let iso: String
        let date: Date
        let value: Double
        let series: String
        init(date: String, value: Double, series: String) {
            self.iso = date
            self.date = TradingCalendar.date(fromISO: date) ?? .now
            self.value = value
            self.series = series
        }
    }

    @ViewBuilder
    private var priceSection: some View {
        let series = dataset.priceSeries(ticker)
        VStack(alignment: .leading, spacing: 8) {
            Text("Price").font(.headline)
            Picker("Range", selection: $range) {
                ForEach(PriceRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if series.count < 2 {
                ContentUnavailableView("No price history yet", systemImage: "chart.line.downtrend.xyaxis",
                                       description: Text("Prices load from Massive in the background."))
                    .frame(height: 200)
            } else {
                let points = pricePoints(series)
                Chart(points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Price", p.value))
                        .foregroundStyle(by: .value("Series", p.series))
                        .lineStyle(StrokeStyle(lineWidth: p.series == "Close" ? 2 : 1.2))
                }
                .chartForegroundStyleScale(["Close": Color.accentColor, "50-day MA": Color.orange, "200-day MA": Color.purple])
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 220)
                .accessibilityLabel("Price chart with 50 and 200 day moving averages")
                if series.count < 200 {
                    Text("The 200-day average needs 200 trading days of history (\(series.count) so far).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pricePoints(_ series: [(date: String, close: Double)]) -> [PricePoint] {
        let closes = series.map(\.close)
        let ma50 = Returns.movingAverage(closes, window: 50)
        let ma200 = Returns.movingAverage(closes, window: 200)
        let start = range.days.map { max(0, series.count - $0) } ?? 0
        var out: [PricePoint] = []
        for i in start..<series.count {
            let d = series[i].date
            out.append(PricePoint(date: d, value: closes[i], series: "Close"))
            if ma50[i].isFinite { out.append(PricePoint(date: d, value: ma50[i], series: "50-day MA")) }
            if ma200[i].isFinite { out.append(PricePoint(date: d, value: ma200[i], series: "200-day MA")) }
        }
        return out
    }

    // MARK: Fundamentals grid

    private struct Cell: Identifiable {
        var id: String { title }
        let title: String
        let value: String
        let info: Explain.Entry?
    }

    @ViewBuilder
    private var fundamentalsSection: some View {
        let f = fundamentals
        let pm = dataset.priceMetrics[ticker]
        let cells: [Cell] = [
            Cell(title: "Market cap", value: Format.marketCap(f?.marketCap), info: Explain.metric(.marketCap)),
            Cell(title: "P/E", value: Format.number(f?.peRatio, digits: 1), info: Explain.peRatio),
            Cell(title: "Earnings yield", value: Format.percent(f?.metrics[.earningsYield]), info: Explain.metric(.earningsYield)),
            Cell(title: "EV/EBITDA", value: Format.number(f?.evToEbitda, digits: 1), info: Explain.metric(.ebitdaToEV)),
            Cell(title: "Book-to-market", value: Format.number(f?.metrics[.bookToMarket], digits: 3), info: Explain.metric(.bookToMarket)),
            Cell(title: "ROE", value: Format.percent(f?.roe), info: Explain.metric(.roe)),
            Cell(title: "Gross margin", value: Format.percent(f?.grossMargin), info: Explain.metric(.grossMargin)),
            Cell(title: "Debt/equity", value: Format.number(f?.debtToEquity), info: Explain.metric(.debtToEquity)),
            Cell(title: "Dividend yield", value: Format.percent(f?.dividendYield, digits: 2), info: Explain.dividendYield),
            Cell(title: "Beta (1y vs SPY)", value: Format.number(pm?.beta), info: Explain.metric(.beta)),
            Cell(title: "Volatility (1y)", value: Format.percent(pm?.volatility), info: Explain.metric(.volatility)),
            Cell(title: "Momentum (12-1)", value: Format.percent(pm?.momentum12_1), info: Explain.metric(.momentum12_1)),
        ]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fundamentals").font(.headline)
                Spacer()
                if let f { Text("FMP · \(Format.relative(f.fetchedAt))").font(.caption2).foregroundStyle(.secondary) }
            }
            if f == nil {
                Label(dataset.fundamentalsFailures[ticker] ?? "Fundamentals haven't loaded yet.",
                      systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(cells) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(c.title).font(.caption).foregroundStyle(.secondary)
                            if let info = c.info { InfoButton(info) }
                        }
                        Text(c.value)
                            .font(.body.monospacedDigit().weight(.medium))
                            .foregroundStyle(c.value == "–" ? .secondary : .primary)
                            .accessibilityLabel(c.value == "–" ? "missing" : c.value)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: Metric z-scores

    @ViewBuilder
    private var metricsSection: some View {
        if let s = score {
            let metrics = data.settings.weights.activeFactors.flatMap(\.metrics)
            VStack(alignment: .leading, spacing: 8) {
                Text("Metric scores").font(.headline)
                ForEach(metrics, id: \.self) { m in
                    HStack {
                        Text(m.displayName).font(.subheadline)
                        InfoButton(Explain.metric(m))
                        Spacer()
                        if let z = s.metricScores[m] {
                            Text(String(format: "%+.2f", z)).monospacedDigit()
                                .foregroundStyle(z >= 0 ? .green : .red)
                        } else {
                            Label("Missing", systemImage: "exclamationmark.circle")
                                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Text("Scores are z-scores within \(data.settings.neutralization == .sector ? "the stock's sector" : "the whole universe"), with higher always better.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func toggleWatch() {
        if inWatchlist {
            for item in watchlist where item.ticker == ticker { context.delete(item) }
        } else {
            context.insert(WatchlistItem(ticker: ticker))
            hapticTrigger += 1
        }
        try? context.save()
    }
}
