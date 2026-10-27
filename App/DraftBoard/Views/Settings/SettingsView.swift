import SwiftUI
import FactorEngine
import FactorData

struct SettingsView: View {
    @Environment(DataCoordinator.self) private var data
    @State private var massiveKey = ""
    @State private var fmpKey = ""
    @State private var customDraft = ""
    @State private var confirmClear = false
    @State private var mismatches: [ConsistencyCheck.Mismatch]?
    @State private var checking = false
    @State private var keysSaved = false

    private var settings: AppSettings { data.settings }

    var body: some View {
        NavigationStack {
            Form {
                keysSection
                universeSection
                freshnessSection
                consistencySection
                rateLimitSection
                cacheSection
                Section {
                    NavigationLink("Methodology & About") { AboutView() }
                } footer: {
                    Text("For educational purposes only. Not investment advice.")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                massiveKey = Keychain.get(.massive) ?? ""
                fmpKey = Keychain.get(.fmp) ?? ""
                customDraft = settings.customTickers
            }
            .task { await data.refreshStats() }
            .sensoryFeedback(.success, trigger: keysSaved)
        }
    }

    // MARK: Keys

    private var keysSection: some View {
        Section {
            LabeledContent {
                SecureField("Paste key", text: $massiveKey).textContentType(.password).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            } label: {
                keyLabel("Massive", present: data.hasMassiveKey)
            }
            LabeledContent {
                SecureField("Paste key", text: $fmpKey).textContentType(.password).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            } label: {
                keyLabel("FMP", present: data.hasFMPKey)
            }
            Button("Save keys") {
                data.saveKeys(massive: massiveKey, fmp: fmpKey)
                keysSaved.toggle()
            }
            .disabled(massiveKey == (Keychain.get(.massive) ?? "") && fmpKey == (Keychain.get(.fmp) ?? ""))
        } header: {
            Text("API keys")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keys are stored in the iOS Keychain on this device only.")
                Link("Get a free Massive key", destination: URL(string: "https://massive.com/dashboard/keys")!)
                Link("Get a free FMP key", destination: URL(string: "https://site.financialmodelingprep.com/developer/docs")!)
            }
        }
    }

    private func keyLabel(_ name: String, present: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(present ? .green : .secondary)
            Text(name)
        }
    }

    // MARK: Universe

    private var universeSection: some View {
        Section {
            Picker("Universe", selection: Binding(get: { settings.universe },
                                                  set: { settings.universe = $0; data.universeChanged() })) {
                ForEach(UniverseChoice.allCases) { Text($0.title).tag($0) }
            }
            if settings.universe == .custom {
                TextField("AAPL, MSFT, BRK.B…", text: $customDraft, axis: .vertical)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .lineLimit(2...6)
                let parsed = UniverseLoader.parseCustom(customDraft)
                Button("Use \(parsed.count) tickers") {
                    settings.customTickers = parsed.joined(separator: ", ")
                    customDraft = settings.customTickers
                    data.universeChanged()
                }
                .disabled(parsed.isEmpty || settings.customTickers == parsed.joined(separator: ", "))
            }
        } header: {
            Text("Universe")
        } footer: {
            Text(settings.universe == .custom
                 ? "Tickers outside the S&P 500 get their price history downloaded once, one request each."
                 : "\(data.dataset.members.count) stocks. Fundamentals load at about 2 FMP calls per stock, and the free plan allows 250 calls a day.")
        }
    }

    // MARK: Freshness

    private var freshnessSection: some View {
        Section {
            freshnessRow("Massive prices", icon: "chart.line.uptrend.xyaxis",
                         lines: ["\(data.stats.priceDays) trading days cached" + (data.stats.latestPriceDate.map { ", latest \($0)" } ?? ""),
                                 "Updated \(Format.relative(data.stats.latestPriceFetch)) · daily"],
                         progress: data.priceProgress)
            freshnessRow("FMP fundamentals", icon: "doc.text.magnifyingglass",
                         lines: ["\(data.stats.fundamentalsCount) companies" + (data.stats.fundamentalsFailed > 0 ? ", \(data.stats.fundamentalsFailed) failed" : ""),
                                 "Oldest \(Format.relative(data.stats.oldestFundamentalsFetch)) · weekly"],
                         progress: data.fundamentalsProgress)
            freshnessRow("Yahoo history (backtest)", icon: "clock.arrow.circlepath",
                         lines: ["\(data.stats.historyCount) tickers" + (data.stats.historyFailed > 0 ? ", \(data.stats.historyFailed) failed" : ""),
                                 "Updated \(Format.relative(data.stats.latestHistoryFetch)) · monthly"],
                         progress: data.historyProgress)
            HStack {
                Button("Refresh now") { data.refreshLive() }
                    .disabled(data.isSyncingLive)
                Spacer()
                if data.isSyncingLive || data.isSyncingHistory {
                    Button("Pause", role: .destructive) { data.cancelSync() }
                }
            }
        } header: {
            Text("Data freshness")
        } footer: {
            Text("Only missing or stale data is downloaded. An interrupted download resumes where it stopped the next time the app opens.")
        }
    }

    private func freshnessRow(_ title: String, icon: String, lines: [String], progress: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            ForEach(lines, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            switch progress.phase {
            case .running:
                ProgressView(value: progress.fraction) {
                    Text("\(progress.completed) of \(progress.total) loaded").font(.caption)
                }
            case .failed(let m), .pausedForQuota(let m):
                Text(m).font(.caption).foregroundStyle(.orange)
            default:
                EmptyView()
            }
        }
    }

    // MARK: Consistency

    private var consistencySection: some View {
        Section {
            Button {
                checking = true
                Task {
                    mismatches = await data.consistencyCheck()
                    checking = false
                }
            } label: {
                HStack {
                    Text("Compare Massive with Yahoo")
                    Spacer()
                    if checking { ProgressView() }
                }
            }
            .disabled(checking || data.stats.historyCount == 0)
            if let mismatches {
                if mismatches.isEmpty {
                    Label("All overlapping closes agree within 1%.", systemImage: "checkmark.seal").foregroundStyle(.green)
                } else {
                    ForEach(mismatches, id: \.ticker) { m in
                        VStack(alignment: .leading) {
                            Text("\(m.ticker): \(Format.percent(m.relativeDifference)) apart on \(m.date)").font(.subheadline)
                            Text("Massive \(Format.money(m.primary)) vs Yahoo \(Format.money(m.secondary))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Data consistency")
        } footer: {
            Text(data.stats.historyCount == 0
                 ? "Run a backtest first to download Yahoo history."
                 : "Flags tickers whose recent split-adjusted closes differ by more than 1% between the two sources. A mismatch usually means a missed split or bad data in one feed.")
        }
    }

    // MARK: Rate limits

    private var rateLimitSection: some View {
        Section {
            Stepper("Massive: \(settings.massiveCallsPerMinute)/min",
                    value: Binding(get: { settings.massiveCallsPerMinute }, set: { settings.massiveCallsPerMinute = $0; data.applyRateLimits() }),
                    in: 1...1000, step: settings.massiveCallsPerMinute >= 100 ? 50 : (settings.massiveCallsPerMinute >= 10 ? 5 : 1))
            Stepper("FMP: \(settings.fmpCallsPerMinute)/min",
                    value: Binding(get: { settings.fmpCallsPerMinute }, set: { settings.fmpCallsPerMinute = $0; data.applyRateLimits() }),
                    in: 1...3000, step: 5)
            Stepper("FMP: \(settings.fmpDailyLimit)/day",
                    value: Binding(get: { settings.fmpDailyLimit }, set: { settings.fmpDailyLimit = $0; data.applyRateLimits() }),
                    in: 50...100_000, step: 50)
            Stepper("Yahoo: \(settings.yahooCallsPerMinute)/min",
                    value: Binding(get: { settings.yahooCallsPerMinute }, set: { settings.yahooCallsPerMinute = $0; data.applyRateLimits() }),
                    in: 1...300, step: 10)
        } header: {
            Text("Rate limits")
        } footer: {
            Text("Massive's free plan allows 5 calls a minute, so the first load of about 13 months of prices takes close to an hour. Raise the limits if you have a paid plan. Rate-limit errors are retried automatically with increasing delays.")
        }
    }

    // MARK: Cache

    private var cacheSection: some View {
        Section {
            LabeledContent("Cache size", value: Format.bytes(data.stats.bytes))
            Button("Clear cache", role: .destructive) { confirmClear = true }
                .confirmationDialog("Clear all downloaded data?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear cache", role: .destructive) { Task { await data.clearCache() } }
                } message: {
                    Text("Prices, fundamentals, history and backtest results will be downloaded again. Your watchlist and API keys are kept.")
                }
        } header: {
            Text("Storage")
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                Text("Draft Board helps you decide **what** to invest in using a multi-factor model. When you've picked a basket, export it to Shock Lab to stress test it.")
                Link("Shock Lab", destination: URL(string: "https://shocklab.streamlit.app/")!)
            }
            Section("The factor model") {
                bullet("Value", "Earnings yield (E/P), EBITDA/EV (inverted EV/EBITDA) and book-to-market.")
                bullet("Quality", "Return on equity, gross margin and debt-to-equity (inverted).")
                bullet("Momentum", "12-month return excluding the most recent month (12-1).")
                bullet("Low volatility", "1-year annualized realized volatility and beta vs SPY, both inverted.")
                bullet("Size", "Market cap, inverted, as an optional small-cap tilt.")
            }
            Section("How scores are built") {
                bullet("1. Winsorize", "Each metric is capped at its 1st and 99th percentile across the universe so outliers can't dominate.")
                bullet("2. Z-score", "Within each GICS sector (sector-neutral, default) or across the universe. A sector with fewer than 3 stocks falls back to the universe.")
                bullet("3. Factor scores", "The average of each factor's available metric z-scores, oriented so higher is always better.")
                bullet("4. Composite", "A weighted average of factor scores, with weights rescaled to 100%. Stocks missing more than 40% of the metrics in use are excluded.")
            }
            Section("Data sources") {
                bullet("Massive", "Live prices for the Screener, Stock Detail, Watchlist and Export. One grouped-daily request covers all US stocks for a day. Splits are applied from Massive's split records.")
                bullet("Financial Modeling Prep", "Fundamentals and company profiles, refreshed weekly.")
                bullet("Yahoo Finance", "10 years of adjusted closes for the Backtest only, refreshed monthly. It's unofficial and can break, which only affects the Backtest tab.")
                Text("Price sources are never mixed within a calculation.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Backtest") {
                Text("Monthly rebalance on momentum and low volatility only. Historical fundamentals as known at the time aren't available, and using today's would leak future information. Stocks are ranked by composite, split into equal-weight quintiles and held one month. Reported: cumulative returns, the top-minus-bottom spread, annualized return, volatility, Sharpe, max drawdown, and the monthly Spearman information coefficient.")
                Text("Limitations: survivorship bias from using current index members, no trading costs, and an unofficial data source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Label("For educational purposes only. This is not investment advice. Do your own research and consider speaking to a licensed adviser.",
                      systemImage: "exclamationmark.shield")
            }
        }
        .navigationTitle("About")
    }

    private func bullet(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.callout).foregroundStyle(.secondary)
        }
    }
}
