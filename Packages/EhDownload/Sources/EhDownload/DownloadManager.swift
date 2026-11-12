import Foundation
import EhModels
import EhDatabase
import EhSpider
#if canImport(UIKit)
import UIKit
#endif

// MARK: - DownloadManager (对应 Android DownloadManager.java)
// 下载队列管理 Actor

public actor DownloadManager {
    public static let shared = DownloadManager()

    // MARK: - 状态常量

    public static let stateInvalid = -1
    public static let stateNone    = 0
    public static let stateWait    = 1
    public static let stateDownload = 2
    public static let stateFinish  = 3
    public static let stateFailed  = 4

    // MARK: - 属性

    /// 下载队列
    /// ⚠️ lazy: 首次访问时同步从数据库加载。
    ///   以前是 init 里 `Task { await loadFromDatabase() }` —— Actor 不保证 Task 之间的
    ///   执行顺序，App 启动后立刻打开已下载画廊时队列可能还是空的，
    ///   于是被判定为"未下载"、整本走网络 (issue #8 问题二)
    ///   加载前先扫描一次下载目录刷新路径索引，否则改过名或移动过的画廊目录会被当成"未下载"
    private lazy var downloadQueue: [DownloadTask] = {
        refreshDirectoryIndex()
        return tasksFromDatabase()
    }()
    /// gid → 画廊目录相对路径，见 GalleryDirectoryIndex
    private nonisolated let directoryIndex = GalleryDirectoryIndex()
    private var activeTask: DownloadTask?
    /// 当前这一轮下载的编号 — executeDownload 每次从 await 恢复后都要用它确认
    /// 自己是否仍是当前一轮。按 gid 判断不够：暂停后立即恢复同一本时，新旧两轮 gid 相同
    private var currentRunID: Int?
    private var lastRunID = 0
    /// 当前一轮下载所在的 Task — 暂停/删除时同步取消，在途页面任务随之停止
    private var runTask: Task<Void, Never>?
    /// 整层重新编号时正在下载的画廊延后改名：gid → 目标相对路径，下载停止后执行
    private var pendingRenames: [Int64: String] = [:]
    private var isRunning = false

    /// 下载监听器（用于通知集成）
    public weak var listener: DownloadListener?

    /// 下载目录
    public nonisolated var downloadDirectory: URL {
        // macOS: 支持用户自定义路径
        #if os(macOS)
        if let customPath = UserDefaults.standard.string(forKey: "downloadPath"),
           !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("download")
    }

    private init() {
        // 确保下载目录存在
        var dir = downloadDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // iOS/iPadOS: 排除 iCloud 备份
        #if os(iOS)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? dir.setResourceValues(resourceValues)
        #endif
    }

    /// 从数据库加载已有下载任务 (nonisolated: 供 lazy 属性同步初始化)
    private nonisolated func tasksFromDatabase() -> [DownloadTask] {
        do {
            let records = try EhDatabase.shared.getAllDownloads()
            var tasks: [DownloadTask] = records.map { record in
                let gallery = GalleryInfo(
                    gid: record.gid, token: record.token,
                    title: record.title, titleJpn: record.titleJpn,
                    thumb: record.thumb,
                    category: EhCategory(rawValue: record.category),
                    posted: record.posted, uploader: record.uploader,
                    rating: record.rating, pages: record.pages
                )
                return DownloadTask(gallery: gallery, state: record.state, date: record.date)
            }
            // 扫描磁盘已下载的图片文件，恢复中断下载的进度
            for i in tasks.indices {
                let task = tasks[i]
                if task.state == Self.stateFinish {
                    // 已完成的任务直接设置为总页数
                    tasks[i].downloadedPages = task.gallery.pages
                } else if task.gallery.pages > 0 {
                    // 扫描目录中已有的图片文件数
                    let dir = galleryDirectory(gid: task.gallery.gid, title: task.gallery.bestTitle)
                    let existingPages = SpiderInfoFile.getDownloadedPages(in: dir, totalPages: task.gallery.pages)
                    tasks[i].downloadedPages = existingPages.count
                }
            }
            return tasks
        } catch {
            print("Failed to load downloads from database: \(error)")
            return []
        }
    }

    // MARK: - 公共接口

    /// 添加下载任务 (Fix A-1: 已有 failed/none 状态时自动恢复而非静默忽略)
    public func startDownload(gallery: GalleryInfo) async {
        // 检查是否已在队列中
        if let existingIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gallery.gid }) {
            let existingState = downloadQueue[existingIndex].state
            if existingState == Self.stateNone || existingState == Self.stateFailed {
                // 已暂停或已失败 → 重置为等待并恢复
                downloadQueue[existingIndex].state = Self.stateWait
                try? EhDatabase.shared.updateDownloadState(gid: gallery.gid, state: Self.stateWait)
                if !isRunning { processQueue() }
            }
            // stateWait / stateDownload / stateFinish → 不重复操作
            return
        }

        let task = DownloadTask(gallery: gallery)
        downloadQueue.append(task)

        // 持久化到数据库
        let record = DownloadRecord(
            gid: gallery.gid, token: gallery.token,
            title: gallery.bestTitle, titleJpn: gallery.titleJpn,
            thumb: gallery.thumb, category: gallery.category.rawValue,
            posted: gallery.posted, uploader: gallery.uploader,
            rating: gallery.rating, simpleLanguage: gallery.simpleLanguage,
            pages: gallery.pages, state: Self.stateWait, date: Date()
        )
        try? EhDatabase.shared.insertDownload(record)

        // 启动队列处理
        if !isRunning {
            processQueue()
        }
    }

    /// 暂停下载
    public func pauseDownload(gid: Int64) {
        let wasActive = activeTask?.gallery.gid == gid
        if wasActive {
            // 正在 await 中的 executeDownload 恢复后会因编号失效自行退出，
            // 不会再把状态写回队列 (否则会覆盖这里设置的"已暂停")
            stopActiveRun()
        }
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].state = Self.stateNone
            downloadQueue[index].spider = nil
            try? EhDatabase.shared.updateDownloadState(gid: gid, state: Self.stateNone)
        }
        if wasActive { processQueue() }
    }

    /// 暂停所有下载（磁盘满时紧急调用）
    public func pauseAllDownloads() {
        // 取消当前活跃任务
        stopActiveRun()
        isRunning = false

        // 暂停队列中所有等待/下载中的任务
        for i in downloadQueue.indices {
            if downloadQueue[i].state == Self.stateWait || downloadQueue[i].state == Self.stateDownload {
                downloadQueue[i].state = Self.stateNone
                downloadQueue[i].spider = nil
                try? EhDatabase.shared.updateDownloadState(gid: downloadQueue[i].gallery.gid, state: Self.stateNone)
            }
        }
        print("[DownloadManager] ⚠️ 所有下载已暂停（磁盘空间不足）")
    }

    /// 恢复下载
    public func resumeDownload(gid: Int64) {
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].state = Self.stateWait
            try? EhDatabase.shared.updateDownloadState(gid: gid, state: Self.stateWait)
            // 用 activeTask == nil 判断，避免 isRunning 残留 true 时队列卡死
            if activeTask == nil {
                currentRunID = nil
                isRunning = false
                processQueue()
            }
        }
    }

    /// 强制尝试处理队列 (外部调用，修复 isRunning 残留问题)
    public func kickQueue() {
        if activeTask == nil {
            currentRunID = nil
            isRunning = false
            processQueue()
        }
    }

    /// 删除下载 (可选删除文件)
    public func deleteDownload(gid: Int64, deleteFiles: Bool = false) {
        // 先获取 gallery 信息 (必须在 removeAll 之前)
        let task = downloadQueue.first(where: { $0.gallery.gid == gid })
        let title = task?.gallery.bestTitle
        let pages = task?.gallery.pages ?? 0

        if activeTask?.gallery.gid == gid {
            // 先同步取消在途页面再删文件，正在执行的 executeDownload 恢复后也不会再访问已删除的任务
            stopActiveRun()
        }

        downloadQueue.removeAll { $0.gallery.gid == gid }
        try? EhDatabase.shared.deleteDownload(gid: gid)
        pendingRenames[gid] = nil

        if deleteFiles {
            // 清除 SpiderDen 阅读缓存
            if pages > 0 {
                SpiderDen.clearCache(forGid: gid, pages: pages)
            }

            if directoryIndex.relativePath(gid: gid) != nil || !(title ?? "").isEmpty {
                // 精确匹配: 路径索引或实际标题
                let dir = galleryDirectory(gid: gid, title: title ?? "")
                try? FileManager.default.removeItem(at: dir)
                directoryIndex.remove(gid: gid)
            } else {
                // 回退: 枚举下载目录中匹配 "gid-*" 前缀的目录
                let prefix = "\(gid)-"
                if let contents = try? FileManager.default.contentsOfDirectory(
                    at: downloadDirectory, includingPropertiesForKeys: nil) {
                    for item in contents where item.lastPathComponent.hasPrefix(prefix) {
                        try? FileManager.default.removeItem(at: item)
                    }
                }
            }
        }

        processQueue()
    }

    /// 获取所有下载任务
    public func getAllTasks() -> [DownloadTask] {
        downloadQueue
    }

    /// 获取任务状态
    public func getTaskState(gid: Int64) -> Int {
        if activeTask?.gallery.gid == gid {
            return activeTask?.state ?? Self.stateNone
        }
        return downloadQueue.first(where: { $0.gallery.gid == gid })?.state ?? Self.stateInvalid
    }

    /// 更新下载进度 (由 SpiderInfoUpdater 调用，同步到队列以便 UI 读取)
    public func updateDownloadedPages(gid: Int64, count: Int) {
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].downloadedPages = count
        }
    }

    /// 更新下载速度 (由 SpiderInfoUpdater 调用，同步到队列以便 UI 读取)
    public func updateDownloadSpeed(gid: Int64, speed: Int64) {
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].speed = speed
        }
    }

    /// 设置下载监听器
    public func setListener(_ listener: DownloadListener?) {
        self.listener = listener
    }

    // MARK: - 后台任务支持

    /// 暂停当前活跃下载 (用于后台任务过期时, 保留 stateWait 以便恢复)
    public func pauseActiveIfNeeded() {
        guard let task = activeTask else { return }
        stopActiveRun()
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == task.gallery.gid }) {
            downloadQueue[index].state = Self.stateWait
            downloadQueue[index].spider = nil
            try? EhDatabase.shared.updateDownloadState(gid: task.gallery.gid, state: Self.stateWait)
        }
        isRunning = false
    }

    /// 是否有画廊正在下载 (BGProcessingTask 据此决定何时报告完成)
    public var isDownloading: Bool {
        activeTask != nil
    }

    /// 恢复队列处理 (用于 BGProcessingTask 唤醒时)
    public func resumeAllWaiting() {
        guard !isRunning else { return }
        if downloadQueue.contains(where: { $0.state == Self.stateWait }) {
            processQueue()
        }
    }

    // MARK: - 队列处理

    private func processQueue() {
        guard activeTask == nil else { return }

        // 找到下一个等待中的任务
        guard let nextIndex = downloadQueue.firstIndex(where: { $0.state == Self.stateWait }) else {
            isRunning = false
            currentRunID = nil
            return
        }

        isRunning = true
        downloadQueue[nextIndex].state = Self.stateDownload
        activeTask = downloadQueue[nextIndex]

        // ★ 只向下传递 gid，绝不传递数组索引:
        //   executeDownload 内部有多个 await 挂起点，挂起期间 deleteDownload /
        //   pauseAllDownloads 会修改 downloadQueue，旧索引会越界或指向别的任务
        //   (对应 issue #8 问题四: 下载管理删除/恢复任务时闪退)
        let gid = downloadQueue[nextIndex].gallery.gid
        lastRunID += 1
        let runID = lastRunID
        currentRunID = runID

        runTask = Task {
            await executeDownload(gid: gid, runID: runID)
            // 下载停止后再做整层重新编号时延后的改名 (此时这一轮的页面任务都已退出)
            applyPendingRename(gid: gid)
        }
    }

    /// 停止当前一轮下载：同步取消页面任务，并让这一轮的收尾失效
    private func stopActiveRun() {
        if let gid = activeTask?.gallery.gid {
            if let spider = spider(forGid: gid) {
                Task { await spider.cancelAll() }
            }
            if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
                downloadQueue[index].speed = 0
            }
        }
        runTask?.cancel()
        runTask = nil
        currentRunID = nil
        activeTask = nil
    }

    // MARK: - 后台任务句柄 (iOS: 申请后台执行时间; 其他平台 no-op)

    private func beginBackgroundTask() async -> Int {
        #if canImport(UIKit)
        let identifier = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "EhGalleryDownload") {
                Task { await DownloadManager.shared.pauseActiveIfNeeded() }
            }
        }
        return identifier.rawValue
        #else
        return 0
        #endif
    }

    private func endBackgroundTask(_ token: Int) async {
        #if canImport(UIKit)
        guard token != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
        }
        #endif
    }

    /// 取出某个任务正在使用的 SpiderQueen
    /// ⚠️ 必须从 downloadQueue 取: activeTask 是 processQueue 时的**值拷贝**,
    ///    spider 是之后才写进 downloadQueue 的, activeTask?.spider 永远是 nil ——
    ///    以前 pause/delete 都是对着 nil 调 cancelAll, 暂停/删除根本停不下正在跑的下载
    private func spider(forGid gid: Int64) -> SpiderQueen? {
        downloadQueue.first(where: { $0.gallery.gid == gid })?.spider
    }

    /// 当前一轮收尾 — 仅当编号仍是当前一轮时才清理并继续队列
    /// (防止已被 pause/delete 取代的旧一轮把新一轮的 activeTask 清空、提前启动下一本)
    private func finishRunning(runID: Int) {
        guard currentRunID == runID else { return }
        currentRunID = nil
        runTask = nil
        activeTask = nil
        processQueue()
    }

    private func executeDownload(gid: Int64, runID: Int) async {
        // iOS: 申请后台执行时间, 防止进入后台后 ~30 秒被系统杀死
        let bgToken = await beginBackgroundTask()

        // ★ 每个 await 挂起点之后都必须按 gid 重新定位任务，并确认自己仍是活跃任务
        guard let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }),
              currentRunID == runID else {
            await endBackgroundTask(bgToken)
            finishRunning(runID: runID)
            return
        }

        let gallery = downloadQueue[index].gallery
        let dir = galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)
        directoryIndex.set(gid: gallery.gid, relativePath: relativePath(of: dir))

        // 通知监听器下载开始
        await listener?.onDownloadStart(gid: gallery.gid, title: gallery.bestTitle)

        // 尝试从 .ehviewer 文件读取已有的 SpiderInfo
        var spiderInfo: SpiderInfo
        if let existing = SpiderInfoFile.read(from: dir) {
            spiderInfo = existing
        } else {
            spiderInfo = SpiderInfo(
                startPage: 0,
                gid: gallery.gid,
                token: gallery.token,
                pages: gallery.pages
            )
            // 保存初始 .ehviewer 文件
            try? SpiderInfoFile.write(spiderInfo, to: dir)
        }

        // 创建 SpiderQueen
        let spider = SpiderQueen(galleryInfo: gallery, spiderInfo: spiderInfo, mode: .download, downloadDir: dir)

        // 统计已有的下载页数作为初始值
        let initialPages = SpiderInfoFile.getDownloadedPages(in: dir, totalPages: gallery.pages)

        // onDownloadStart 是 await — 队列可能已在此期间变化，重新定位
        guard let setupIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }),
              currentRunID == runID else {
            await endBackgroundTask(bgToken)
            finishRunning(runID: runID)
            return
        }
        downloadQueue[setupIndex].spider = spider
        downloadQueue[setupIndex].downloadedPages = initialPages.count
        downloadQueue[setupIndex].speed = 0

        // 设置代理以便更新 .ehviewer 文件和进度通知
        let updater = SpiderInfoUpdater(
            gid: gallery.gid,
            title: gallery.bestTitle,
            total: gallery.pages,
            listener: listener,
            downloadedPages: initialPages
        )
        await spider.setDelegate(updater)

        // 开始下载所有页面 (startDownload() 是真正的 async，会等待全部页面完成)
        await spider.startDownload()

        let finalInfo = await spider.getSpiderInfo()

        // ★ 长时间 await 之后任务可能已被删除或暂停 —— 此时不得再写回状态或文件，
        //   否则会数组越界崩溃 (旧索引失效)、把状态写到别的画廊头上，或重建已删除的目录
        guard let finalIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }),
              currentRunID == runID else {
            await endBackgroundTask(bgToken)
            finishRunning(runID: runID)
            return
        }

        // 下载完成后更新 .ehviewer 文件
        try? SpiderInfoFile.write(finalInfo, to: dir)

        // 统计下载结果：按磁盘文件数，阅读器补存的页也算 (对齐 Android DownloadManager.onFinished)
        let progress = diskProgress(dir: dir, pages: gallery.pages)
        let success = progress.complete
        downloadQueue[finalIndex].state = success ? Self.stateFinish : Self.stateFailed
        downloadQueue[finalIndex].downloadedPages = progress.downloaded
        downloadQueue[finalIndex].spider = nil  // 释放 spider 引用
        try? EhDatabase.shared.updateDownloadState(gid: gallery.gid, state: downloadQueue[finalIndex].state)

        // 通知监听器下载完成
        await listener?.onDownloadFinish(gid: gallery.gid, title: gallery.bestTitle, success: success)

        // iOS: 释放后台执行时间
        await endBackgroundTask(bgToken)

        finishRunning(runID: runID)
    }

    // MARK: - 文件管理

    // MARK: - 路径统一 (Fix D-1, A-3: 全局唯一的目录命名算法)

    /// 文件名清理 (移除非法字符) — 公开静态方法，保证所有组件使用同一逻辑
    public nonisolated static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = sanitized.prefix(128)
        return String(trimmed).trimmingCharacters(in: .whitespaces)
    }

    /// 画廊目录名 — 唯一真相源 (所有路径引用必须通过此方法)
    /// 格式: `{gid}-{sanitizeFilename(title).prefix(128)}`
    public nonisolated static func galleryDirectoryName(gid: Int64, title: String) -> String {
        let sanitized = sanitizeFilename(title)
        return "\(gid)-\(sanitized)"
    }

    /// 画廊下载目录：先查路径索引（目录可能带序号、在分组内或被用户改名），
    /// 索引里的目录不存在时再按旧规则 `gid-标题` 拼
    public nonisolated func galleryDirectory(gid: Int64, title: String) -> URL {
        let legacy = downloadDirectory.appendingPathComponent(Self.galleryDirectoryName(gid: gid, title: title))
        guard let relativePath = directoryIndex.relativePath(gid: gid) else { return legacy }
        let indexed = downloadDirectory.appendingPathComponent(relativePath, isDirectory: true)
        if FileManager.default.fileExists(atPath: indexed.path) { return indexed }
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : indexed
    }

    /// 画廊目录相对下载根目录的路径（如 `000100_组/2345678-标题`）
    public nonisolated func relativePath(of directory: URL) -> String {
        let root = downloadDirectory.standardizedFileURL.pathComponents
        let components = directory.standardizedFileURL.pathComponents
        guard components.count > root.count, Array(components.prefix(root.count)) == root else {
            return directory.lastPathComponent
        }
        return components.dropFirst(root.count).joined(separator: "/")
    }

    /// 扫描下载目录（根目录和一层分组），按 .ehviewer 中的 gid 重建路径索引
    /// 同一 gid 出现在多个目录时取扫描到的第一个
    public nonisolated func refreshDirectoryIndex() {
        var paths: [Int64: String] = [:]
        for (dir, info) in SpiderInfoFile.scanOfflineGalleries(in: downloadDirectory) where info.gid > 0 {
            if paths[info.gid] == nil {
                paths[info.gid] = relativePath(of: dir)
            }
        }
        directoryIndex.replaceAll(paths)
    }

    /// 重新扫描下载目录并刷新各任务的已下载页数 (进入下载页时调用，
    /// 用户可能在「文件」App 中移动或改名了画廊目录)
    public func rescanDownloadDirectory() {
        refreshDirectoryIndex()
        // 已完成的不重算：逐页检查文件开销大，且和启动时的处理保持一致
        for i in downloadQueue.indices
        where downloadQueue[i].state != Self.stateDownload && downloadQueue[i].state != Self.stateFinish {
            let gallery = downloadQueue[i].gallery
            let dir = galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)
            downloadQueue[i].downloadedPages = diskProgress(dir: dir, pages: gallery.pages).downloaded
        }
    }

    /// 图片文件名 (对应 Android: String.format("%08d%s", index+1, ext))
    public nonisolated func imageFilename(index: Int, ext: String = ".jpg") -> String {
        String(format: "%08d%@", index + 1, ext)
    }

    // MARK: - 下载状态真实检查 (Fix D-2, B-1)

    /// 检查画廊是否已完整下载 — 验证数据库状态 AND 磁盘上每一页都存在
    /// (仅目录存在不足以判定完成: 下载中断后目录同样存在, 会被误判为"已下载")
    public func isGalleryFullyDownloaded(gid: Int64) -> Bool {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }),
              task.state == Self.stateFinish else { return false }
        let dir = galleryDirectory(gid: gid, title: task.gallery.bestTitle)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        let pages = task.gallery.pages
        guard pages > 0 else { return false }
        return SpiderInfoFile.getDownloadedPages(in: dir, totalPages: pages).count >= pages
    }

    /// 已下载的页数 (磁盘真实文件数, 与下载状态无关)
    public func getDownloadedPageCount(gid: Int64) -> Int {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }),
              task.gallery.pages > 0 else { return 0 }
        let dir = galleryDirectory(gid: gid, title: task.gallery.bestTitle)
        return SpiderInfoFile.getDownloadedPages(in: dir, totalPages: task.gallery.pages).count
    }

    // MARK: - 阅读时同步下载 (对齐 Android 上游 sync_download_while_reading)

    /// 阅读时把看过的图片顺手存进下载目录
    ///
    /// 对应 Android SpiderDen.shouldSyncDownloadWhileReading(): 阅读模式 + 设置开启时，
    /// 写图片的管道从"只写缓存"变成"也写下载目录"。
    /// Apple 端阅读器没走 SpiderDen（自己下图），所以由阅读器下载成功后回调到这里。
    ///
    /// - Returns: 真正写入磁盘了才返回 true (已存在同页 / 磁盘空间不足 → false)
    @discardableResult
    public func saveWhileReading(
        gallery: GalleryInfo, pageIndex: Int, data: Data, extension ext: String
    ) -> Bool {
        guard pageIndex >= 0, !data.isEmpty else { return false }

        let dir = galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)
        // 已经有这一页就不重复写 (可能是之前下载过的)
        if SpiderInfoFile.getLocalImageURL(in: dir, pageIndex: pageIndex) != nil { return false }

        // 磁盘空间兜底 —— 与正式下载同一套判断
        guard SpiderDen.hasSufficientDiskSpace(bytes: Int64(data.count) + 10 * 1024 * 1024) else {
            return false
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 还没开始下载的画廊此时才建目录：没有 .ehviewer 的目录认不出是画廊
            if !SpiderInfoFile.exists(in: dir) {
                let info = SpiderInfo(startPage: 0, gid: gallery.gid, token: gallery.token, pages: gallery.pages)
                try SpiderInfoFile.write(info, to: dir)
            }
            let filename = imageFilename(index: pageIndex, ext: ext)
            try data.write(to: dir.appendingPathComponent(filename), options: .atomic)
        } catch {
            print("[DownloadManager] 阅读时同步下载失败 p\(pageIndex): \(error)")
            return false
        }

        directoryIndex.set(gid: gallery.gid, relativePath: relativePath(of: dir))

        // 首次写入时补一条数据库记录，这样这本画廊会出现在下载列表里
        registerReadingSyncTaskIfNeeded(gallery: gallery, directory: dir)

        // 刷新进度，让下载列表显示"已存 N 页"
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gallery.gid }) {
            let progress = diskProgress(dir: dir, pages: gallery.pages)
            downloadQueue[index].downloadedPages = progress.downloaded

            // 整本都在盘上 → 标记为已完成 (否则列表会一直显示"已暂停"或"失败")
            // 正在下载的那本由下载收尾按同一规则判定，这里不抢着改
            if progress.complete, downloadQueue[index].state != Self.stateFinish,
               activeTask?.gallery.gid != gallery.gid {
                downloadQueue[index].state = Self.stateFinish
                try? EhDatabase.shared.updateDownloadState(gid: gallery.gid, state: Self.stateFinish)
            }
        }
        return true
    }

    /// 下载列表中的画廊，阅读时在线加载的页存入下载目录（画廊信息取自下载任务，不依赖详情页缓存）
    /// - Returns: 不在下载列表中、已有同页或写入失败时返回 false
    @discardableResult
    public func saveWhileReading(
        gid: Int64, pageIndex: Int, data: Data, extension ext: String
    ) -> Bool {
        guard let gallery = downloadQueue.first(where: { $0.gallery.gid == gid })?.gallery else { return false }
        return saveWhileReading(gallery: gallery, pageIndex: pageIndex, data: data, extension: ext)
    }

    /// 同步下载首次落盘时登记任务 (状态设为 stateNone = 已暂停，不会抢占下载队列)
    private func registerReadingSyncTaskIfNeeded(gallery: GalleryInfo, directory: URL) {
        guard !downloadQueue.contains(where: { $0.gallery.gid == gallery.gid }) else { return }

        // ⚠️ stateNone 而不是 stateWait: 这是"顺手存的"，不应该自己启动整本下载
        var task = DownloadTask(gallery: gallery, state: Self.stateNone)
        task.downloadedPages = SpiderInfoFile.getDownloadedPages(
            in: directory, totalPages: max(gallery.pages, 1)
        ).count
        downloadQueue.append(task)

        let record = DownloadRecord(
            gid: gallery.gid, token: gallery.token,
            title: gallery.bestTitle, titleJpn: gallery.titleJpn,
            thumb: gallery.thumb, category: gallery.category.rawValue,
            posted: gallery.posted, uploader: gallery.uploader,
            rating: gallery.rating, simpleLanguage: gallery.simpleLanguage,
            pages: gallery.pages, state: Self.stateNone, date: Date()
        )
        try? EhDatabase.shared.insertDownload(record)
    }

    /// 按磁盘实际文件数判定下载进度 — 下载器和阅读器补存都写同一目录，完成状态只看磁盘
    private nonisolated func diskProgress(dir: URL, pages: Int) -> (downloaded: Int, complete: Bool) {
        guard pages > 0 else { return (0, false) }
        let downloaded = SpiderInfoFile.getDownloadedPages(in: dir, totalPages: pages).count
        return (downloaded, downloaded >= pages)
    }

    /// 获取已下载画廊的目录路径 (由 ReaderViewModel 调用，替代硬编码路径)
    public func getDownloadedGalleryDirectory(gid: Int64) -> URL? {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }) else { return nil }
        return galleryDirectory(gid: gid, title: task.gallery.bestTitle)
    }

    /// 本地画廊目录 — 只要画廊在下载列表中就返回，不要求目录里已有图片
    /// (对齐 Android SpiderDen: 逐页判断本地是否存在，而不是整本"全有或全无")
    /// 刚加入下载、一张图都还没有时打开阅读，之后下载器写好的页也能读本地；缺失的页由调用方回退网络
    public func localGalleryDirectory(gid: Int64) -> URL? {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }) else { return nil }
        return galleryDirectory(gid: gid, title: task.gallery.bestTitle)
    }

    // MARK: - 分组与排序
    //
    // 分组 = 根目录下没有 .ehviewer 的子目录，只有一层；顺序写在目录名的序号前缀里
    // (见 DownloadDirectoryName)。同一层的分组和画廊共用一套序号，有序号的在前。

    /// 当前目录布局：根目录下的分组，以及下载列表中每本画廊所在分组和序号
    /// 延后改名的画廊按改名后的位置返回，列表顺序立即正确
    public func directoryLayout() -> DownloadLayout {
        let groups = SpiderInfoFile.subdirectories(of: downloadDirectory)
            .filter { SpiderInfoFile.isGroupDirectory($0) }
            .map { dir in
                DownloadGroup(
                    dirname: dir.lastPathComponent,
                    createdAt: try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate
                )
            }
        var placements: [Int64: GalleryPlacement] = [:]
        for task in downloadQueue {
            let gid = task.gallery.gid
            placements[gid] = GalleryPlacement(relativePath: pendingRenames[gid] ?? directoryIndex.relativePath(gid: gid))
        }
        return DownloadLayout(groups: groups, placements: placements)
    }

    /// 新建分组：不带序号，和新下载的画廊一样作为未排序项显示在最上面
    /// - Returns: 新分组的目录名
    @discardableResult
    public func createGroup(name: String) throws -> String {
        let groupName = try Self.sanitizeGroupName(name)
        try ensureGroupNameAvailable(groupName, excluding: nil)
        let dirname = groupName
        try FileManager.default.createDirectory(
            at: downloadDirectory.appendingPathComponent(dirname, isDirectory: true),
            withIntermediateDirectories: false
        )
        return dirname
    }

    /// 重命名分组，保留序号
    public func renameGroup(dirname: String, to newName: String) async throws {
        let groupName = try Self.sanitizeGroupName(newName)
        try ensureGroupNameAvailable(groupName, excluding: dirname)
        let newDirname = DownloadDirectoryName.withOrder(DownloadDirectoryName.parseOrder(dirname).order, name: groupName)
        guard newDirname != dirname else { return }
        let resumeGid = await suspendActiveDownload(ifIn: gids(inGroup: dirname))
        defer { resumeAfterMove(resumeGid) }
        try moveGroupDirectory(from: dirname, to: newDirname)
    }

    /// 解散分组：其中的画廊移回根目录（去掉序号，变为未排序），空目录删除
    public func dissolveGroup(dirname: String) async throws {
        let groupDir = downloadDirectory.appendingPathComponent(dirname, isDirectory: true)
        guard FileManager.default.fileExists(atPath: groupDir.path) else { throw DownloadGroupError.groupNotFound }
        let resumeGid = await suspendActiveDownload(ifIn: gids(inGroup: dirname))
        defer { resumeAfterMove(resumeGid) }

        var movedCount = 0
        for child in SpiderInfoFile.subdirectories(of: groupDir) {
            guard let info = SpiderInfoFile.readHeader(from: child) else { continue }
            let target = downloadDirectory.appendingPathComponent(
                DownloadDirectoryName.parseOrder(child.lastPathComponent).rest, isDirectory: true
            )
            try moveDirectory(from: child, to: target)
            if info.gid > 0 {
                directoryIndex.set(gid: info.gid, relativePath: relativePath(of: target))
            }
            movedCount += 1
        }

        // 只剩系统隐藏文件时删除分组目录；用户放进去的其他文件保留
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: groupDir.path)) ?? []
        if remaining.allSatisfy({ $0.hasPrefix(".") }) {
            try? FileManager.default.removeItem(at: groupDir)
        } else if movedCount == 0 {
            throw DownloadGroupError.onlyOtherFiles
        }
    }

    /// 把画廊移到某个分组 (nil = 根目录)，排在目标层已排序项的末尾；目标层没有序号时保持未排序
    /// 正在下载的画廊先暂停，移动完成后恢复 (否则旧一轮会把页面写回旧目录)
    public func moveGalleries(_ gids: [Int64], toGroup group: String?) async throws {
        let parent: URL
        if let group {
            parent = downloadDirectory.appendingPathComponent(group, isDirectory: true)
            guard FileManager.default.fileExists(atPath: parent.path) else { throw DownloadGroupError.groupNotFound }
        } else {
            parent = downloadDirectory
        }

        let resumeGid = await suspendActiveDownload(ifIn: Set(gids))
        defer { resumeAfterMove(resumeGid) }

        let layout = directoryLayout()
        var order = nextOrder(inGroup: group)
        for gid in gids {
            guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }),
                  layout.placement(of: gid).group != group else { continue }
            let current = ensureGalleryDirectory(task)
            let name = DownloadDirectoryName.withOrder(order, name: current.lastPathComponent)
            let target = parent.appendingPathComponent(name, isDirectory: true)
            try moveDirectory(from: current, to: target)
            directoryIndex.set(gid: gid, relativePath: relativePath(of: target))
            pendingRenames[gid] = nil
            order = order.map { $0 + Self.orderStep }
        }
    }

    /// 手动排序：`items` 是拖动后该层的完整顺序，`moved` 是被拖动的项
    ///
    /// 该层有项还没有序号时整层按 100、200、300 重新编号；否则只给被拖动的项取相邻两项的中间值，
    /// 没有空位时整层重新编号。正在下载的画廊延后到下载停止后再改名。
    public func reorder(inGroup group: String?, items: [DownloadLevelItem], moved: DownloadLevelItem) async throws {
        guard let position = items.firstIndex(of: moved) else { return }
        let layout = directoryLayout()
        let currentOrders = items.map { order(of: $0, in: layout) }

        var targets: [DownloadLevelItem: Int] = [:]
        let previous = position > 0 ? currentOrders[position - 1] : 0
        let next = position + 1 < items.count ? currentOrders[position + 1] : previous.map { $0 + 2 * Self.orderStep }
        if !currentOrders.contains(where: { $0 == nil }),
           let previous, let next, next - previous >= 2, next <= Self.maxOrder {
            targets[moved] = (previous + next) / 2
        } else {
            let step = min(Self.orderStep, max(1, Self.maxOrder / (items.count + 1)))
            for (index, item) in items.enumerated() {
                targets[item] = (index + 1) * step
            }
        }

        // 要改名的分组里如果有正在下载的画廊，先暂停 (分组目录一改名，它的路径就变了)
        var affectedGids = Set<Int64>()
        for (item, order) in targets where order != self.order(of: item, in: layout) {
            if case .group(let dirname) = item {
                affectedGids.formUnion(gids(inGroup: dirname))
            }
        }
        let resumeGid = await suspendActiveDownload(ifIn: affectedGids)
        defer { resumeAfterMove(resumeGid) }

        for (item, order) in targets where order != self.order(of: item, in: layout) {
            switch item {
            case .group(let dirname):
                try moveGroupDirectory(from: dirname, to: DownloadDirectoryName.withOrder(order, name: dirname))
            case .gallery(let gid):
                try renameGallery(gid: gid, order: order)
            }
        }
    }

    // MARK: 分组与排序的内部实现

    /// 序号间隔
    private static let orderStep = 100
    /// 序号上限 (6 位数字)
    private static let maxOrder = 999_999

    private func order(of item: DownloadLevelItem, in layout: DownloadLayout) -> Int? {
        switch item {
        case .group(let dirname): return DownloadDirectoryName.parseOrder(dirname).order
        case .gallery(let gid): return layout.placement(of: gid).order
        }
    }

    /// 某一层已排序项末尾的下一个序号；该层没有任何序号时返回 nil
    private func nextOrder(inGroup group: String?) -> Int? {
        let layout = directoryLayout()
        var orders = downloadQueue.compactMap { task -> Int? in
            let placement = layout.placement(of: task.gallery.gid)
            return placement.group == group ? placement.order : nil
        }
        if group == nil {
            orders += layout.groups.compactMap(\.order)
        }
        guard let maxOrder = orders.max(), maxOrder + Self.orderStep <= Self.maxOrder else { return nil }
        return maxOrder + Self.orderStep
    }

    /// 改画廊目录名的序号；正在下载的画廊记为延后改名，下载停止后由 applyPendingRename 执行
    private func renameGallery(gid: Int64, order: Int) throws {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }) else { return }
        if activeTask?.gallery.gid == gid {
            let currentPath = pendingRenames[gid]
                ?? directoryIndex.relativePath(gid: gid)
                ?? relativePath(of: galleryDirectory(gid: gid, title: task.gallery.bestTitle))
            var components = currentPath.split(separator: "/").map(String.init)
            guard let last = components.popLast() else { return }
            components.append(DownloadDirectoryName.withOrder(order, name: last))
            pendingRenames[gid] = components.joined(separator: "/")
            return
        }
        let current = ensureGalleryDirectory(task)
        let target = current.deletingLastPathComponent()
            .appendingPathComponent(DownloadDirectoryName.withOrder(order, name: current.lastPathComponent), isDirectory: true)
        try moveDirectory(from: current, to: target)
        directoryIndex.set(gid: gid, relativePath: relativePath(of: target))
    }

    /// 执行延后的改名 (下载停止后调用)；同一本又开始下载时继续延后
    private func applyPendingRename(gid: Int64) {
        guard activeTask?.gallery.gid != gid,
              let target = pendingRenames.removeValue(forKey: gid),
              let task = downloadQueue.first(where: { $0.gallery.gid == gid }) else { return }
        let current = galleryDirectory(gid: gid, title: task.gallery.bestTitle)
        let targetURL = downloadDirectory.appendingPathComponent(target, isDirectory: true)
        // 目标被占用时保持原名，不影响阅读和下载
        if (try? moveDirectory(from: current, to: targetURL)) != nil {
            directoryIndex.set(gid: gid, relativePath: target)
        }
    }

    /// 移动分组目录并更新其中画廊的路径索引
    private func moveGroupDirectory(from old: String, to new: String) throws {
        guard old != new else { return }
        try moveDirectory(
            from: downloadDirectory.appendingPathComponent(old, isDirectory: true),
            to: downloadDirectory.appendingPathComponent(new, isDirectory: true)
        )
        let oldPrefix = old + "/"
        for (gid, path) in directoryIndex.allPaths() where path.hasPrefix(oldPrefix) {
            directoryIndex.set(gid: gid, relativePath: new + "/" + path.dropFirst(oldPrefix.count))
        }
        for (gid, path) in pendingRenames where path.hasPrefix(oldPrefix) {
            pendingRenames[gid] = new + "/" + path.dropFirst(oldPrefix.count)
        }
    }

    /// 同一文件系统内改名移动，不复制文件；目标已存在时报错，不覆盖
    private nonisolated func moveDirectory(from source: URL, to target: URL) throws {
        guard source.standardizedFileURL.path != target.standardizedFileURL.path else { return }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw DownloadGroupError.targetExists(target.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: target)
    }

    /// 还没开始下载的画廊没有目录，移动或排序前先建好目录和 .ehviewer
    private func ensureGalleryDirectory(_ task: DownloadTask) -> URL {
        let gallery = task.gallery
        let dir = galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)
        if !SpiderInfoFile.exists(in: dir) {
            let info = SpiderInfo(startPage: 0, gid: gallery.gid, token: gallery.token, pages: gallery.pages)
            try? SpiderInfoFile.write(info, to: dir)
        }
        directoryIndex.set(gid: gallery.gid, relativePath: relativePath(of: dir))
        return dir
    }

    /// 某个分组内的画廊 gid (按路径索引和延后改名)
    private func gids(inGroup dirname: String) -> Set<Int64> {
        let prefix = dirname + "/"
        var result = Set(directoryIndex.allPaths().filter { $0.value.hasPrefix(prefix) }.keys)
        result.formUnion(pendingRenames.filter { $0.value.hasPrefix(prefix) }.keys)
        return result
    }

    /// 暂停正在下载且受影响的画廊，并等这一轮的页面任务全部退出 (移动目录前必须停干净)
    /// - Returns: 被暂停的 gid，移动完成后交给 resumeAfterMove 恢复
    private func suspendActiveDownload(ifIn gids: Set<Int64>) async -> Int64? {
        guard let gid = activeTask?.gallery.gid, gids.contains(gid) else { return nil }
        let run = runTask
        stopActiveRun()
        // 移动期间置为暂停，避免被队列重新启动后又写回旧目录
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].state = Self.stateNone
            downloadQueue[index].spider = nil
        }
        await run?.value
        return gid
    }

    private func resumeAfterMove(_ gid: Int64?) {
        guard let gid else { return }
        resumeDownload(gid: gid)
    }

    /// 组名：非法字符替换为 `_`；不能为空，也不能以 `.` 开头 (会成为隐藏目录)
    private nonisolated static func sanitizeGroupName(_ name: String) throws -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.hasPrefix(".") else { throw DownloadGroupError.invalidName }
        return cleaned
    }

    private func ensureGroupNameAvailable(_ name: String, excluding dirname: String?) throws {
        let exists = directoryLayout().groups.contains { $0.dirname != dirname && $0.name == name }
        if exists { throw DownloadGroupError.nameExists }
    }
}

// MARK: - DownloadTask

public struct DownloadTask: Sendable {
    public let gallery: GalleryInfo
    public var state: Int
    public var downloadedPages: Int
    /// 下载速度 (字节/秒)
    public var speed: Int64
    public var spider: SpiderQueen?
    /// 加入下载的时间 (未排序的项按它倒序显示)
    public let date: Date

    public init(gallery: GalleryInfo, state: Int = DownloadManager.stateWait, date: Date = Date()) {
        self.gallery = gallery
        self.state = state
        self.downloadedPages = 0
        self.speed = 0
        self.date = date
    }
}

// MARK: - SpiderInfo 扩展 (简化构造)

extension SpiderInfo {
    init(startPage: Int, gid: Int64, token: String, pages: Int) {
        self.init()
        self.startPage = startPage
        self.gid = gid
        self.token = token
        self.pages = pages
    }
}

// MARK: - SpiderInfoUpdater (用于下载时更新 .ehviewer 文件)

actor SpiderInfoUpdater: SpiderDelegate {
    private let gid: Int64
    private let title: String
    private let totalPages: Int
    private weak var listener: DownloadListener?

    /// 已在磁盘上的页：重新开始下载时这些页会再回调一次，不能重复计数
    private var loadedPages: Set<Int>
    /// 最近完成页的 (完成时间, 网络字节数)，只保留速度窗口内的
    private var recentDownloads: [(time: Date, bytes: Int64)] = []
    /// 速度按最近这么长时间内下载的字节计算，排队、冷却等停顿会很快反映出来
    private let speedWindow: TimeInterval = 5
    private let startTime = Date()
    private var lastNotifyTime: Date = .distantPast
    private let notifyInterval: TimeInterval = 1.0 // 每秒最多通知一次

    init(gid: Int64, title: String, total: Int, listener: DownloadListener?, downloadedPages: Set<Int> = []) {
        self.gid = gid
        self.title = title
        self.totalPages = total
        self.listener = listener
        self.loadedPages = downloadedPages
    }

    func onPageLoaded(index: Int, imageUrl: String, networkBytes: Int64) async {
        guard loadedPages.insert(index).inserted else { return }

        // 同步更新 DownloadManager 队列中的进度 (便于 UI 读取)
        await DownloadManager.shared.updateDownloadedPages(gid: gid, count: loadedPages.count)

        let now = Date()
        if networkBytes > 0 {
            recentDownloads.append((now, networkBytes))
        }
        recentDownloads.removeAll { now.timeIntervalSince($0.time) > speedWindow }
        // 刚开始时窗口还没满，按实际经过时间算，至少按 1 秒算以免首页数值虚高
        let span = max(1, min(speedWindow, now.timeIntervalSince(startTime)))
        let speed = Int64(Double(recentDownloads.reduce(0) { $0 + $1.bytes }) / span)

        // 同步速度到 DownloadManager 队列 (便于 UI 读取)
        await DownloadManager.shared.updateDownloadSpeed(gid: gid, speed: speed)

        // 节流通知
        if now.timeIntervalSince(lastNotifyTime) >= notifyInterval {
            lastNotifyTime = now
            await listener?.onDownloadProgress(
                gid: gid,
                title: title,
                downloaded: loadedPages.count,
                total: totalPages,
                speed: speed
            )
        }
    }

    func onPageFailed(index: Int, error: Error) async {
        print("[SpiderInfoUpdater] Page \(index) failed: \(error)")
    }

    func onImageLimitReached() async {
        print("[SpiderInfoUpdater] Image limit (509) reached")
        await listener?.on509Error()
    }

    func onDiskFull() async {
        print("[SpiderInfoUpdater] ⚠️ 磁盘空间不足，暂停所有下载")
        await DownloadManager.shared.pauseAllDownloads()
        await listener?.onDiskFull()
    }

    func onDownloadProgress(downloaded: Int, total: Int) async {}
}

// MARK: - DownloadListener (下载事件监听器)

public protocol DownloadListener: AnyObject, Sendable {
    /// 下载开始
    func onDownloadStart(gid: Int64, title: String) async

    /// 下载进度更新
    func onDownloadProgress(gid: Int64, title: String, downloaded: Int, total: Int, speed: Int64) async

    /// 下载完成
    func onDownloadFinish(gid: Int64, title: String, success: Bool) async

    /// 509错误
    func on509Error() async

    /// 磁盘空间不足
    func onDiskFull() async
}
