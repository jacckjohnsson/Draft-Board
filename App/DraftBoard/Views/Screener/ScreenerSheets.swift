import SwiftUI
import FactorEngine
import FactorData

struct FilterSheet: View {
    @Environment(DataCoordinator.self) private var data
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ScreenerFilters()

    private var sectors: [String] {
        Array(Set(data.dataset.tickers.map { data.dataset.sector($0) })).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if sectors.isEmpty {
                        Text("Sectors appear once the universe has loaded.").foregroundStyle(.secondary)
                    }
                    ForEach(sectors, id: \.self) { s in
                        Button {
                            if draft.sectors.contains(s) { draft.sectors.remove(s) } else { draft.sectors.insert(s) }
                        } label: {
                            HStack {
                                Text(s).foregroundStyle(.primary)
                                Spacer()
                                if draft.sectors.contains(s) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } header: {
                    Text("Sectors")
                } footer: {
                    Text(draft.sectors.isEmpty ? "All sectors are shown." : "\(draft.sectors.count) selected.")
                }

                Section {
                    OptionalNumberRow(title: "Min market cap", unit: "$B", value: $draft.minMarketCapBillions, defaultValue: 10, step: 5, range: 0...5000)
                    OptionalNumberRow(title: "Max P/E", unit: "×", value: $draft.maxPE, defaultValue: 25, step: 1, range: 1...200,
                                      info: Explain.peRatio)
                    OptionalNumberRow(title: "Min dividend yield", unit: "%", value: $draft.minDividendYieldPercent, defaultValue: 1, step: 0.25, range: 0...15,
                                      info: Explain.dividendYield)
                    OptionalNumberRow(title: "Max beta", unit: "", value: $draft.maxBeta, defaultValue: 1.2, step: 0.1, range: 0...4,
                                      info: Explain.metric(.beta))
                } header: {
                    Text("Limits")
                } footer: {
                    Text("Filters only hide rows. Ranks are still computed across the whole universe. Stocks missing the filtered value are hidden while that filter is on.")
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Reset") { draft = ScreenerFilters() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { data.settings.filters = draft; dismiss() }
                }
            }
            .onAppear { draft = data.settings.filters }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A toggle-able numeric limit: off means "no limit".
struct OptionalNumberRow: View {
    let title: String
    let unit: String
    @Binding var value: Double?
    let defaultValue: Double
    let step: Double
    let range: ClosedRange<Double>
    var info: Explain.Entry? = nil

    var body: some View {
        VStack(alignment: .leading) {
            Toggle(isOn: Binding(get: { value != nil }, set: { value = $0 ? defaultValue : nil })) {
                HStack(spacing: 4) {
                    Text(title)
                    if let info { InfoButton(info) }
                }
            }
            if let v = value {
                Stepper(value: Binding(get: { v }, set: { value = $0 }), in: range, step: step) {
                    Text(unit == "$B" ? "$\(Format.number(v, digits: 0))B" : "\(Format.number(v, digits: step < 1 ? 2 : 0))\(unit)")
                        .monospacedDigit()
                }
            }
        }
    }
}

struct WeightsSheet: View {
    @Environment(DataCoordinator.self) private var data
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let settings = data.settings
        let normalized = settings.weights.normalized
        NavigationStack {
            Form {
                Section {
                    Picker("Preset", selection: Binding(
                        get: { settings.preset },
                        set: { if let p = $0 { settings.apply(p) } })) {
                        ForEach(Preset.allCases) { p in Text(p.displayName).tag(Optional(p)) }
                        if settings.preset == nil { Text("Custom").tag(Optional<Preset>.none) }
                    }
                    if let p = settings.preset {
                        Text(p.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(Factor.allCases) { f in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(f.displayName, systemImage: f.symbol)
                                InfoButton(Explain.factor(f))
                                Spacer()
                                Text(Format.percent(normalized[f], digits: 0))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(
                                get: { settings.weights[f] },
                                set: { settings.weights[f] = $0.rounded(); settings.preset = nil }),
                                   in: 0...100, step: 5) {
                                Text(f.displayName)
                            }
                            .accessibilityValue(Format.percent(normalized[f], digits: 0))
                        }
                    }
                } header: {
                    Text("Factor weights")
                } footer: {
                    Text("Weights are rescaled to add up to 100%. Size is an optional tilt toward smaller companies.")
                }

                Section {
                    Toggle(isOn: Binding(get: { settings.neutralization == .sector },
                                         set: { settings.neutralization = $0 ? .sector : .crossSectional })) {
                        HStack(spacing: 4) {
                            Text("Sector-neutral")
                            InfoButton(Explain.sectorNeutral)
                        }
                    }
                }
            }
            .navigationTitle("Weights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
