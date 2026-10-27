import SwiftUI
import SwiftData

@main
struct DraftBoardApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Schema(CacheSchema.models))
        } catch {
            // A corrupt or incompatible cache should never brick the app: fall back to
            // memory and let Settings › Clear cache / a reinstall recover.
            container = try! ModelContainer(for: Schema(CacheSchema.models),
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    var body: some Scene {
        WindowGroup {
            BootstrapView(container: container)
        }
        .modelContainer(container)
    }
}

/// Builds the long-lived services off the main thread, then shows the tabs.
struct BootstrapView: View {
    let container: ModelContainer
    @State private var coordinator: DataCoordinator?
    @State private var settings = AppSettings()

    var body: some View {
        Group {
            if let coordinator {
                RootView()
                    .environment(coordinator)
            } else {
                ProgressView("Opening Draft Board…")
            }
        }
        .task {
            guard coordinator == nil else { return }
            coordinator = await DataCoordinator.make(container: container, settings: settings)
        }
    }
}

struct RootView: View {
    @Environment(DataCoordinator.self) private var data
    @Environment(\.scenePhase) private var scenePhase
    @State private var scoring = ScoringModel()
    @State private var router = Router()

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            ScreenerView()
                .tabItem { Label("Screener", systemImage: "list.number") }
                .tag(Router.Tab.screener)
            BacktestView()
                .tabItem { Label("Backtest", systemImage: "chart.xyaxis.line") }
                .tag(Router.Tab.backtest)
            WatchlistView()
                .tabItem { Label("Watchlist", systemImage: "star") }
                .tag(Router.Tab.watchlist)
            ExportView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                .tag(Router.Tab.export)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Router.Tab.settings)
        }
        .environment(scoring)
        .environment(router)
        .task { await data.start() }
        .onChange(of: data.datasetVersion) { rescore() }
        .onChange(of: data.settings.scoringConfig) { rescore() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { data.refreshLive() }
        }
    }

    private func rescore() {
        scoring.rescore(dataset: data.dataset, version: data.datasetVersion, config: data.settings.scoringConfig)
    }
}
