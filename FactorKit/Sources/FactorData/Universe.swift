import Foundation

public struct UniverseMember: Codable, Sendable, Hashable, Identifiable {
    public var id: String { ticker }
    public var ticker: String
    public var name: String
    public var sector: String

    public init(ticker: String, name: String, sector: String) {
        self.ticker = ticker
        self.name = name
        self.sector = sector
    }
}

public struct Universe: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var members: [UniverseMember]
    public var note: String?

    /// Benchmark used for beta and as the trading calendar.
    public static let benchmark = "SPY"
}

public enum UniverseChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    case dow30, top100, sp500, custom
    public var id: String { rawValue }
    public static let `default`: UniverseChoice = .top100

    public var title: String {
        switch self {
        case .dow30: return "Dow 30"
        case .top100: return "Top 100 S&P 500"
        case .sp500: return "Full S&P 500"
        case .custom: return "Custom tickers"
        }
    }
}

public enum UniverseLoader {
    public enum LoadError: Error { case missingResource(String) }

    /// Loads a bundled universe JSON (dow30, top100, sp500).
    public static func load(_ choice: UniverseChoice) throws -> Universe {
        guard choice != .custom else { return Universe(id: "custom", title: choice.title, members: []) }
        guard let url = Bundle.module.url(forResource: choice.rawValue, withExtension: "json") else {
            throw LoadError.missingResource(choice.rawValue)
        }
        return try JSONDecoder().decode(Universe.self, from: Data(contentsOf: url))
    }

    /// The full S&P 500 list, used to look up names and sectors for any member.
    public static func directory() -> [String: UniverseMember] {
        let u = (try? load(.sp500))?.members ?? []
        return Dictionary(u.map { ($0.ticker, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Cleans user-typed tickers: uppercased, trimmed, deduplicated, "BRK-B" → "BRK.B".
    public static func parseCustom(_ text: String) -> [String] {
        let parts = text.uppercased()
            .components(separatedBy: CharacterSet(charactersIn: ", \n\t;"))
            .map { SymbolFormat.massive($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty && $0.count <= 10 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." } }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }
    }
}
