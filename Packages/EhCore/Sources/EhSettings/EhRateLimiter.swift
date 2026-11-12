//
//  EhRateLimiter.swift
//  EhCore
//
//  全局速率限制器 — 防止 IP 封禁 (V-08, V-09)
//  浏览页面/接口请求: 排队放行，2 次/秒，burst 3
//  下载取页请求: 不占限速，并发由下载线程数控制
//  图片下载: 全局最多 5 并发
//

import Foundation

/// 全局速率限制器 — 所有网络请求共享同一实例
/// - 页面/接口请求 (EhAPI): `try await waitApiSlot(priority:)`
///   浏览请求进入队列，每产生一个 token 只放行一个；排队中的任务被取消时从队列移除，不再发出请求
/// - 图片下载 (SpiderQueen): `try await acquireImageSlot()` / `releaseImageSlot()` → 全局最多 5 并发
public actor EhRateLimiter {
    public static let shared = EhRateLimiter()

    /// 请求优先级
    public enum Priority: Sendable {
        /// 浏览、阅读 —— 按 token 桶限速
        case interactive
        /// 后台下载 —— 不占 token：下载线程数本身限制了并发，
        /// 再叠加每秒 2 次的上限会让多线程下载失去意义
        case download
    }

    // MARK: - Token Bucket (API)

    /// 桶容量 (burst 上限)
    private let apiBurstCapacity: Double
    /// 每秒填充速率 (tokens/sec)
    private let apiRefillRate: Double
    /// 当前可用 token 数
    private var apiTokens: Double
    /// 上次填充时间
    private var apiLastRefill: ContinuousClock.Instant = .now

    private struct ApiWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    /// 等待队列 — 先进先出
    private var apiWaiters: [ApiWaiter] = []
    private var nextWaiterID: UInt64 = 0
    /// 放行循环，队列为空时退出
    private var dispatcher: Task<Void, Never>?

    // MARK: - Semaphore (Image Downloads)

    /// 全局最大并发图片下载数
    private let maxImageConcurrent: Int
    /// 当前活跃下载数
    private var activeImageCount = 0

    private struct ImageWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    /// 等待队列 — FIFO
    private var imageWaiters: [ImageWaiter] = []

    init(apiRefillRate: Double = 2.0, apiBurstCapacity: Double = 3.0, maxImageConcurrent: Int = 5) {
        self.apiRefillRate = apiRefillRate
        self.apiBurstCapacity = apiBurstCapacity
        self.apiTokens = apiBurstCapacity
        self.maxImageConcurrent = maxImageConcurrent
    }

    // MARK: - API Slot

    /// 等待直到可用 API token — 每次放行消耗 1 token；下载请求直接放行
    /// - Throws: 等待期间任务被取消时抛出 CancellationError，此时不消耗 token
    public func waitApiSlot(priority: Priority = .interactive) async throws {
        try Task.checkCancellation()
        if priority == .download { return }

        refillApiTokens()
        if apiTokens >= 1.0, apiWaiters.isEmpty {
            apiTokens -= 1.0
            return
        }

        nextWaiterID += 1
        let id = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // 取消可能发生在入队之前，此时 onCancel 找不到等待者，必须在这里拦下
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                apiWaiters.append(ApiWaiter(id: id, continuation: cont))
                startDispatcherIfNeeded()
            }
        } onCancel: {
            Task { await self.cancelApiWaiter(id: id) }
        }
    }

    private func startDispatcherIfNeeded() {
        guard dispatcher == nil else { return }
        dispatcher = Task { await self.dispatchLoop() }
    }

    private func dispatchLoop() async {
        while !apiWaiters.isEmpty {
            refillApiTokens()
            if apiTokens >= 1.0 {
                apiTokens -= 1.0
                apiWaiters.removeFirst().continuation.resume()
                continue
            }
            let tokenWait = Duration.milliseconds(Int((1.0 - apiTokens) / apiRefillRate * 1000))
            try? await Task.sleep(for: max(tokenWait, .milliseconds(1)))
        }
        dispatcher = nil
    }

    private func cancelApiWaiter(id: UInt64) {
        guard let index = apiWaiters.firstIndex(where: { $0.id == id }) else { return }
        apiWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// 根据经过的时间填充 token
    private func refillApiTokens() {
        let now = ContinuousClock.now
        let elapsed = now - apiLastRefill
        apiLastRefill = now
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        apiTokens = min(apiBurstCapacity, apiTokens + seconds * apiRefillRate)
    }

    // MARK: - Image Slot

    /// 获取一个图片下载槽位 — 如果当前并发已满则挂起等待
    /// - Throws: 等待期间任务被取消时抛出 CancellationError，此时没有占用槽位，不要 release
    public func acquireImageSlot() async throws {
        try Task.checkCancellation()
        if activeImageCount < maxImageConcurrent {
            activeImageCount += 1
            return
        }

        // 当前已满 → 挂起，加入等待队列
        nextWaiterID += 1
        let id = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                imageWaiters.append(ImageWaiter(id: id, continuation: cont))
            }
        } onCancel: {
            Task { await self.cancelImageWaiter(id: id) }
        }
        // 被 resume 时槽位已在 releaseImageSlot 中直接移交
    }

    /// 释放一个图片下载槽位 — 唤醒等待队列中的下一个
    public func releaseImageSlot() {
        if !imageWaiters.isEmpty {
            // 有等待者 → 不减 activeImageCount (槽位直接移交)
            imageWaiters.removeFirst().continuation.resume()
        } else {
            activeImageCount -= 1
        }
    }

    private func cancelImageWaiter(id: UInt64) {
        guard let index = imageWaiters.firstIndex(where: { $0.id == id }) else { return }
        imageWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
