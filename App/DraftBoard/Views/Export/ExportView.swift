import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import FactorEngine
import FactorData

/// A CSV file handed to the share sheet.
struct CSVDocument: Transferable {
    let text: String
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { doc in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(doc.filename)
            try doc.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

struct ExportView: View {
    @Environment(DataCoordinator.self) private var data
    @Environment(ScoringModel.self) private var scoring
    @Environment(Router.self) private var router
    @Query(sort: \WatchlistItem.addedAt) private var items: [WatchlistItem]

    private var settings: AppSettings { data.settings }

    private var allocation: ShareAllocation {
        let tickers = items.map(\.ticker)
        let pct = scoring.scoresByTicker.mapValues(\.percentile)
        let weights = Portfolio.weights(tickers: tickers, scheme: settings.exportScheme, percentiles: pct)
        var prices: [String: Double] = [:]
        for t in tickers { if let p = data.dataset.lastClose(t) { prices[t] = p } }
        return Portfolio.allocate(weights: weights, prices: prices, amount: settings.exportAmount, rounding: settings.exportRounding)
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to export", systemImage: "square.and.arrow.up")
                    } description: {
                        Text("Add stocks to your watchlist, then export them here as a CSV for Shock Lab.")
                    } actions: {
                        Button("Go to Screener") { router.tab = .screener }
                    }
                } else {
                    form
                }
            }
            .navigationTitle("Export")
        }
    }

    private var form: some View {
        let alloc = allocation
        let csv = Portfolio.shockLabCSV(alloc, rounding: settings.exportRounding)
        let date = data.dataset.latestDate ?? TradingCalendar.isoString(.now)
        return Form {
            Section {
                SourceBadge(text: "Prices: Massive close \(data.dataset.latestDate ?? "unavailable")")
                    .listRowSeparator(.hidden)
                LabeledContent("Portfolio value") {
                    TextField("Amount", value: Binding(get: { settings.exportAmount },
                                                       set: { settings.exportAmount = max(0, $0) }),
                              format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Picker("Weighting", selection: Binding(get: { settings.exportScheme }, set: { settings.exportScheme = $0 })) {
                    ForEach(WeightingScheme.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Shares", selection: Binding(get: { settings.exportRounding }, set: { settings.exportRounding = $0 })) {
                    Text("Whole").tag(ShareRounding.whole)
                    Text("Fractional").tag(ShareRounding.fractional)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(settings.exportScheme == .score
                     ? "Score weighted: each stock's weight is proportional to its composite percentile in the universe."
                     : "Equal weight: the same dollar amount in every stock.")
            }

            Section("Preview") {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Ticker").gridColumnAlignment(.leading)
                        Text("Weight"); Text("Price"); Text("Shares"); Text("Value")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(alloc.holdings) { h in
                        GridRow {
                            Text(h.ticker).bold().gridColumnAlignment(.leading)
                            Text(Format.percent(h.weight))
                            Text(Format.money(h.price))
                            Text(settings.exportRounding == .whole ? String(Int(h.shares)) : Format.number(h.shares, digits: 4))
                            Text(Format.money(h.value))
                        }
                        .foregroundStyle(h.shares == 0 ? .secondary : .primary)
                    }
                }
                .font(.caption.monospacedDigit())
                LabeledContent("Invested", value: Format.money(alloc.invested))
                LabeledContent("Cash left over", value: Format.money(alloc.cash))
                if alloc.holdings.contains(where: { $0.shares == 0 }) {
                    Label("Some positions round to 0 shares at this portfolio size. Raise the amount or switch to fractional shares.",
                          systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !alloc.unpriced.isEmpty {
                    Label("No Massive price yet for \(alloc.unpriced.joined(separator: ", ")). Left out of the file.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section {
                ShareLink(item: CSVDocument(text: csv, filename: "draft-board-\(date).csv"),
                          preview: SharePreview("Draft Board basket \(date)")) {
                    Label("Share CSV for Shock Lab", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .disabled(alloc.holdings.allSatisfy { $0.shares == 0 })
                Link(destination: URL(string: "https://shocklab.streamlit.app/")!) {
                    Label("Open Shock Lab", systemImage: "safari")
                }
            } header: {
                Text("File")
            } footer: {
                Text("Columns: ticker, shares. Positions with 0 shares are left out.")
            }

            Section("CSV") {
                Text(csv).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }
}
