import SwiftUI
import FactorEngine
import FactorData

/// ⓘ button that shows a plain-English explanation in a popover.
struct InfoButton: View {
    let entry: Explain.Entry
    @State private var shown = false

    init(_ entry: Explain.Entry) { self.entry = entry }

    var body: some View {
        Button {
            shown = true
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(entry.title)")
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title).font(.headline)
                Text(entry.body).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(idealWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Small capsule naming where a tab's data comes from.
struct SourceBadge: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "antenna.radiowaves.left.and.right")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel("Data source: \(text)")
    }
}

/// "X of N loaded" banner for a running sync.
struct SyncBanner: View {
    let progress: SyncProgress
    var etaPerItem: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch progress.phase {
                case .running: ProgressView().controlSize(.small)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .pausedForQuota: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
                default: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if progress.total > 0 && progress.isRunning {
                    Text("\(progress.completed) of \(progress.total)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if progress.isRunning && progress.total > 0 {
                ProgressView(value: progress.fraction)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch progress.phase {
        case .running: return "Loading \(progress.source)"
        case .failed: return "\(progress.source) problem"
        case .pausedForQuota: return "\(progress.source) paused"
        case .finished: return "\(progress.source) up to date"
        case .idle: return progress.source
        }
    }

    private var message: String? {
        switch progress.phase {
        case .failed(let m), .pausedForQuota(let m): return m
        case .running:
            if let etaPerItem, progress.total > progress.completed {
                let minutes = Int((Double(progress.total - progress.completed) * etaPerItem / 60).rounded(.up))
                return "\(progress.detail) · about \(minutes) min left. Keep the app open. It resumes if interrupted."
            }
            return progress.detail.isEmpty ? nil : progress.detail
        default: return progress.detail.isEmpty ? nil : progress.detail
        }
    }
}

/// Composite score capsule, colored by sign.
struct ScoreBadge: View {
    let score: Double
    var body: some View {
        Text(score.isFinite ? String(format: "%+.2f", score) : "–")
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(color, in: Capsule())
            .accessibilityLabel("Composite score \(score.isFinite ? String(format: "%.2f", score) : "unavailable")")
    }
    private var color: Color {
        guard score.isFinite else { return .gray }
        if score > 0.5 { return .green }
        if score > 0 { return .teal }
        if score > -0.5 { return .orange }
        return .red
    }
}

/// Five tiny horizontal bars, one per factor, centered on zero.
struct MiniFactorBars: View {
    let scores: [Factor: Double]
    let factors: [Factor]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(factors) { f in
                let v = scores[f]
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        let h = geo.size.height
                        let clamped = max(-2, min(2, v ?? 0)) / 2
                        ZStack(alignment: .center) {
                            Rectangle().fill(.quaternary).frame(height: 1)
                            Rectangle()
                                .fill(v == nil ? Color.gray.opacity(0.3) : (clamped >= 0 ? Color.green : Color.red))
                                .frame(height: max(1, abs(clamped) * h / 2))
                                .offset(y: -clamped * h / 4)
                        }
                        .frame(width: geo.size.width, height: h)
                    }
                    .frame(width: 10, height: 22)
                    Text(f.shortLabel).font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(factors.map { "\($0.displayName) \(scores[$0].map { String(format: "%.1f", $0) } ?? "missing")" }.joined(separator: ", "))
    }
}

extension Factor {
    var shortLabel: String {
        switch self {
        case .value: return "V"
        case .quality: return "Q"
        case .momentum: return "M"
        case .lowVolatility: return "LV"
        case .size: return "S"
        }
    }

    var symbol: String {
        switch self {
        case .value: return "tag"
        case .quality: return "checkmark.seal"
        case .momentum: return "arrow.up.right"
        case .lowVolatility: return "waveform.path.ecg"
        case .size: return "building.2"
        }
    }
}

extension Metric {
    var displayName: String { Explain.metric(self).title }
}

enum Format {
    static func percent(_ x: Double?, digits: Int = 1) -> String {
        guard let x, x.isFinite else { return "–" }
        return String(format: "%.\(digits)f%%", x * 100)
    }
    static func number(_ x: Double?, digits: Int = 2) -> String {
        guard let x, x.isFinite else { return "–" }
        return String(format: "%.\(digits)f", x)
    }
    static func money(_ x: Double?) -> String {
        guard let x, x.isFinite else { return "–" }
        return x.formatted(.currency(code: "USD"))
    }
    static func marketCap(_ x: Double?) -> String {
        guard let x, x.isFinite, x > 0 else { return "–" }
        if x >= 1e12 { return String(format: "$%.2fT", x / 1e12) }
        if x >= 1e9 { return String(format: "$%.1fB", x / 1e9) }
        return String(format: "$%.0fM", x / 1e6)
    }
    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
    static func relative(_ d: Date?) -> String {
        guard let d else { return "never" }
        return d.formatted(.relative(presentation: .named))
    }
}
