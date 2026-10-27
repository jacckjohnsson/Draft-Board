import SwiftUI
import Charts
import FactorEngine
import FactorData

struct BacktestView: View {
    @Environment(DataCoordinator.self) private var data
    @State private var model = BacktestModel()

    private var settings: AppSettings { data.settings }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SourceBadge(text: "Yahoo Finance history · price-only factors")
                        .listRowSeparator(.hidden)
                    configSection
                }
                stateSection
                if let r = model.result {
                    resultSections(r)
                }
                limitationsSection
            }
            .navigationTitle("Backtest")
        }
    }

    // MARK: Configuration

    @ViewBuilder
    private var configSection: some View {
        let w = settings.weights.normalized(restrictedTo: [.momentum, .lowVolatility])
        VStack(alignment: .leading, spacing: 4) {
            Text("Scores stocks monthly on momentum and low volatility only, using your current weights:")
                .font(.callout)
            Text("Momentum \(Format.percent(w[.momentum], digits: 0)) · Low volatility \(Format.percent(w[.lowVolatility], digits: 0))")
                .font(.callout.weight(.semibold))
            Text("\(settings.universe.title) · \(settings.neutralization == .sector ? "sector-neutral" : "cross-sectional")")
                .font(.caption).foregroundStyle(.secondary)
        }
        Stepper(value: Binding(get: { settings.backtestYears }, set: { settings.backtestYears = $0 }), in: 3...10) {
            Text("Lookback: \(settings.backtestYears) years")
        }
        Button {
            Task { await model.run(coordinator: data) }
        } label: {
            Label(model.result == nil ? "Run backtest" : "Run again", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.state == .downloading || model.isRunning)
    }

    @ViewBuilder
    private var stateSection: some View {
        switch model.state {
        case .idle:
            if model.result == nil {
                Section {
                    ContentUnavailableView("No backtest yet", systemImage: "chart.xyaxis.line",
                                           description: Text("The first run downloads about 10 years of daily prices per stock from Yahoo Finance and caches them for a month."))
                }
            }
        case .downloading:
            Section { SyncBanner(progress: data.historyProgress, etaPerItem: 60 / Double(max(1, settings.yahooCallsPerMinute))) }
        case .running(let f):
            Section {
                VStack(alignment: .leading) {
                    Text("Running backtest…")
                    ProgressView(value: f)
                }
            }
        case .failed(let msg):
            Section {
                Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                if case .failed = data.historyProgress.phase {
                    Text("Yahoo Finance is unofficial and sometimes unavailable. Only this tab is affected: the Screener, Watchlist and Export keep working on Massive data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .done:
            if !model.historyFailures.isEmpty {
                Section {
                    Label("\(model.historyFailures.count) tickers had no Yahoo history and were left out.", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Results

    private struct LinePoint: Identifiable {
        var id: String { series + iso }
        let iso: String
        let date: Date
        let value: Double
        let series: String
    }

    private static func quintileName(_ q: Int, of n: Int) -> String {
        q == 0 ? "Q1 (top)" : (q == n - 1 ? "Q\(n) (bottom)" : "Q\(q + 1)")
    }

    @ViewBuilder
    private func resultSections(_ r: BacktestResult) -> some View {
        let dates = r.periodEnds.map { TradingCalendar.date(fromISO: $0) ?? .now }
        let n = r.cumulative.count

        if r.isTooShort {
            Section {
                Label("Only \(r.months) months of history were available. Results from less than 3 years are mostly noise. Treat them as illustrative only.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }

        Section {
            let points: [LinePoint] = (0..<n).flatMap { q -> [LinePoint] in
                r.cumulative[q].enumerated().map { i, v in
                    LinePoint(iso: r.periodEnds[i], date: dates[i], value: v, series: Self.quintileName(q, of: n))
                }
            }
            Chart(points) { p in
                LineMark(x: .value("Date", p.date), y: .value("Growth of $1", p.value))
                    .foregroundStyle(by: .value("Quintile", p.series))
            }
            .chartYScale(type: .log)
            .chartYAxisLabel("Growth of $1 (log)")
            .frame(height: 240)
            .accessibilityLabel("Cumulative return by quintile")
        } header: {
            HStack { Text("Quintile cumulative returns"); InfoButton(Explain.quintiles) }
        } footer: {
            Text("\(r.months) monthly rebalances, about \(Int(r.averageStocksPerRebalance)) stocks each, from \(model.tickersUsed) tickers.\(model.fromCache ? " Loaded from cache." : "")")
        }

        Section {
            let spread = r.spreadCumulative.enumerated().map { i, v in
                LinePoint(iso: r.periodEnds[i], date: dates[i], value: v - 1, series: "Q1 − Q\(n)")
            }
            Chart {
                ForEach(spread) { p in
                    AreaMark(x: .value("Date", p.date), y: .value("Cumulative spread", p.value))
                        .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.05)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", p.date), y: .value("Cumulative spread", p.value))
                }
                RuleMark(y: .value("Zero", 0.0)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4]))
            }
            .chartYAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.Percent(locale: .autoupdatingCurrent)) }
            .frame(height: 180)
            .accessibilityLabel("Long short spread cumulative return")
        } header: {
            HStack { Text("Long/short spread"); InfoButton(Explain.spread) }
        }

        Section {
            statsTable(r)
        } header: {
            HStack { Text("Statistics"); InfoButton(Explain.sharpe) }
        } footer: {
            HStack(spacing: 4) {
                Text("Max DD = largest peak-to-trough loss.")
                InfoButton(Explain.maxDrawdown)
            }
        }

        Section {
            let ics = r.informationCoefficients.enumerated().compactMap { i, v -> LinePoint? in
                v.isFinite ? LinePoint(iso: r.periodEnds[i], date: dates[i], value: v, series: "IC") : nil
            }
            HStack {
                Text("Mean IC")
                Spacer()
                Text(Format.number(r.meanIC, digits: 3)).monospacedDigit().bold()
                    .foregroundStyle((r.meanIC.isFinite && r.meanIC > 0) ? .green : .red)
            }
            Chart(ics) { p in
                BarMark(x: .value("Month", p.date, unit: .month), y: .value("IC", p.value))
                    .foregroundStyle(p.value >= 0 ? Color.green : Color.red)
            }
            .frame(height: 160)
            .accessibilityLabel("Monthly information coefficient")
        } header: {
            HStack { Text("Information coefficient"); InfoButton(Explain.ic) }
        }
    }

    private func statsTable(_ r: BacktestResult) -> some View {
        let n = r.stats.count
        return Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("Return"); Text("Vol"); Text("Sharpe"); Text("Max DD")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(0..<n, id: \.self) { q in
                GridRow {
                    Text(q == 0 ? "Q1 top" : (q == n - 1 ? "Q\(n) bottom" : "Q\(q + 1)")).gridColumnAlignment(.leading)
                    ForEach(Array(statStrings(r.stats[q]).enumerated()), id: \.offset) { Text($0.element) }
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text("Q1 − Q\(n)").bold().gridColumnAlignment(.leading)
                ForEach(Array(statStrings(r.spreadStats).enumerated()), id: \.offset) { Text($0.element).bold() }
            }
        }
        .font(.caption.monospacedDigit())
    }

    private func statStrings(_ s: QuantileStats) -> [String] {
        [Format.percent(s.annualizedReturn), Format.percent(s.annualizedVolatility),
         Format.number(s.sharpe), Format.percent(-s.maxDrawdown, digits: 0)]
    }

    // MARK: Limitations

    private var limitationsSection: some View {
        Section("Limitations") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Survivorship bias: the test uses today's index members, so companies that were dropped or went bankrupt are missing. This flatters results.", systemImage: "person.3.sequence")
                Label("Price-only factors: value and quality are excluded because historical fundamentals as they were known at the time aren't available. Using today's fundamentals would leak future information.", systemImage: "eye.slash")
                Label("Yahoo Finance is an unofficial source. Data can contain errors or stop working without notice.", systemImage: "exclamationmark.bubble")
                Label("No trading costs, taxes or slippage. Equal weights, monthly rebalancing.", systemImage: "dollarsign.circle")
                Label("Past performance does not predict future results.", systemImage: "clock.arrow.circlepath")
            }
            .font(.caption)
        }
    }
}
