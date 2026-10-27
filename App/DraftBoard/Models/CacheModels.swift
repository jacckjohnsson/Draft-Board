import Foundation
import SwiftData
import FactorData

// SwiftData models. Heavy payloads are stored as encoded Data blobs (externalStorage)
// so each trading day or ticker is one row, which keeps saves and fetches fast.

/// One trading day of Massive closes (unadjusted) for the tracked tickers.
@Model
final class PriceDay {
    @Attribute(.unique) var date: String
    /// True when the market was closed (empty grouped response); no payload then.
    var isClosed: Bool
    @Attribute(.externalStorage) var payload: Data?
    var fetchedAt: Date

    init(date: String, isClosed: Bool, payload: Data?, fetchedAt: Date = .now) {
        self.date = date
        self.isClosed = isClosed
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

@Model
final class SplitRecord {
    @Attribute(.unique) var splitID: String
    var ticker: String
    var executionDate: String
    var splitFrom: Double
    var splitTo: Double

    init(_ s: SplitEvent) {
        splitID = s.id
        ticker = s.ticker
        executionDate = s.executionDate
        splitFrom = s.splitFrom
        splitTo = s.splitTo
    }
}

@Model
final class FundamentalsRecord {
    @Attribute(.unique) var ticker: String
    var payload: Data?
    var fetchedAt: Date
    var failed: Bool
    var message: String?

    init(ticker: String, payload: Data?, fetchedAt: Date, failed: Bool, message: String? = nil) {
        self.ticker = ticker
        self.payload = payload
        self.fetchedAt = fetchedAt
        self.failed = failed
        self.message = message
    }
}

/// Yahoo daily history for the backtest.
@Model
final class HistoryRecord {
    @Attribute(.unique) var ticker: String
    @Attribute(.externalStorage) var payload: Data?
    var fetchedAt: Date
    var failed: Bool
    var message: String?

    init(ticker: String, payload: Data?, fetchedAt: Date, failed: Bool, message: String? = nil) {
        self.ticker = ticker
        self.payload = payload
        self.fetchedAt = fetchedAt
        self.failed = failed
        self.message = message
    }
}

/// The user's saved basket.
@Model
final class WatchlistItem {
    @Attribute(.unique) var ticker: String
    var addedAt: Date

    init(ticker: String, addedAt: Date = .now) {
        self.ticker = ticker
        self.addedAt = addedAt
    }
}

@Model
final class BacktestRecord {
    @Attribute(.unique) var key: String
    @Attribute(.externalStorage) var payload: Data
    var createdAt: Date

    init(key: String, payload: Data, createdAt: Date = .now) {
        self.key = key
        self.payload = payload
        self.createdAt = createdAt
    }
}

@Model
final class MetadataRecord {
    @Attribute(.unique) var key: String
    var value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

enum CacheSchema {
    static let models: [any PersistentModel.Type] = [
        PriceDay.self, SplitRecord.self, FundamentalsRecord.self, HistoryRecord.self,
        WatchlistItem.self, BacktestRecord.self, MetadataRecord.self,
    ]
}
