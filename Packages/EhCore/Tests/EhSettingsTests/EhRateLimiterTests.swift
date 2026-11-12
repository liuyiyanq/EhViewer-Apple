import XCTest
@testable import EhSettings

/// 放行记录，按放行先后追加
private actor ReleaseLog {
    private(set) var entries: [(label: String, time: ContinuousClock.Instant)] = []

    func append(_ label: String) {
        entries.append((label, .now))
    }

    var labels: [String] { entries.map(\.label) }
}

final class EhRateLimiterTests: XCTestCase {

    /// 10 个并发等待者按速率逐个放行，不会一起放行
    func testWaitApiSlot_ReleasesOneTokenAtATime() async throws {
        let limiter = EhRateLimiter(apiRefillRate: 10, apiBurstCapacity: 1)
        let log = ReleaseLog()
        let start = ContinuousClock.now

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await limiter.waitApiSlot(priority: .interactive)
                    await log.append("\(i)")
                }
            }
            try await group.waitForAll()
        }

        let entries = await log.entries
        XCTAssertEqual(entries.count, 10)
        // 首个用掉 burst，其余 9 个每 0.1 秒放行一个
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(850))
        for (previous, next) in zip(entries, entries.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.time - previous.time, .milliseconds(70))
        }
    }

    /// 下载请求不占 token：浏览请求排队时下载请求照样直接放行
    func testWaitApiSlot_DownloadIsNotLimited() async throws {
        let limiter = EhRateLimiter(apiRefillRate: 1, apiBurstCapacity: 1)
        try await limiter.waitApiSlot(priority: .interactive)  // 用掉 burst
        let queued = Task { try await limiter.waitApiSlot(priority: .interactive) }

        let start = ContinuousClock.now
        for _ in 0..<10 {
            try await limiter.waitApiSlot(priority: .download)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(100))
        queued.cancel()
    }

    /// 排队中被取消的请求抛出 CancellationError，且不占用 token
    func testWaitApiSlot_CancelledWaiterIsNotReleased() async throws {
        let limiter = EhRateLimiter(apiRefillRate: 5, apiBurstCapacity: 1)
        try await limiter.waitApiSlot(priority: .interactive)  // 用掉 burst

        let cancelled = Task {
            try await limiter.waitApiSlot(priority: .interactive)
        }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()

        do {
            try await cancelled.value
            XCTFail("取消后不应被放行")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        // 下一个等待者拿到被取消者让出的 token，约 0.2 秒内放行
        let start = ContinuousClock.now
        try await limiter.waitApiSlot(priority: .interactive)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(400))
    }

    /// 图片槽位等待被取消时不占用槽位
    func testAcquireImageSlot_CancelledWaiterDoesNotTakeSlot() async throws {
        let limiter = EhRateLimiter(maxImageConcurrent: 1)
        try await limiter.acquireImageSlot()

        let waiting = Task { try await limiter.acquireImageSlot() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("取消后不应拿到槽位")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        await limiter.releaseImageSlot()
        // 槽位已归还，可立即获取
        try await limiter.acquireImageSlot()
    }
}
