import Foundation
import Observation
import FactorEngine
import FactorData

/// Screener filters. nil means "no limit".
struct ScreenerFilters: Codable, Equatable, Sendable {
    var sectors: Set<String> = []
    var minMarketCapBillions: Double?
    var maxPE: Double?
    /// Percent, e.g. 2 = 2%.
    var minDividendYieldPercent: Double?
    var maxBeta: Double?

    var activeCount: Int {
        (sectors.isEmpty ? 0 : 1) + [minMarketCapBillions, maxPE, minDividendYieldPercent, maxBeta].compactMap { $0 }.count
    }
}

/// User preferences, persisted in UserDefaults. API keys are NOT here (see Keychain).
@Observable
@MainActor
final class AppSettings {
    private let defaults: UserDefaults

    var universe: UniverseChoice { didSet { defaults.set(universe.rawValue, forKey: "universe") } }
    var customTickers: String { didSet { defaults.set(customTickers, forKey: "customTickers") } }
    var weights: FactorWeights { didSet { save(weights, "weights") } }
    /// The preset the weights came from, or nil once the user moves a slider.
    var preset: Preset? { didSet { defaults.set(preset?.rawValue ?? "custom", forKey: "preset") } }
    var neutralization: Neutralization { didSet { defaults.set(neutralization.rawValue, forKey: "neutralization") } }
    var filters: ScreenerFilters { didSet { save(filters, "filters") } }

    var massiveCallsPerMinute: Int { didSet { defaults.set(massiveCallsPerMinute, forKey: "massiveCPM") } }
    var fmpCallsPerMinute: Int { didSet { defaults.set(fmpCallsPerMinute, forKey: "fmpCPM") } }
    var fmpDailyLimit: Int { didSet { defaults.set(fmpDailyLimit, forKey: "fmpDaily") } }
    var yahooCallsPerMinute: Int { didSet { defaults.set(yahooCallsPerMinute, forKey: "yahooCPM") } }

    var backtestYears: Int { didSet { defaults.set(backtestYears, forKey: "backtestYears") } }

    var exportAmount: Double { didSet { defaults.set(exportAmount, forKey: "exportAmount") } }
    var exportScheme: WeightingScheme { didSet { defaults.set(exportScheme.rawValue, forKey: "exportScheme") } }
    var exportRounding: ShareRounding { didSet { defaults.set(exportRounding.rawValue, forKey: "exportRounding") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        universe = UniverseChoice(rawValue: defaults.string(forKey: "universe") ?? "") ?? .default
        customTickers = defaults.string(forKey: "customTickers") ?? ""
        weights = Self.load(FactorWeights.self, "weights", defaults) ?? Preset.balanced.weights
        preset = defaults.object(forKey: "preset") == nil ? .balanced : Preset(rawValue: defaults.string(forKey: "preset") ?? "")
        neutralization = Neutralization(rawValue: defaults.string(forKey: "neutralization") ?? "") ?? .sector
        filters = Self.load(ScreenerFilters.self, "filters", defaults) ?? ScreenerFilters()
        massiveCallsPerMinute = defaults.object(forKey: "massiveCPM") as? Int ?? 5
        fmpCallsPerMinute = defaults.object(forKey: "fmpCPM") as? Int ?? 30
        fmpDailyLimit = defaults.object(forKey: "fmpDaily") as? Int ?? 250
        yahooCallsPerMinute = defaults.object(forKey: "yahooCPM") as? Int ?? 60
        backtestYears = defaults.object(forKey: "backtestYears") as? Int ?? 10
        exportAmount = defaults.object(forKey: "exportAmount") as? Double ?? 10_000
        exportScheme = WeightingScheme(rawValue: defaults.string(forKey: "exportScheme") ?? "") ?? .equal
        exportRounding = ShareRounding(rawValue: defaults.string(forKey: "exportRounding") ?? "") ?? .whole
    }

    var scoringConfig: ScoringConfig {
        ScoringConfig(weights: weights, neutralization: neutralization)
    }

    func apply(_ p: Preset) {
        weights = p.weights
        preset = p
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(v), forKey: key)
    }

    private static func load<T: Decodable>(_ t: T.Type, _ key: String, _ d: UserDefaults) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(t, from: $0) }
    }
}
