import Foundation
import EhModels
import EhSettings
import EhAPI

// MARK: - SpiderQueen (对应 Android SpiderQueen.java)
// 画廊图片加载引擎核心，使用 Swift Actor 保证线程安全
// 原始 Android 版本使用 AsyncTask + Thread 池，此处使用 structured concurrency

public actor SpiderQueen {

    // MARK: - 状态常量 (与 Android 保持一致)

    public static let stateNone    = 0
    public static let stateLoading = 1
    public static let stateFinish  = 2
    public static let stateFailed  = 3

    public enum Mode: Sendable {
        case read      // 阅读模式 (顺序预加载)
        case download  // 下载模式 (全量下载)
    }

    // MARK: - 属性

    public let galleryInfo: GalleryInfo
    public private(set) var spiderInfo: SpiderInfo
    private var mode: Mode
    private var pageStates: [Int]       // 每页的加载状态
    private var imageUrls: [String?]    // 每页的图片 URL
    private var showKey: String?        // showpage API 的 showKey
    private var activeTasks: [Int: Task<Void, Never>] = [:]
    /// 下载模式的页面任务都在这个 Task 的 TaskGroup 里，cancelAll 取消它才能停住下载
    private var downloadTask: Task<Void, Never>?
    /// 进行中的详情页请求 (按详情页号)，同一个详情页只请求一次
    private var detailPageLoads: [Int: Task<Void, Error>] = [:]
    /// 整本停止下载的原因 (509、IP 封禁、画廊已删除等)：设上后剩余页不再派发
    public private(set) var stopReason: SpiderStopReason?

    /// 单页最多尝试次数 (对齐 Android SpiderWorker 最多 5 次)：用完即判失败，让出线程给后面的页
    private static let maxPageAttempts = 5

    private static let pTokenPattern = try! NSRegularExpression(pattern: #"/s/([0-9a-f]+)/\d+-(\d+)"#)

    /// 并发下载数 — 从 AppSettings 读取用户设置 (对齐 Android SpiderQueen.mWorkerPool 大小)
    private var maxConcurrent: Int {
        AppSettings.shared.multiThreadDownload
    }

    /// 下载图片 — 占全局图片槽位 (V-09)；不限单张总时长；
    /// 走 EhAPI 获得域名前置回退。页面和接口请求另走 EhAPI 的下载档限速
    private func fetchImage(url: URL) async throws -> (Data, HTTPURLResponse) {
        try await EhRateLimiter.shared.acquireImageSlot()
        do {
            let result = try await EhAPI.shared.fetchDownloadImage(url: url)
            await EhRateLimiter.shared.releaseImageSlot()
            return result
        } catch {
            await EhRateLimiter.shared.releaseImageSlot()
            throw error
        }
    }

    /// 图片存储管理器 (对应 Android SpiderDen)
    private let spiderDen: SpiderDen

    /// 回调通知
    public weak var delegate: SpiderDelegate?

    // MARK: - 生命周期

    /// - Parameter downloadDir: 画廊下载目录，由 DownloadManager 解析后传入
    public init(galleryInfo: GalleryInfo, spiderInfo: SpiderInfo, mode: Mode = .read, downloadDir: URL) {
        self.galleryInfo = galleryInfo
        self.spiderInfo = spiderInfo
        self.mode = mode
        // 模式在构造时确定：若用不等待的 Task 设置，首批页面可能在切换前写进阅读缓存
        self.spiderDen = SpiderDen(
            galleryInfo: galleryInfo,
            mode: mode == .download ? .download : .read,
            downloadDir: downloadDir
        )

        let pageCount = galleryInfo.pages
        self.pageStates = Array(repeating: Self.stateNone, count: pageCount)
        self.imageUrls = Array(repeating: nil, count: pageCount)
    }

    // MARK: - 公共接口

    /// 请求加载指定页面 (对应 Android request)
    public func request(index: Int, force: Bool = false) {
        guard index >= 0 && index < pageStates.count else { return }

        if !force && (pageStates[index] == Self.stateLoading || pageStates[index] == Self.stateFinish) {
            return
        }

        pageStates[index] = Self.stateLoading

        // 取消旧任务
        activeTasks[index]?.cancel()

        // 启动新任务
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.loadPage(index: index)
        }
        activeTasks[index] = task
    }

    /// 批量预加载 (对应 Android preloadPages)
    public func preload(around index: Int, range: Int = 5) {
        let start = max(0, index - 1)
        let end = min(pageStates.count, index + range)

        for i in start..<end {
            request(index: i)
        }
    }

    /// 开始下载模式 (对应 Android setMode(MODE_DOWNLOAD))
    /// 使用 TaskGroup 实现并发控制，等待所有页面下载完成后再返回
    public func startDownload() async {
        mode = .download

        // 收集需要下载的页面索引
        var pagesToDownload: [Int] = []
        for i in 0..<pageStates.count {
            if pageStates[i] != Self.stateFinish {
                pagesToDownload.append(i)
            }
        }

        guard !pagesToDownload.isEmpty else { return }

        let task = Task { await self.downloadPages(pagesToDownload) }
        downloadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        downloadTask = nil
    }

    /// 使用 TaskGroup 配合信号量控制并发数 (对齐 Android SpiderQueen.mWorkerPool)
    private func downloadPages(_ pagesToDownload: [Int]) async {
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var index = 0

            while index < pagesToDownload.count {
                if Task.isCancelled || stopReason != nil { break }
                if inFlight < maxConcurrent {
                    let pageIndex = pagesToDownload[index]
                    pageStates[pageIndex] = Self.stateLoading
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        await self.loadPage(index: pageIndex)
                    }
                    inFlight += 1
                    index += 1
                } else {
                    // 等待一个任务完成再继续
                    await group.next()
                    inFlight -= 1
                }
            }

            // 等待剩余任务完成
            await group.waitForAll()
        }
    }

    /// 获取页面状态
    public func getPageState(_ index: Int) -> Int {
        guard index >= 0 && index < pageStates.count else { return Self.stateNone }
        return pageStates[index]
    }

    /// 获取页面图片 URL (远程或本地)
    public func getImageUrl(_ index: Int) -> String? {
        guard index >= 0 && index < imageUrls.count else { return nil }
        return imageUrls[index]
    }

    /// 获取本地图片文件 URL (用于显示已下载的图片)
    public func getLocalImageUrl(_ index: Int) async -> URL? {
        return await spiderDen.getImageFileURL(index: index)
    }

    /// 读取图片数据 (从缓存或下载目录)
    public func getImageData(_ index: Int) async -> Data? {
        return await spiderDen.read(index: index)
    }

    /// 取消所有任务
    public func cancelAll() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        downloadTask?.cancel()
        downloadTask = nil
    }

    /// 设置回调代理
    public func setDelegate(_ delegate: SpiderDelegate?) {
        self.delegate = delegate
    }

    /// 获取当前 SpiderInfo (包含已更新的 pTokenMap)
    public func getSpiderInfo() -> SpiderInfo {
        return spiderInfo
    }

    /// 更新 pToken (用于外部添加)
    public func updatePToken(index: Int, token: String) {
        spiderInfo.pTokenMap[index] = token
    }

    // MARK: - 核心加载管线 (对应 Android SpiderQueen.run)

    /// 加载单页图片 (对齐 Android SpiderWorker.downloadImage)
    /// 管线: 检查缓存 → 获取 pToken → 构建页面 URL → 获取图片 URL → 下载图片 → 存储
    /// 图片下载失败：先用同一地址重试 1 次 (不经过主站，不扣配额)；再失败不带 nl= 重新向主站要 1 次地址
    /// (按普通看图扣 1 次，主站可能分到别的节点)；仍失败判本页失败。重试之间不等待
    /// 不用 nl= 换节点：官方规则里强制重载失败的图算 50 次配额
    private func loadPage(index: Int) async {
        var lastError: Error?
        var attempt = 0
        /// 当前要下载的图片地址；为 nil 时向主站重新取
        var imageUrl: String?
        var retriedSameUrl = false
        var refetchedUrl = false

        attemptLoop: while attempt < Self.maxPageAttempts {
            if Task.isCancelled || stopReason != nil {
                markCancelled(index)
                return
            }
            var downloadingImage = false
            do {
                // 0. 检查是否已在缓存/下载目录中 (快速路径)
                if await spiderDen.contain(index: index) {
                    pageStates[index] = Self.stateFinish
                    if let fileUrl = await spiderDen.getImageFileURL(index: index) {
                        imageUrls[index] = fileUrl.absoluteString
                        await delegate?.onPageLoaded(index: index, imageUrl: fileUrl.absoluteString, networkBytes: 0)
                    }
                    activeTasks.removeValue(forKey: index)
                    return
                }

                let finalImageUrl: String
                if let current = imageUrl {
                    // 同一地址重试，不再请求主站
                    finalImageUrl = current
                } else {
                    // 1. 获取 pToken
                    let pToken = try await getPToken(for: index)

                    // 2. 获取图片 URL
                    let result: GalleryPageResult
                    if let currentShowKey = showKey {
                        result = try await fetchPageApi(index: index, pToken: pToken, showKey: currentShowKey)
                    } else {
                        result = try await fetchPageHtml(index: index, pToken: pToken)
                    }
                    if let newShowKey = result.showKey {
                        showKey = newShowKey
                    }

                    // 2.5 如果用户启用了"下载原始图片"且有原图 URL，优先使用 (对齐 Android downloadOriginImage)
                    let resolved: String
                    if AppSettings.shared.downloadOriginImage,
                       let origin = result.originImageUrl, !origin.isEmpty {
                        resolved = origin
                    } else {
                        resolved = result.imageUrl
                    }

                    // 3. URL 有效性
                    guard !resolved.isEmpty else {
                        throw SpiderError.emptyImageUrl
                    }

                    // 4. 509 检测
                    if resolved.contains("509.gif") || resolved.contains("509s.gif") {
                        throw SpiderError.imageLimitReached
                    }
                    imageUrl = resolved
                    finalImageUrl = resolved
                }

                // 5. 下载图片并存储
                downloadingImage = true
                let networkBytes = try await downloadAndStore(imageUrl: finalImageUrl, index: index)

                // 6. 保存结果
                imageUrls[index] = finalImageUrl
                pageStates[index] = Self.stateFinish
                await delegate?.onPageLoaded(index: index, imageUrl: finalImageUrl, networkBytes: networkBytes)
                activeTasks.removeValue(forKey: index)
                await waitDownloadDelay(networkBytes: networkBytes)
                return

            } catch is CancellationError {
                markCancelled(index)
                return
            } catch {
                if Task.isCancelled {
                    markCancelled(index)
                    return
                }
                // 账号级、画廊级错误重试也没用：整本停下，原因交给 DownloadManager 处理
                if let reason = SpiderStopReason(error: error) {
                    await stopDownload(index, reason: reason, error: error)
                    return
                }
                lastError = error
                attempt += 1
                guard downloadingImage else {
                    // 向主站取地址失败：showKey 可能过期，第二次起清除，下次改用 HTML 方式
                    if attempt > 1 { showKey = nil }
                    continue
                }
                if !retriedSameUrl {
                    retriedSameUrl = true
                    continue
                }
                // 同一地址仍失败，多半是 H@H 节点不可用：重新向主站要一次地址，只要一次
                // 写盘失败与节点无关，重新要地址只会白扣配额
                let isStorageError = error as? SpiderError == .diskFull || error as? SpiderError == .storageFailed
                guard !isStorageError, !refetchedUrl else { break attemptLoop }
                refetchedUrl = true
                imageUrl = nil
            }
        }

        // 所有重试失败
        pageStates[index] = Self.stateFailed
        await delegate?.onPageFailed(index: index, error: lastError ?? SpiderError.networkError)
        activeTasks.removeValue(forKey: index)
    }

    /// 整本停止：剩余页也拿不到，停止派发并通知，整本由 DownloadManager 按磁盘判为失败
    private func stopDownload(_ index: Int, reason: SpiderStopReason, error: Error) async {
        pageStates[index] = Self.stateFailed
        activeTasks.removeValue(forKey: index)
        guard stopReason == nil else { return }
        stopReason = reason
        if SpiderStopReason.isImageLimit(error) {
            await delegate?.onImageLimitReached()
        }
        downloadTask?.cancel()
    }

    /// 下载模式下每页从网络下完后等待「下载延迟」，期间占着这个线程 (对齐 Android SpiderWorker 的 Thread.sleep(mDownloadDelay))
    private func waitDownloadDelay(networkBytes: Int64) async {
        let delay = AppSettings.shared.downloadDelay
        guard mode == .download, networkBytes > 0, delay > 0 else { return }
        try? await Task.sleep(for: .milliseconds(delay))
    }

    /// 取消后该页回到未加载状态，不计入失败
    private func markCancelled(_ index: Int) {
        pageStates[index] = Self.stateNone
        activeTasks.removeValue(forKey: index)
    }

    /// 下载图片并存储到 SpiderDen (对齐 Android: 共享 session 保持 cookies)
    /// - Returns: 从网络下载的字节数
    private func downloadAndStore(imageUrl: String, index: Int) async throws -> Int64 {
        guard let url = URL(string: imageUrl) else {
            throw SpiderError.invalidUrl
        }

        let (data, httpResponse) = try await fetchImage(url: url)

        if httpResponse.statusCode == 509 {
            throw SpiderError.imageLimitReached
        }
        guard httpResponse.statusCode == 200 else {
            throw SpiderError.networkError
        }

        // 检查数据有效性 (反劫持检测 - 纯文本响应)
        if data.count < 1000 {
            // 检查是否为纯文本（可能被劫持）
            if let text = String(data: data, encoding: .utf8),
               text.contains("<html") || text.contains("<!DOCTYPE") {
                throw SpiderError.antiHijackDetected
            }
        }

        // 从 URL 或 Content-Type 获取扩展名
        let ext = getImageExtension(from: imageUrl, response: httpResponse)

        // 存储到 SpiderDen（先检查磁盘空间）
        if !SpiderDen.hasSufficientDiskSpace(bytes: Int64(data.count) + 10 * 1024 * 1024) {
            // 磁盘满: 通知代理暂停所有下载，不再重试当前页
            await delegate?.onDiskFull()
            throw SpiderError.diskFull
        }

        // 暂停或删除后不再落盘，避免把已删除的目录重新建出来
        try Task.checkCancellation()
        let success = await spiderDen.write(data: data, index: index, extension: ext)
        if !success {
            throw SpiderError.storageFailed
        }
        return Int64(data.count)
    }

    /// 获取图片扩展名
    private func getImageExtension(from url: String, response: HTTPURLResponse) -> String {
        // 从 URL 提取
        if let urlObj = URL(string: url) {
            let ext = urlObj.pathExtension.lowercased()
            if !ext.isEmpty && SpiderDen.supportedExtensions.contains(".\(ext)") {
                return ".\(ext)"
            }
        }

        // 从 Content-Type 推断
        if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
            if contentType.contains("jpeg") || contentType.contains("jpg") {
                return ".jpg"
            } else if contentType.contains("png") {
                return ".png"
            } else if contentType.contains("gif") {
                return ".gif"
            } else if contentType.contains("webp") {
                return ".webp"
            }
        }

        return ".jpg" // 默认
    }

    // MARK: - pToken 管理

    /// 获取指定页面的 pToken (对齐 Android SpiderQueen.getPTokenFromInternet)
    /// pToken 包含在详情页的预览链接中；每个详情页的缩略图数取决于账号设置，从第 0 页得出
    private func getPToken(for index: Int) async throws -> String {
        // 优先从 SpiderInfo 缓存获取
        if let token = spiderInfo.pTokenMap[index] {
            return token
        }

        if spiderInfo.previewPerPage <= 0 {
            try await loadDetailPage(0)
            if let token = spiderInfo.pTokenMap[index] {
                return token
            }
        }

        let perPage = spiderInfo.previewPerPage > 0 ? spiderInfo.previewPerPage : 20
        try await loadDetailPage(index / perPage)
        if let token = spiderInfo.pTokenMap[index] {
            return token
        }

        throw SpiderError.pTokenNotFound
    }

    /// 同一个详情页只请求一次：并发的页面任务等待同一个请求的结果
    private func loadDetailPage(_ detailPage: Int) async throws {
        if let pending = detailPageLoads[detailPage] {
            try await pending.value
            return
        }
        let task = Task { try await self.fetchDetailPage(detailPage) }
        detailPageLoads[detailPage] = task
        defer { detailPageLoads[detailPage] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 请求一个详情页，解析其中的 pToken；第 0 页同时得出每页缩略图数
    private func fetchDetailPage(_ detailPage: Int) async throws {
        let siteUrl = EhURL.host(for: AppSettings.shared.gallerySite)
        let url = "\(siteUrl)g/\(galleryInfo.gid)/\(galleryInfo.token)/\(detailPage > 0 ? "?p=\(detailPage)" : "")"
        let html = try await EhAPI.shared.fetchHTML(url: url, priority: .download)

        // 从预览链接中提取 pTokens: /s/PTOKEN/GID-PAGE
        var pagesOnDetailPage = Set<Int>()
        let matches = Self.pTokenPattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches {
            guard let ptRange = Range(m.range(at: 1), in: html),
                  let pnRange = Range(m.range(at: 2), in: html),
                  let pn = Int(html[pnRange]), pn > 0 else { continue }
            spiderInfo.pTokenMap[pn - 1] = String(html[ptRange])  // 1-based → 0-based
            pagesOnDetailPage.insert(pn)
        }

        if detailPage == 0, spiderInfo.previewPerPage <= 0, !pagesOnDetailPage.isEmpty {
            spiderInfo.previewPerPage = pagesOnDetailPage.count
        }
    }

    // MARK: - 网络请求 (走 EhAPI 下载档：限速、域名前置回退、Cookie 清洁)

    /// 通过 GET 获取页面 HTML (首次获取 showKey，或 showKey 失效后)
    private func fetchPageHtml(index: Int, pToken: String) async throws -> GalleryPageResult {
        let url = EhURL.pageUrl(gid: galleryInfo.gid, index: index, pToken: pToken, site: AppSettings.shared.gallerySite)
        return try await EhAPI.shared.getGalleryPage(url: url, priority: .download)
    }

    /// 通过 POST API 获取图片 URL (showpage)
    private func fetchPageApi(index: Int, pToken: String, showKey: String) async throws -> GalleryPageResult {
        try await EhAPI.shared.getGalleryPageApi(
            gid: galleryInfo.gid,
            index: index,
            pToken: pToken,
            showKey: showKey,
            previousPToken: index > 0 ? spiderInfo.pTokenMap[index - 1] : nil,
            priority: .download
        )
    }
}

// MARK: - SpiderDelegate

public protocol SpiderDelegate: AnyObject, Sendable {
    /// - Parameter networkBytes: 本次从网络下载的字节数；页面已在磁盘或阅读缓存中时为 0
    func onPageLoaded(index: Int, imageUrl: String, networkBytes: Int64) async
    func onPageFailed(index: Int, error: Error) async
    func onImageLimitReached() async
    func onDownloadProgress(downloaded: Int, total: Int) async
    func onDiskFull() async
}

// MARK: - 失败原因

/// 整本停止下载的原因
public enum SpiderStopReason: Sendable, Equatable {
    /// 账号或 IP 层面 (509、IP 封禁、请求过快、登录失效)：后面的画廊也会失败，应暂停整个队列
    case account(String)
    /// 这本画廊本身不可用 (已删除、不可用)：重试也没用，下一本照常下载
    case gallery(String)

    /// 不属于这两类的错误返回 nil，按普通失败重试
    public init?(error: Error) {
        if Self.isImageLimit(error) {
            self = .account(SpiderQueen.failureMessage(for: error))
            return
        }
        guard let ehError = error as? EhError else { return nil }
        switch ehError {
        case .ipBanned, .openingPagesTooFast, .sadPanda, .kokomade, .igneousWrong, .cloudflare403:
            self = .account(SpiderQueen.failureMessage(for: error))
        case .pining, .galleryUnavailable, .offensive:
            self = .gallery(SpiderQueen.failureMessage(for: error))
        default:
            return nil
        }
    }

    public var message: String {
        switch self {
        case .account(let message), .gallery(let message): return message
        }
    }

    static func isImageLimit(_ error: Error) -> Bool {
        if error as? SpiderError == .imageLimitReached { return true }
        if let ehError = error as? EhError, case .imageLimitReached = ehError { return true }
        return false
    }
}

extension SpiderQueen {
    /// 下载页显示用的简短失败原因
    public static func failureMessage(for error: Error) -> String {
        if SpiderStopReason.isImageLimit(error) { return "509 配额已用完" }
        if let ehError = error as? EhError {
            switch ehError {
            case .ipBanned(let detail): return detail.isEmpty ? "IP 被临时封禁" : "IP 被临时封禁（\(detail)）"
            case .openingPagesTooFast: return "请求过快"
            case .sadPanda, .kokomade, .igneousWrong: return "登录失效或无里站权限"
            case .cloudflare403: return "Cloudflare 验证拦截"
            case .pining: return "画廊已删除"
            case .galleryUnavailable: return "画廊不可用"
            case .offensive: return "画廊有内容警告"
            case .httpError(let code, _): return "HTTP \(code)"
            case .parseError: return "页面解析失败"
            case .serverError(let message): return message
            default: return "网络错误"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "超时"
            case .notConnectedToInternet: return "无网络"
            case .networkConnectionLost: return "连接中断"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed: return "连不上服务器"
            default: return "网络错误"
            }
        }
        if let spiderError = error as? SpiderError {
            switch spiderError {
            case .pTokenNotFound: return "找不到页面链接"
            case .networkError: return "图片下载失败"
            case .storageFailed: return "保存失败"
            case .diskFull: return "存储空间不足"
            default: return "图片地址无效"
            }
        }
        return "未知错误"
    }
}

// MARK: - 错误

public enum SpiderError: LocalizedError, Sendable {
    case pTokenNotFound
    case emptyImageUrl
    case imageLimitReached
    case antiHijackDetected
    case invalidUrl
    case networkError
    case invalidResponseData
    case notImplemented
    case storageFailed
    case diskFull

    public var errorDescription: String? {
        switch self {
        case .pTokenNotFound: return "pToken not found"
        case .emptyImageUrl: return "Empty image URL"
        case .imageLimitReached: return "509 Image limit reached"
        case .antiHijackDetected: return "Anti-hijack: pure text response"
        case .invalidUrl: return "Invalid URL"
        case .networkError: return "Network request failed"
        case .invalidResponseData: return "Invalid response data"
        case .notImplemented: return "Not implemented"
        case .storageFailed: return "Failed to save image to disk"
        case .diskFull: return "磁盘空间不足，无法保存图片"
        }
    }
}
