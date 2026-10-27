import XCTest
@testable import FactorData

/// Virtual clock: `sleep` advances time instantly and records how long was requested.
final class TestClock: SchedulerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double = 1_000
    private(set) var sleeps: [Double] = []
    var day = "2026-10-27"

    func now() -> Double { lock.lock(); defer { lock.unlock() }; return t }
    func sleep(seconds: Double) async throws {
        lock.withLock { t += seconds; sleeps.append(seconds) }
    }
    func dayKey() -> String { lock.lock(); defer { lock.unlock() }; return day }
    func advance(_ s: Double) { lock.lock(); t += s; lock.unlock() }
}

final class MemoryUsage: DailyUsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func count(provider: String, day: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts["\(provider)|\(day)"] ?? 0 }
    func increment(provider: String, day: String) { lock.lock(); counts["\(provider)|\(day)", default: 0] += 1; lock.unlock() }
}

/// Records the clock time of each call.
actor CallLog {
    var times: [Double] = []
    func record(_ t: Double) { times.append(t) }
}

final class RateLimiterTests: XCTestCase {

    func testFirstNCallsRunImmediatelyThenWaitForWindow() async throws {
        let clock = TestClock()
        let s = RequestScheduler(name: "m", config: .init(callsPerMinute: 5), clock: clock)
        let log = CallLog()
        for _ in 0..<7 {
            _ = try await s.run { await log.record(clock.now()); return 1 }
        }
        let times = await log.times
        // Calls 1–5 at t=1000; call 6 waits until the first slot expires (t=1060); call 7 too.
        XCTAssertEqual(Array(times.prefix(5)), [1000, 1000, 1000, 1000, 1000])
        XCTAssertEqual(times[5], 1060, accuracy: 1e-9)
        XCTAssertEqual(times[6], 1060, accuracy: 1e-9)
        // No more than 5 calls in any 60-second window.
        for (i, t) in times.enumerated() {
            XCTAssertLessThanOrEqual(times.filter { $0 > t - 60 && $0 <= t }.count, 5, "window ending at call \(i)")
        }
    }

    func testCallsSpacedOutDoNotWait() async throws {
        let clock = TestClock()
        let s = RequestScheduler(name: "m", config: .init(callsPerMinute: 2), clock: clock)
        for _ in 0..<4 {
            _ = try await s.run { 0 }
            clock.advance(31)
        }
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    func testConcurrentCallersNeverExceedLimit() async throws {
        let clock = TestClock()
        let s = RequestScheduler(name: "m", config: .init(callsPerMinute: 3), clock: clock)
        let log = CallLog()
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<9 {
                g.addTask { _ = try await s.run { await log.record(clock.now()); return 0 } }
            }
            try await g.waitForAll()
        }
        let times = await log.times.sorted()
        XCTAssertEqual(times.count, 9)
        for t in times {
            XCTAssertLessThanOrEqual(times.filter { $0 > t - 60 && $0 <= t }.count, 3)
        }
    }

    func testRetriesRateLimitWithExponentialBackoff() async throws {
        let clock = TestClock()
        let s = RequestScheduler(name: "m", config: .init(callsPerMinute: 100, maxRetries: 5, baseBackoff: 2), clock: clock)
        let attempts = CallLog()
        let value = try await s.run { () async throws -> Int in
            await attempts.record(0)
            if await attempts.times.count < 4 { throw HTTPError.rateLimited(retryAfter: nil) }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(clock.sleeps, [2, 4, 8])
        let status = await s.snapshot()
        XCTAssertEqual(status.retries, 3)
        XCTAssertEqual(status.completed, 1)
    }

    func testRetryAfterHeaderIsRespected() async {
        let s = RequestScheduler(name: "m", config: .init(callsPerMinute: 5, baseBackoff: 2), clock: TestClock())
        let d = await s.backoff(attempt: 0, error: .rateLimited(retryAfter: 30))
        XCTAssertEqual(d, 30)
        let capped = await s.backoff(attempt: 20, error: .server(status: 503))
        XCTAssertEqual(capped, 120)
    }

    func testGivesUpAfterMaxRetries() async {
        let clock = TestClock()
        let s = RequestScheduler(name: "m", config: .init(callsPerMinute: 100, maxRetries: 2, baseBackoff: 1), clock: clock)
        do {
            _ = try await s.run { () async throws -> Int in throw HTTPError.rateLimited(retryAfter: nil) }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? SchedulerError, .retriesExhausted(.rateLimited(retryAfter: nil)))
        }
        XCTAssertEqual(clock.sleeps, [1, 2])
    }

    func testNonTransientErrorsAreNotRetried() async {
        let clock = TestClock()
        let s = RequestScheduler(name: "m", config: .init(callsPerMinute: 100), clock: clock)
        do {
            _ = try await s.run { () async throws -> Int in throw HTTPError.unauthorized }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? HTTPError, .unauthorized)
        }
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    func testDailyLimit() async throws {
        let clock = TestClock()
        let usage = MemoryUsage()
        let s = RequestScheduler(name: "fmp", config: .init(callsPerMinute: 100, dailyLimit: 3), clock: clock, usage: usage)
        for _ in 0..<3 { _ = try await s.run { 0 } }
        let left = await s.remainingToday()
        XCTAssertEqual(left, 0)
        do {
            _ = try await s.run { 0 }
            XCTFail("expected daily limit")
        } catch {
            XCTAssertEqual(error as? SchedulerError, .dailyLimitReached(limit: 3))
        }
        clock.day = "2026-10-28"
        _ = try await s.run { 0 }   // new day, quota reset
    }

    func testLimitCanBeChangedAtRuntime() async throws {
        let clock = TestClock()
        let s = RequestScheduler(name: "m", config: .init(callsPerMinute: 1), clock: clock)
        _ = try await s.run { 0 }
        await s.update(callsPerMinute: 2)
        _ = try await s.run { 0 }
        XCTAssertTrue(clock.sleeps.isEmpty)
    }
}
