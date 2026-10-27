import SwiftUI
import SwiftData
import Charts
import FactorEngine
import FactorData

struct WatchlistView: View {
    @Environment(DataCoordinator.self) private var data
    @Environment(ScoringModel.self) private var scoring
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    @Query(sort: \WatchlistItem.addedAt) private var items: [WatchlistItem]
    @State private var model = WatchlistModel()

    private var tickers: [String] { items.map(\.ticker) }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("Your watchlist is empty", systemImage: "star")
                    } description: {
                        Text("Swipe a stock in the Screener to add it to your basket.")
                    } actions: {
                        Button("Go to Screener") { router.tab = .screener }
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Watchlist")
            .toolbar { if !items.isEmpty { EditButton() } }
            .navigationDestination(for: String.self) { StockDetailView(ticker: $0) }
            .task(id: "\(data.datasetVersion)|\(tickers.joined(separator: ","))") {
                model.update(tickers: tickers, dataset: data.dataset, version: data.datasetVersion)
            }
        }
    }

    private var list: some View {
        List {
            Section {
                SourceBadge(text: "Correlations from Massive daily returns, past year")
                    .listRowSeparator(.hidden)
            }
            Section("Basket (\(items.count))") {
                ForEach(items) { item in
                    NavigationLink(value: item.ticker) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.ticker).font(.headline)
                                Text(data.dataset.name(item.ticker)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let s = scoring.scoresByTicker[item.ticker] {
                                ScoreBadge(score: s.composite)
                            } else {
                                Text("Not scored").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { context.delete(items[i]) }
                    try? context.save()
                }
            }

            if let a = model.analysis {
                if !a.warnings.isEmpty { warningsSection(a) }
                sectorSection(a)
                if a.ordered.count >= 2 {
                    heatmapSection(a)
                    clusterSection(a)
                } else if items.count >= 2 {
                    Section("Correlation") {
                        Text("Correlations need at least \(WatchlistAnalysis.minimumOverlap) days of price history for two or more stocks.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !a.insufficientHistory.isEmpty {
                    Section {
                        Label("Not enough price history yet: \(a.insufficientHistory.joined(separator: ", "))",
                              systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            } else if model.isComputing {
                Section { ProgressView("Analyzing basket…") }
            }
        }
    }

    // MARK: Sections

    private func warningsSection(_ a: WatchlistAnalysis) -> some View {
        Section("Warnings") {
            ForEach(a.warnings) { w in
                switch w.kind {
                case let .highCorrelation(x, y, c):
                    Label("\(x) and \(y) are highly correlated (\(Format.number(c))). Owning both adds little diversification.",
                          systemImage: "link")
                        .foregroundStyle(.orange)
                case let .sectorConcentration(s, share):
                    Label("\(s) is \(Format.percent(share, digits: 0)) of the basket (over 40%).",
                          systemImage: "chart.pie")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
        }
    }

    private func sectorSection(_ a: WatchlistAnalysis) -> some View {
        Section("Sectors") {
            Chart(a.sectorShares) { s in
                SectorMark(angle: .value("Share", s.share), innerRadius: .ratio(0.6), angularInset: 1.5)
                    .foregroundStyle(by: .value("Sector", s.sector))
                    .cornerRadius(3)
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
            .frame(height: 240)
            .accessibilityLabel(a.sectorShares.map { "\($0.sector) \(Format.percent($0.share, digits: 0))" }.joined(separator: ", "))
        }
    }

    private struct HeatCell: Identifiable {
        var id: String { x + "|" + y }
        let x: String
        let y: String
        let value: Double
    }

    private func heatmapSection(_ a: WatchlistAnalysis) -> some View {
        var cells: [HeatCell] = []
        for (i, x) in a.ordered.enumerated() {
            for (j, y) in a.ordered.enumerated() {
                cells.append(HeatCell(x: x, y: y, value: a.correlation[i][j].isFinite ? a.correlation[i][j] : 0))
            }
        }
        let showLabels = a.ordered.count <= 8
        return Section {
            Chart(cells) { c in
                RectangleMark(x: .value("Stock", c.x), y: .value("Stock ", c.y))
                    .foregroundStyle(by: .value("Correlation", c.value))
                    .annotation(position: .overlay) {
                        if showLabels {
                            Text(String(format: "%.2f", c.value)).font(.system(size: 9)).foregroundStyle(.primary)
                        }
                    }
            }
            .chartForegroundStyleScale(domain: -1.0...1.0, range: Gradient(colors: [.blue, Color(.systemBackground), .red]))
            .chartXScale(domain: a.ordered)
            .chartYScale(domain: Array(a.ordered.reversed()))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("Correlation heatmap of \(a.ordered.count) stocks")
        } header: {
            HStack {
                Text("Correlation heatmap")
                InfoButton(Explain.correlation)
            }
        } footer: {
            Text("Blue means the stocks move in opposite directions, red means they move together. Stocks in the same cluster sit next to each other.")
        }
    }

    private func clusterSection(_ a: WatchlistAnalysis) -> some View {
        Section {
            ForEach(Array(a.clusters.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.count == 1 ? "Independent" : "Cluster \(i + 1) · moves together")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(c.joined(separator: ", ")).font(.body.weight(.medium))
                }
            }
        } header: {
            HStack {
                Text("Clusters")
                InfoButton(Explain.clusters)
            }
        }
    }
}
