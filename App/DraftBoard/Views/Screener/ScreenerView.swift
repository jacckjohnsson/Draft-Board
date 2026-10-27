import SwiftUI
import SwiftData
import FactorEngine
import FactorData

struct ScreenerView: View {
    @Environment(DataCoordinator.self) private var data
    @Environment(ScoringModel.self) private var scoring
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    @Query private var watchlist: [WatchlistItem]

    @State private var search = ""
    @State private var showFilters = false
    @State private var showWeights = false
    @State private var hapticTrigger = 0

    private var settings: AppSettings { data.settings }
    private var watchSet: Set<String> { Set(watchlist.map(\.ticker)) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Screener")
                .searchable(text: $search, prompt: "Ticker or company")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showWeights = true } label: {
                            Label("Weights", systemImage: "slider.horizontal.3")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showFilters = true } label: {
                            Label("Filters", systemImage: settings.filters.activeCount > 0
                                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityValue(settings.filters.activeCount > 0 ? "\(settings.filters.activeCount) active" : "none")
                    }
                }
                .sheet(isPresented: $showFilters) { FilterSheet() }
                .sheet(isPresented: $showWeights) { WeightsSheet() }
                .navigationDestination(for: String.self) { StockDetailView(ticker: $0) }
                .refreshable { data.refreshLive() }
                .sensoryFeedback(.success, trigger: hapticTrigger)
        }
    }

    @ViewBuilder
    private var content: some View {
        let dataset = data.dataset
        let rows = scoring.rows(dataset: dataset, filters: settings.filters, search: search)

        if !data.hasMassiveKey && !data.hasFMPKey && dataset.isEmpty {
            ContentUnavailableView {
                Label("Add your API keys", systemImage: "key")
            } description: {
                Text("Draft Board needs a free Massive key for prices and a Financial Modeling Prep key for fundamentals.")
            } actions: {
                Button("Open Settings") { router.tab = .settings }.buttonStyle(.borderedProminent)
            }
        } else if let error = data.datasetError {
            ContentUnavailableView("Couldn't load cached data", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if scoring.result == nil && (data.isLoadingDataset || scoring.isScoring) {
            ProgressView("Scoring \(dataset.universeTitle)…")
        } else {
            List {
                Section {
                    statusHeader(dataset)
                }
                .listRowSeparator(.hidden)

                if rows.isEmpty {
                    emptyRows(dataset)
                } else {
                    Section {
                        ForEach(rows) { s in
                            NavigationLink(value: s.ticker) {
                                StockRow(score: s, name: dataset.name(s.ticker),
                                         activeFactors: settings.weights.activeFactors,
                                         inWatchlist: watchSet.contains(s.ticker))
                            }
                            .swipeActions(edge: .trailing) { watchButton(s.ticker) }
                            .swipeActions(edge: .leading) { watchButton(s.ticker) }
                        }
                    } header: {
                        HStack {
                            Text("\(rows.count) stocks")
                            Spacer()
                            if scoring.isScoring { ProgressView().controlSize(.mini) }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func statusHeader(_ dataset: LiveDataset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SourceBadge(text: "Prices: Massive · Fundamentals: FMP")
                Spacer()
                if let d = dataset.latestDate {
                    Text("As of \(d)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Text(settings.preset?.displayName ?? "Custom weights")
                Text("·")
                Text(settings.neutralization == .sector ? "Sector-neutral" : "Cross-sectional")
                InfoButton(Explain.composite)
            }
            .font(.caption).foregroundStyle(.secondary)

            if data.priceProgress.isRunning || isProblem(data.priceProgress) {
                SyncBanner(progress: data.priceProgress, etaPerItem: 60 / Double(max(1, settings.massiveCallsPerMinute)))
            }
            if let b = data.backfillProgress, b.isRunning { SyncBanner(progress: b) }
            if data.fundamentalsProgress.isRunning || isProblem(data.fundamentalsProgress) {
                SyncBanner(progress: data.fundamentalsProgress, etaPerItem: 120 / Double(max(1, settings.fmpCallsPerMinute)))
            }
            if let excluded = scoring.result?.excluded, !excluded.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("\(excluded.count) of \(dataset.members.count) stocks excluded for missing data")
                    InfoButton(Explain.excluded)
                }
                .font(.caption)
            }
            if dataset.tradingDays > 0 && dataset.tradingDays < 253 {
                Text("Only \(dataset.tradingDays) trading days of prices so far. Momentum needs 253, so it stays blank until the backfill finishes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func isProblem(_ p: SyncProgress) -> Bool {
        switch p.phase {
        case .failed, .pausedForQuota: return true
        default: return false
        }
    }

    @ViewBuilder
    private func emptyRows(_ dataset: LiveDataset) -> some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else if settings.filters.activeCount > 0 {
            ContentUnavailableView {
                Label("No stocks match your filters", systemImage: "line.3.horizontal.decrease.circle")
            } actions: {
                Button("Clear filters") { settings.filters = ScreenerFilters() }
            }
        } else if data.isSyncingLive {
            ContentUnavailableView("Loading data", systemImage: "arrow.down.circle",
                                   description: Text("Scores appear as soon as enough prices and fundamentals are cached."))
        } else {
            ContentUnavailableView("Nothing to score yet", systemImage: "chart.bar.xaxis",
                                   description: Text("Pull to refresh, or check your API keys in Settings."))
        }
    }

    @ViewBuilder
    private func watchButton(_ ticker: String) -> some View {
        if watchSet.contains(ticker) {
            Button(role: .destructive) { removeFromWatchlist(ticker) } label: {
                Label("Remove", systemImage: "star.slash")
            }
        } else {
            Button { addToWatchlist(ticker) } label: {
                Label("Watch", systemImage: "star.fill")
            }
            .tint(.yellow)
        }
    }

    private func addToWatchlist(_ t: String) {
        guard !watchSet.contains(t) else { return }
        context.insert(WatchlistItem(ticker: t))
        try? context.save()
        hapticTrigger += 1
    }

    private func removeFromWatchlist(_ t: String) {
        for item in watchlist where item.ticker == t { context.delete(item) }
        try? context.save()
    }
}

struct StockRow: View {
    let score: StockScore
    let name: String
    let activeFactors: [Factor]
    let inWatchlist: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(score.rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(score.ticker).font(.headline)
                    if inWatchlist {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            .accessibilityLabel("In watchlist")
                    }
                    if !score.missingMetrics.isEmpty {
                        Image(systemName: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange)
                            .accessibilityLabel("\(score.missingMetrics.count) metrics missing")
                    }
                }
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(score.sector).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            MiniFactorBars(scores: score.factorScores, factors: activeFactors)
            ScoreBadge(score: score.composite)
        }
        .padding(.vertical, 2)
    }
}
