import Foundation

/// Time source for the scheduler, injectable so tests run instantly.
public protocol SchedulerClock: Sendable {
    /// Seconds since an arbitrary fixed origin.
    func now() -> Double
    func sleep(seconds: Double) async throws
    /// Calendar day used for daily quotas ("yyyy-MM-dd").
    func dayKey() -> String
}

public struct SystemClock: SchedulerClock {
    public init() {}
    public func now() -> Double { Date().timeIntervalSince1970 }
    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    public func dayKey() -> String { TradingCalendar.isoString(Date(), timeZone: .current) }
}

/// Persists how many calls were made today, for providers with a daily cap (FMP free: 250/day).
public protocol DailyUsageStore: Sendable {
    func count(provider: String, day: String) -> Int
    func increment(provider: String, day: String)
}

public final class UserDefaultsUsageStore: DailyUsageStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ p: String, _ d: String) -> String { "usage.\(p).\(d)" }
    public func count(provider: String, day: String) -> Int { defaults.integer(forKey: key(provider, day)) }
    public func increment(provider: String, day: String) {
        defaults.set(count(provider: provider, day: day) + 1, forKey: key(provider, day))
    }
}

public enum SchedulerError: Error, Equatable, Sendable {
    case dailyLimitReached(limit: Int)
    case retriesExhausted(HTTPError)
}

/// One scheduler per provider. Every request goes through `run`, which:
///  1. enforces a sliding-window calls-per-minute limit (and an optional daily cap),
///  2. retries rate-limit and transient errors with exponential backoff,
///  3. reports waiting state for the progress UI.
public actor RequestScheduler {
    public struct Config: Sendable, Equatable {
        public var callsPerMinute: Int
        public var maxRetries: Int
        public var baseBackoff: Double
        public var maxBackoff: Double
        public var dailyLimit: Int?

        public init(callsPerMinute: Int, maxRetries: Int = 5, baseBackoff: Double = 2,
                    maxBackoff: Double = 120, dailyLimit: Int? = nil) {
            self.callsPerMinute = max(1, callsPerMinute)
            self.maxRetries = maxRetries
            self.baseBackoff = baseBackoff
            self.maxBackoff = maxBackoff
            self.dailyLimit = dailyLimit
        }
    }

    public struct Status: Sendable, Equatable {
        public var waitingForSlot: Int
        public var completed: Int
        public var retries: Int
        /// When the next slot opens, if the window is full (clock seconds).
        public var nextSlotAt: Double?
    }

    public let name: String
    public private(set) var config: Config
    private let clock: SchedulerClock
    private let usage: DailyUsageStore?
    private var window: [Double] = []
    private var status = Status(waitingForSlot: 0, completed: 0, retries: 0, nextSlotAt: nil)

    public init(name: String, config: Config, clock: SchedulerClock = SystemClock(), usage: DailyUsageStore? = nil) {
        self.name = name
        self.config = config
        self.clock = clock
        self.usage = usage
    }

    public func update(callsPerMinute: Int) {
        config.callsPerMinute = max(1, callsPerMinute)
    }

    public func update(dailyLimit: Int?) {
        config.dailyLimit = dailyLimit
    }

    public func snapshot() -> Status { status }

    /// Calls left today under the daily cap, or nil if uncapped.
    public func remainingToday() -> Int? {
        guard let limit = config.dailyLimit else { return nil }
        let used = usage?.count(provider: name, day: clock.dayKey()) ?? 0
        return max(0, limit - used)
    }

    /// Waits for a slot in the per-minute window. The check-and-append has no suspension
    /// point between them, so concurrent callers can't oversubscribe the window.
    private func acquire() async throws {
        status.waitingForSlot += 1
        defer { status.waitingForSlot -= 1 }
        while true {
            try Task.checkCancellation()
            let now = clock.now()
            window.removeAll { $0 <= now - 60 }
            if window.count < config.callsPerMinute {
                window.append(now)
                status.nextSlotAt = nil
                return
            }
            let wait = window[0] + 60 - now
            status.nextSlotAt = window[0] + 60
            try await clock.sleep(seconds: max(wait, 0.001))
        }
    }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            if let limit = config.dailyLimit, let usage,
               usage.count(provider: name, day: clock.dayKey()) >= limit {
                throw SchedulerError.dailyLimitReached(limit: limit)
            }
            try await acquire()
            usage?.increment(provider: name, day: clock.dayKey())
            do {
                let value = try await operation()
                status.completed += 1
                return value
            } catch let error as HTTPError where error.isTransient {
                guard attempt < config.maxRetries else { throw SchedulerError.retriesExhausted(error) }
                status.retries += 1
                try await clock.sleep(seconds: backoff(attempt: attempt, error: error))
                attempt += 1
            }
        }
    }

    /// base × 2^attempt, capped; a server-provided Retry-After wins when larger.
    public func backoff(attempt: Int, error: HTTPError) -> Double {
        let exp = min(config.maxBackoff, config.baseBackoff * pow(2, Double(attempt)))
        if case .rateLimited(let retryAfter?) = error { return min(config.maxBackoff, max(exp, retryAfter)) }
        return exp
    }
}
