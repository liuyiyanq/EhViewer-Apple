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
    /// 图片配额已用完 (509)：剩余页不再派发
    public private(set) var isImageLimitReached = false

    /// 单页最多尝试次数 (对齐 Android SpiderWorker 最多 5 次)：用完即判失败，让出线程给后面的页
    private static let maxPageAttempts = 5
    /// 同一页最多换几个 H@H 节点 (与阅读器一致)
    private static let maxSkipHathKeys = 3

    private static let pTokenPattern = try! NSRegularExpression(pattern: #"/s/([0-9a-f]+)/\d+-(\d+)"#)

    /// 并发下载数 — 从 AppSettings 读取用户设置 (对齐 Android SpiderQueen.mWorkerPool 大小)
    private var maxConcurrent: Int {
        AppSettings.shared.multiThreadDownload
    }

    /// 下载图片 — 全局最多 5 个并发图片请求 (V-09)；超时读设置值；
    /// 走 EhAPI 获得域名前置回退。页面和接口请求另走 EhAPI 的下载档限速
    private func fetchImage(url: URL) async throws -> (Data, HTTPURLResponse) {
        try await EhRateLimiter.shared.acquireImageSlot()
        do {
            let result = try await EhAPI.shared.fetchDownloadImage(
                url: url, timeout: TimeInterval(AppSettings.shared.downloadTimeout)
            )
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
                if Task.isCancelled || isImageLimitReached { break }
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
    /// 图片下载失败时带 nl= 重新取页面换 H@H 节点；E-H 提示请求过快时等冷却后重试，不计入失败
    private func loadPage(index: Int) async {
        var lastError: Error?
        var attempt = 0
        /// 最近一次页面返回的 nl key (对齐 Android skipHathKey)
        var skipHathKey: String?
        var usedSkipHathKeys: Set<String> = []
        /// 下一次取页面时要带上的 nl key
        var nextSkipHathKey: String?

        while attempt < Self.maxPageAttempts {
            if Task.isCancelled || isImageLimitReached {
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

                // 1. 获取 pToken
                let pToken = try await getPToken(for: index)

                // 2. 获取图片 URL (换节点时必须走页面 HTML，showpage 接口不接受 nl)
                let result: GalleryPageResult
                if let currentShowKey = showKey, nextSkipHathKey == nil {
                    result = try await fetchPageApi(index: index, pToken: pToken, showKey: currentShowKey)
                } else {
                    result = try await fetchPageHtml(index: index, pToken: pToken, skipHathKey: nextSkipHathKey)
                }
                nextSkipHathKey = nil
                if let newShowKey = result.showKey {
                    showKey = newShowKey
                }
                skipHathKey = result.skipHathKey

                // 2.5 如果用户启用了"下载原始图片"且有原图 URL，优先使用 (对齐 Android downloadOriginImage)
                let finalImageUrl: String
                if AppSettings.shared.downloadOriginImage,
                   let origin = result.originImageUrl, !origin.isEmpty {
                    finalImageUrl = origin
                } else {
                    finalImageUrl = result.imageUrl
                }

                // 3. URL 有效性
                guard !finalImageUrl.isEmpty else {
                    throw SpiderError.emptyImageUrl
                }

                // 4. 509 检测
                if finalImageUrl.contains("509.gif") || finalImageUrl.contains("509s.gif") {
                    throw SpiderError.imageLimitReached
                }

                // 5. 下载图片并存储
                downloadingImage = true
                let networkBytes = try await downloadAndStore(imageUrl: finalImageUrl, index: index)

                // 6. 保存结果
                imageUrls[index] = finalImageUrl
                pageStates[index] = Self.stateFinish
                await delegate?.onPageLoaded(index: index, imageUrl: finalImageUrl, networkBytes: networkBytes)
                activeTasks.removeValue(forKey: index)
                return

            } catch is CancellationError {
                markCancelled(index)
                return
            } catch SpiderError.imageLimitReached {
                await handleImageLimitReached(index)
                return
            } catch {
                if Task.isCancelled {
                    markCancelled(index)
                    return
                }
                lastError = error
                // 图片下载失败多半是 H@H 节点不可用，带 nl= 重新取页面换一个节点；
                // 服务器重复返回同一个 key 说明没有别的节点了 (对齐 Android leakSkipHathKey)
                if downloadingImage, let key = skipHathKey, !key.isEmpty,
                   !usedSkipHathKeys.contains(key), usedSkipHathKeys.count < Self.maxSkipHathKeys {
                    usedSkipHathKeys.insert(key)
                    nextSkipHathKey = key
                }
                // showKey 可能过期，清除后下次使用 HTML 方式
                if attempt > 0 { showKey = nil }
                attempt += 1
                // 下载延迟 (downloadDelay, 毫秒) 为基础的指数退避：默认 0.5、1、2、4 秒
                if attempt < Self.maxPageAttempts {
                    let userDelay = Double(max(500, AppSettings.shared.downloadDelay))
                    let delayMs = userDelay * pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(for: .milliseconds(Int(delayMs)))
                }
            }
        }

        // 所有重试失败
        pageStates[index] = Self.stateFailed
        await delegate?.onPageFailed(index: index, error: lastError ?? SpiderError.networkError)
        activeTasks.removeValue(forKey: index)
    }

    /// 图片配额用完：剩余页也拿不到，停止派发并通知，整本由 DownloadManager 按磁盘判为失败
    private func handleImageLimitReached(_ index: Int) async {
        pageStates[index] = Self.stateFailed
        activeTasks.removeValue(forKey: index)
        guard !isImageLimitReached else { return }
        isImageLimitReached = true
        await delegate?.onImageLimitReached()
        downloadTask?.cancel()
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

    /// 通过 GET 获取页面 HTML (首次获取 showKey，或带 nl= 换 H@H 节点)
    private func fetchPageHtml(index: Int, pToken: String, skipHathKey: String?) async throws -> GalleryPageResult {
        var url = EhURL.pageUrl(gid: galleryInfo.gid, index: index, pToken: pToken, site: AppSettings.shared.gallerySite)
        if let key = skipHathKey, !key.isEmpty {
            url += (url.contains("?") ? "&" : "?") + "nl=\(key)"
        }
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
