//
//  DownloadsView.swift
//  ehviewer apple
//
//  下载管理视图 (对齐 Android DownloadsScene: 搜索、批量操作、状态过滤)
//  分组与排序基于下载目录结构：根目录下没有 .ehviewer 的子目录是分组，序号写在目录名前缀
//

import SwiftUI
import EhModels
import EhDownload
import EhDatabase
import EhSpider
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - 状态过滤枚举

enum DownloadStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case queue = "队列中"
    case paused = "已暂停"
    case finished = "已完成"
    case failed = "失败"

    var id: String { rawValue }
}

/// 下载页的显示方式
enum DownloadsLayoutMode: String, CaseIterable {
    case list
    case grid
    /// 不显示封面和标题，只看进度
    case privacy

    var title: String {
        switch self {
        case .list: return "列表"
        case .grid: return "网格"
        case .privacy: return "隐私"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        case .privacy: return "eye.slash"
        }
    }
}

struct DownloadsView: View {
    @State private var vm = DownloadsViewModel()

    // MARK: - 搜索/过滤
    @State private var searchText = ""
    @State private var statusFilter: DownloadStatusFilter = .all

    // MARK: - 显示方式
    @AppStorage("downloadsLayoutMode") private var layoutMode: DownloadsLayoutMode = .list
    /// 网格中拖动时当前悬停的格子 (条目 id)
    @State private var gridDropTarget: GridDropTarget?
    /// 隐私视图顶部显示的本机上下行网速
    @State private var deviceNetworkSpeed = DeviceNetworkSpeedMonitor()

    // MARK: - 导航 (进入分组、点封面打开详情页)
    @State private var navigationPath: [DownloadsRoute] = []

    // MARK: - 批量操作
    @State private var isSelectMode = false
    @State private var selectedGids: Set<Int64> = []
    @State private var showBatchDeleteConfirm = false

    // MARK: - 单项删除确认 (Fix: 从 Row 移至父视图，避免 Timer 刷新销毁 @State)
    @State private var deletingTaskGid: Int64? = nil
    @State private var showSingleDeleteConfirm = false
    // 分享 (issue #2)
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportedZip: ExportedArchive?

    // MARK: - 分组管理
    /// 等待移动到分组的画廊
    @State private var movingGids: [Int64] = []
    @State private var showMoveToGroupSheet = false
    @State private var showNewGroupAlert = false
    @State private var newGroupName = ""
    /// 新建分组后是否把 movingGids 移进去
    @State private var newGroupTakesMovingGids = false
    @State private var renamingGroup: DownloadGroup?
    @State private var groupRenameText = ""
    @State private var dissolvingGroup: DownloadGroup?

    // MARK: - 阅读器 (fullScreenCover 呈现，隐藏导航栏)
    @State private var readerGallery: GalleryInfo?
    /// 详情页点标签后弹出的标签搜索页：下载页导航栈只放 DownloadsRoute，推不进搜索页
    @State private var tagSearch: TagSearchDestination?

    // MARK: - 存储信息
    @State private var gallerySizes: [Int64: Int64] = [:]  // gid -> bytes
    @State private var totalStorageSize: Int64 = 0
    @State private var isCalculatingSize = false
    @State private var readingProgress: [Int64: Int] = [:]  // gid -> page index

    var body: some View {
        NavigationStack(path: $navigationPath) {
            levelView(group: nil)
                .navigationDestination(for: DownloadsRoute.self) { route in
                    switch route {
                    case .group(let dirname):
                        levelView(group: dirname)
                    case .gallery(let gallery):
                        GalleryDetailView(gallery: gallery)
                            .environment(\.tagNavigationAction, TagNavigationAction { tag in
                                tagSearch = TagSearchDestination(tag: tag)
                            })
                    }
                }
        }
        // 标签搜索：自带导航栈，在里面可以继续打开画廊、点标签
        .sheet(item: $tagSearch) { destination in
            NavigationStack {
                GalleryListView(mode: .tag(keyword: destination.tag), isPushed: true)
                    .navigationDestination(for: GalleryInfo.self) { gallery in
                        GalleryDetailView(gallery: gallery)
                            .id(gallery.gid)
                    }
                    .navigationDestination(for: TagSearchDestination.self) { dest in
                        GalleryListView(mode: .tag(keyword: dest.tag), isPushed: true)
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { tagSearch = nil }
                        }
                    }
            }
            // 弹出页里点标签推入自己的导航栈，不沿用外层的跳转方式
            .environment(\.tagNavigationAction, nil)
            #if os(macOS)
            .frame(minWidth: 600, minHeight: 500)
            #endif
        }
        // 移动到分组 Sheet
        .sheet(isPresented: $showMoveToGroupSheet) {
            moveToGroupSheet
        }
        // 新建分组
        .alert("新建分组", isPresented: $showNewGroupAlert) {
            TextField("分组名称", text: $newGroupName)
            Button("取消", role: .cancel) {
                newGroupName = ""
                newGroupTakesMovingGids = false
            }
            Button("创建") {
                createGroup(newGroupName)
                newGroupName = ""
            }
        }
        // 重命名分组
        .alert("重命名分组", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("新名称", text: $groupRenameText)
            Button("取消", role: .cancel) { renamingGroup = nil }
            Button("确定") {
                if let group = renamingGroup {
                    Task { await vm.renameGroup(group, to: groupRenameText) }
                }
                renamingGroup = nil
            }
        }
        // 解散分组确认
        .confirmationDialog(
            "解散分组「\(dissolvingGroup?.name ?? "")」？\n其中的画廊会移回下载列表顶层，文件不会删除。",
            isPresented: Binding(
                get: { dissolvingGroup != nil },
                set: { if !$0 { dissolvingGroup = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("解散", role: .destructive) {
                if let group = dissolvingGroup {
                    navigationPath.removeAll { $0 == .group(group.dirname) }
                    Task { await vm.dissolveGroup(group) }
                }
                dissolvingGroup = nil
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { vm.operationError != nil },
            set: { if !$0 { vm.operationError = nil } }
        )) {
            Button("好") { vm.operationError = nil }
        } message: {
            Text(vm.operationError ?? "")
        }
        .overlay {
            if isExporting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在打包…").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("分享失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .sheet(item: $exportedZip) { archive in
            #if os(iOS)
            ShareSheet(items: [archive.url])
            #else
            // macOS: 直接在 Finder 里定位打包好的 zip
            Color.clear.onAppear {
                NSWorkspace.shared.activateFileViewerSelecting([archive.url])
                exportedZip = nil
            }
            #endif
        }
        #if os(iOS)
        .fullScreenCover(item: $readerGallery) { gallery in
            ImageReaderView(gid: gallery.gid, token: gallery.token, pages: gallery.pages)
                .id(gallery.gid)
        }
        #else
        .sheet(item: $readerGallery) { gallery in
            ImageReaderView(gid: gallery.gid, token: gallery.token, pages: gallery.pages)
                .id(gallery.gid)
                .frame(minWidth: 800, minHeight: 600)
        }
        #endif
        .onChange(of: layoutMode) { _, mode in
            // 隐私视图只在根目录显示，退出分组和批量选择
            if mode == .privacy {
                navigationPath.removeAll()
                exitSelectMode()
            }
        }
        .task {
            // 用户可能在「文件」App 中移动或改名了画廊目录，先按 .ehviewer 重新定位
            await DownloadManager.shared.rescanDownloadDirectory()
            await vm.loadTasks()
            await loadReadingProgress()
            await calculateStorageSizes()
        }
    }

    // MARK: - 一层列表 (根目录或某个分组，两者共用)

    private func levelView(group: String?) -> some View {
        let isRoot = group == nil
        let entries = listEntries(inGroup: group)
        return VStack(spacing: 0) {
            // 存储空间概览
            if isRoot && !vm.tasks.isEmpty {
                storageOverview
            }

            // 账号级错误让队列整体暂停时的提示
            if isRoot, let reason = vm.haltReason {
                Label("下载已暂停：\(reason)", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }

            // 内容
            if isRoot && layoutMode == .privacy {
                privacyView
            } else if entries.isEmpty {
                ContentUnavailableView(
                    emptyTitle(isRoot: isRoot),
                    systemImage: isRoot ? "arrow.down.circle" : "folder",
                    description: Text(emptyDescription(isRoot: isRoot))
                )
                .frame(maxHeight: .infinity)
            } else if layoutMode == .grid {
                downloadGrid(entries: entries, group: group)
            } else {
                downloadList(entries: entries, group: group)
            }

            // 批量操作底栏
            if isSelectMode {
                batchActionBar
            }
        }
        .navigationTitle(group.map { DownloadGroup(dirname: $0).name } ?? "下载")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .modifier(RootSearchModifier(enabled: isRoot && layoutMode != .privacy, text: $searchText))
        .toolbar {
            #if os(iOS)
            // 列表在编辑模式下拖动排序 (搜索、筛选、批量选择时不提供；网格直接拖动格子)
            if canReorder && layoutMode == .list {
                ToolbarItem(placement: .automatic) {
                    EditButton()
                }
            }
            #endif
            if !isSelectMode {
                ToolbarItem(placement: .automatic) {
                    layoutModeMenu
                }
            }
            ToolbarItem(placement: .automatic) {
                mainToolbarMenu(group: group)
            }
        }
        // 批量删除确认
        .confirmationDialog("确认删除 \(selectedGids.count) 个下载？", isPresented: presented($showBatchDeleteConfirm, onLevel: group), titleVisibility: .visible) {
            Button("仅删除记录", role: .destructive) {
                batchDelete(withFiles: false)
            }
            Button("删除记录和文件", role: .destructive) {
                batchDelete(withFiles: true)
            }
        }
        // 单项删除确认 (Fix: 放在父视图，不受 Timer 刷新影响)
        .confirmationDialog("确认删除下载？", isPresented: presented($showSingleDeleteConfirm, onLevel: group), titleVisibility: .visible) {
            Button("仅删除记录", role: .destructive) {
                if let gid = deletingTaskGid {
                    vm.deleteTask(gid: gid, withFiles: false)
                    // 移除缓存的大小
                    gallerySizes.removeValue(forKey: gid)
                    recalcTotalSize()
                }
                deletingTaskGid = nil
            }
            Button("删除记录和文件", role: .destructive) {
                if let gid = deletingTaskGid {
                    vm.deleteTask(gid: gid, withFiles: true)
                    gallerySizes.removeValue(forKey: gid)
                    recalcTotalSize()
                }
                deletingTaskGid = nil
            }
        }
    }

    /// 删除确认框挂在当前显示的这一层上：挂在 NavigationStack 外面时，
    /// iOS 会把它放到屏幕底部中间，与旧版位置不一致
    private func presented(_ flag: Binding<Bool>, onLevel group: String?) -> Binding<Bool> {
        Binding(
            get: { flag.wrappedValue && isVisibleLevel(group) },
            set: { flag.wrappedValue = $0 }
        )
    }

    private func isVisibleLevel(_ group: String?) -> Bool {
        switch navigationPath.last {
        case nil: return group == nil
        case .group(let dirname): return dirname == group
        case .gallery: return false
        }
    }

    /// 搜索或按状态筛选时平铺显示所有画廊，不能拖动排序
    private var isFiltering: Bool {
        !searchText.isEmpty || statusFilter != .all
    }

    private var canReorder: Bool {
        !isFiltering && !isSelectMode
    }

    // MARK: - 存储空间概览

    private var storageOverview: some View {
        HStack(spacing: 12) {
            // 总存储
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isCalculatingSize {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Text("总计 \(Self.formatFileSize(totalStorageSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // 下载数统计
            let activeCount = vm.tasks.filter { $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait }.count
            let finishedCount = vm.tasks.filter { $0.state == DownloadManager.stateFinish }.count
            if activeCount > 0 {
                Text("\(activeCount) 进行中")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            Text("\(finishedCount)/\(vm.tasks.count) 已完成")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 刷新按钮
            Button {
                Task { await calculateStorageSizes() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - 批量操作底栏

    private var batchActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                // 全选/取消全选
                Button {
                    let allGids = Set(selectableTasks.map { $0.gallery.gid })
                    if selectedGids == allGids {
                        selectedGids.removeAll()
                    } else {
                        selectedGids = allGids
                    }
                } label: {
                    let allGids = Set(selectableTasks.map { $0.gallery.gid })
                    VStack(spacing: 2) {
                        Image(systemName: selectedGids == allGids ? "checkmark.circle" : "checkmark.circle.fill")
                            .font(.title3)
                        Text(selectedGids == allGids ? "取消全选" : "全选")
                            .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)

                // 开始
                Button {
                    batchResume()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "play.fill")
                            .font(.title3)
                        Text("开始")
                            .font(.caption2)
                    }
                }
                .disabled(selectedGids.isEmpty)
                .frame(maxWidth: .infinity)

                // 暂停
                Button {
                    batchPause()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "pause.fill")
                            .font(.title3)
                        Text("暂停")
                            .font(.caption2)
                    }
                }
                .disabled(selectedGids.isEmpty)
                .frame(maxWidth: .infinity)

                // 移动到分组
                Button {
                    requestMoveToGroup(Array(selectedGids))
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "folder")
                            .font(.title3)
                        Text("移入分组")
                            .font(.caption2)
                    }
                }
                .disabled(selectedGids.isEmpty)
                .frame(maxWidth: .infinity)

                // 删除
                Button {
                    showBatchDeleteConfirm = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "trash")
                            .font(.title3)
                        Text("删除")
                            .font(.caption2)
                    }
                    .foregroundColor(selectedGids.isEmpty ? .secondary : .red)
                }
                .disabled(selectedGids.isEmpty)
                .frame(maxWidth: .infinity)

                // 退出选择
                Button {
                    exitSelectMode()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "xmark.circle")
                            .font(.title3)
                        Text("退出")
                            .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(.bar)

            // 已选计数
            if !selectedGids.isEmpty {
                Text("已选择 \(selectedGids.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: - 存储计算

    private func calculateStorageSizes() async {
        isCalculatingSize = true
        let tasks = vm.tasks
        let downloadDir = DownloadManager.shared.downloadDirectory
        let result: ([Int64: Int64], Int64) = await Task.detached {
            var sizes: [Int64: Int64] = [:]
            for task in tasks {
                let dir = DownloadManager.shared.galleryDirectory(gid: task.gallery.gid, title: task.gallery.bestTitle)
                sizes[task.gallery.gid] = StorageUtils.directorySize(at: dir)
            }
            // 总空间直接从下载根目录计算，确保包含所有文件（含孤立目录和元数据）
            let total = StorageUtils.directorySize(at: downloadDir)
            return (sizes, total)
        }.value
        gallerySizes = result.0
        totalStorageSize = result.1
        isCalculatingSize = false
    }

    private func recalcTotalSize() {
        totalStorageSize = gallerySizes.values.reduce(0, +)
    }

    /// 递归计算目录大小
    static func directorySize(at url: URL) -> Int64 {
        StorageUtils.directorySize(at: url)
    }

    /// 格式化文件大小
    static func formatFileSize(_ bytes: Int64) -> String {
        StorageUtils.formatFileSize(bytes)
    }

    // MARK: - 阅读进度

    private func loadReadingProgress() async {
        let tasks = vm.tasks
        let progress: [Int64: Int] = await Task.detached {
            var result: [Int64: Int] = [:]
            for task in tasks {
                let key = "reading_progress_\(task.gallery.gid)"
                if let page = UserDefaults.standard.object(forKey: key) as? Int {
                    result[task.gallery.gid] = page
                }
            }
            return result
        }.value
        readingProgress = progress
    }

    // MARK: - 过滤后的任务列表

    /// 打包并唤起系统分享 (issue #2)
    private func shareGallery(_ gallery: GalleryInfo) async {
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try await GalleryArchiveExporter.exportZip(for: gallery)
            exportedZip = ExportedArchive(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// 按状态和搜索词过滤后的全部画廊 (不分层)
    private var filteredTasks: [DownloadTask] {
        var tasks = vm.tasks

        // 状态过滤
        switch statusFilter {
        case .all: break
        case .queue:
            // 正在下载的排第一，等待中的按 DownloadManager 取下一本的顺序
            tasks = tasks.filter { $0.state == DownloadManager.stateDownload }
                + tasks.filter { $0.state == DownloadManager.stateWait }
        case .paused:
            tasks = tasks.filter { $0.state == DownloadManager.stateNone }
        case .finished:
            tasks = tasks.filter { $0.state == DownloadManager.stateFinish }
        case .failed:
            tasks = tasks.filter { $0.state == DownloadManager.stateFailed }
        }

        // 搜索过滤 —— 标题 + 标签，多个词按 AND
        // (对齐上游 2026-04-20「修复了已下载项目的按标签搜索功能」:
        //  以空格拆词，每个词都要命中，标签支持 `female:xxx` 这种带命名空间的写法)
        let terms = searchText
            .split(whereSeparator: { $0 == " " || $0 == "\u{3000}" })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }

        if !terms.isEmpty {
            tasks = tasks.filter { task in
                let title = task.gallery.bestTitle.lowercased()
                let tags = EhDatabase.shared.searchableTags(gid: task.gallery.gid)
                    .map { $0.lowercased() }
                return terms.allSatisfy { term in
                    title.contains(term) || tags.contains { $0.contains(term) }
                }
            }
        }

        return tasks
    }

    /// 某一层显示的项：文件夹与画廊混排
    /// 无序号的在前、按下载时间倒序，有序号的在后、按序号升序；筛选时平铺显示所有层的画廊
    /// (拖动排序会给整层编号，之后只有新下载的画廊没有序号，要显示在最上面)
    private func listEntries(inGroup group: String?) -> [DownloadListEntry] {
        if isFiltering {
            let tasks = group == nil
                ? filteredTasks
                : filteredTasks.filter { vm.layout.placement(of: $0.gallery.gid).group == group }
            return tasks.map { .gallery($0) }
        }

        var entries: [(entry: DownloadListEntry, order: Int?, name: String, date: Date)] = []
        if group == nil {
            for downloadGroup in vm.layout.groups {
                let groupTasks = tasks(inGroup: downloadGroup.dirname)
                // 组内最新画廊的加入时间；空分组 (如刚新建的) 用目录创建时间
                let latest = max(groupTasks.map(\.date).max() ?? .distantPast, downloadGroup.createdAt ?? .distantPast)
                entries.append((DownloadListEntry.group(downloadGroup, groupTasks), downloadGroup.order, downloadGroup.name, latest))
            }
        }
        for task in vm.tasks {
            let placement = vm.layout.placement(of: task.gallery.gid)
            guard placement.group == group else { continue }
            entries.append((DownloadListEntry.gallery(task), placement.order, task.gallery.bestTitle, task.date))
        }

        return entries.sorted { a, b in
            switch (a.order, b.order) {
            case let (x?, y?):
                return x != y ? x < y : a.name < b.name
            case (.some, nil):
                return false
            case (nil, .some):
                return true
            case (nil, nil):
                return a.date > b.date
            }
        }.map(\.entry)
    }

    /// 分组内的画廊，按分组内的显示顺序
    private func tasks(inGroup dirname: String) -> [DownloadTask] {
        vm.tasks
            .filter { vm.layout.placement(of: $0.gallery.gid).group == dirname }
            .sorted { a, b in
                let x = vm.layout.placement(of: a.gallery.gid).order
                let y = vm.layout.placement(of: b.gallery.gid).order
                switch (x, y) {
                case let (x?, y?): return x < y
                case (.some, nil): return false
                case (nil, .some): return true
                case (nil, nil): return a.date > b.date
                }
            }
    }

    /// 批量选择的范围：当前层（或筛选结果）中的画廊
    private var selectableTasks: [DownloadTask] {
        listEntries(inGroup: currentGroup).compactMap { entry in
            if case .gallery(let task) = entry { return task }
            return nil
        }
    }

    /// 当前所在的分组 (nil = 根目录)
    private var currentGroup: String? {
        guard case .group(let dirname) = navigationPath.last else { return nil }
        return dirname
    }

    private func emptyTitle(isRoot: Bool) -> String {
        if isFiltering { return "无匹配下载" }
        return isRoot ? "暂无下载" : "分组为空"
    }

    private func emptyDescription(isRoot: Bool) -> String {
        if isFiltering { return "试试更换筛选条件" }
        return isRoot ? "在画廊详情页点击下载按钮" : "长按画廊选择「移动到分组」"
    }

    private func countForFilter(_ filter: DownloadStatusFilter) -> Int {
        // 先用搜索过滤，再按状态计数
        var tasks = vm.tasks
        if !searchText.isEmpty {
            tasks = tasks.filter { $0.gallery.bestTitle.localizedCaseInsensitiveContains(searchText) }
        }

        switch filter {
        case .all: return tasks.count
        case .queue: return tasks.filter { $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait }.count
        case .paused: return tasks.filter { $0.state == DownloadManager.stateNone }.count
        case .finished: return tasks.filter { $0.state == DownloadManager.stateFinish }.count
        case .failed: return tasks.filter { $0.state == DownloadManager.stateFailed }.count
        }
    }

    // MARK: - 主工具栏菜单

    private func mainToolbarMenu(group: String?) -> some View {
        Menu {
            if isSelectMode {
                // 选择模式工具
                Button {
                    let allGids = Set(selectableTasks.map { $0.gallery.gid })
                    if selectedGids == allGids {
                        selectedGids.removeAll()
                    } else {
                        selectedGids = allGids
                    }
                } label: {
                    let allGids = Set(selectableTasks.map { $0.gallery.gid })
                    Label(selectedGids == allGids ? "取消全选" : "全选",
                          systemImage: selectedGids == allGids ? "square" : "checkmark.square")
                }

                Divider()

                Button {
                    batchResume()
                } label: {
                    Label("批量开始 (\(selectedGids.count))", systemImage: "play")
                }
                .disabled(selectedGids.isEmpty)

                Button {
                    batchPause()
                } label: {
                    Label("批量暂停 (\(selectedGids.count))", systemImage: "pause")
                }
                .disabled(selectedGids.isEmpty)

                Button {
                    requestMoveToGroup(Array(selectedGids))
                } label: {
                    Label("移动到分组 (\(selectedGids.count))", systemImage: "folder")
                }
                .disabled(selectedGids.isEmpty)

                Divider()

                Button(role: .destructive) {
                    showBatchDeleteConfirm = true
                } label: {
                    Label("批量删除 (\(selectedGids.count))", systemImage: "trash")
                }
                .disabled(selectedGids.isEmpty)

                Divider()

                Button {
                    exitSelectMode()
                } label: {
                    Label("退出选择", systemImage: "xmark.circle")
                }
            } else {
                // 普通模式 (隐私视图只保留全部开始、暂停和清空已完成)
                if layoutMode != .privacy {
                    // 状态过滤 (对齐 Android DownloadsScene 状态筛选)
                    Picker("状态过滤", selection: $statusFilter) {
                        ForEach(DownloadStatusFilter.allCases) { filter in
                            let count = countForFilter(filter)
                            if filter == .all {
                                Text(filter.rawValue).tag(filter)
                            } else {
                                Text("\(filter.rawValue) (\(count))").tag(filter)
                            }
                        }
                    }

                    Divider()

                    if group == nil {
                        Button {
                            newGroupTakesMovingGids = false
                            showNewGroupAlert = true
                        } label: {
                            Label("新建分组", systemImage: "folder.badge.plus")
                        }
                    }

                    Button {
                        isSelectMode = true
                        selectedGids.removeAll()
                    } label: {
                        Label("批量操作", systemImage: "checkmark.circle")
                    }

                    Divider()
                }

                Button {
                    vm.resumeAll()
                } label: {
                    Label("全部开始", systemImage: "play.fill")
                }

                Button {
                    vm.pauseAll()
                } label: {
                    Label("全部暂停", systemImage: "pause.fill")
                }

                Divider()

                Button(role: .destructive) {
                    vm.clearFinished()
                } label: {
                    Label("清空已完成", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: isSelectMode ? "checkmark.circle.fill" : "ellipsis.circle")
        }
    }

    /// 显示方式切换 (列表 / 网格 / 隐私)
    private var layoutModeMenu: some View {
        Menu {
            Picker("显示方式", selection: $layoutMode) {
                ForEach(DownloadsLayoutMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
        } label: {
            Image(systemName: layoutMode.systemImage)
        }
    }

    // MARK: - 隐私视图

    /// 未完成的画廊按状态分段：下载中、等待中 (按队列顺序)、已暂停、失败；没有画廊的状态不显示
    private var privacySections: [(state: Int, tasks: [DownloadTask])] {
        [DownloadManager.stateDownload, DownloadManager.stateWait, DownloadManager.stateNone, DownloadManager.stateFailed]
            .map { state in (state, vm.tasks.filter { $0.state == state }) }
            .filter { !$0.tasks.isEmpty }
    }

    private var privacyView: some View {
        let sections = privacySections
        let queue = sections
            .filter { $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait }
            .flatMap(\.tasks)
        let downloaded = queue.reduce(0) { $0 + min($1.downloadedPages, $1.gallery.pages) }
        let total = queue.reduce(0) { $0 + $1.gallery.pages }
        let progress = total > 0 ? Double(downloaded) / Double(total) : 0

        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(queue.isEmpty ? "队列为空" : "队列中 \(queue.count) 本")
                            .font(.headline)
                        Spacer()
                        // 本机网速，含其他 App 的流量；每本画廊行里仍显示 App 自己的下载速度
                        HStack(spacing: 10) {
                            Label(DownloadTaskRow.formatSpeed(deviceNetworkSpeed.downloadSpeed), systemImage: "arrow.down")
                                .foregroundStyle(.blue)
                            Label(DownloadTaskRow.formatSpeed(deviceNetworkSpeed.uploadSpeed), systemImage: "arrow.up")
                                .foregroundStyle(.green)
                        }
                        .font(.subheadline)
                        .monospacedDigit()
                    }
                    ProgressView(value: progress)
                    HStack {
                        Text("\(downloaded)/\(total) 页")
                        Spacer()
                        Text("\(Int(progress * 100))%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                .padding(.vertical, 4)
            }

            // 序号跨段连续编号
            ForEach(Array(sections.enumerated()), id: \.element.state) { sectionIndex, section in
                let offset = sections[..<sectionIndex].reduce(0) { $0 + $1.tasks.count }
                Section("\(DownloadTaskRow.statusText(state: section.state)) \(section.tasks.count)") {
                    ForEach(Array(section.tasks.enumerated()), id: \.element.gallery.gid) { index, task in
                        let gid = task.gallery.gid
                        PrivacyTaskRow(
                            index: offset + index + 1,
                            task: task,
                            onPause: { vm.pauseTask(gid: gid) },
                            onResume: { vm.resumeTask(gid: gid) }
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .onAppear { deviceNetworkSpeed.start() }
        .onDisappear { deviceNetworkSpeed.stop() }
        #if os(iOS)
        // 停留在隐私视图时不自动锁屏，下载保持在前台进行
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    // MARK: - 下载列表

    private func downloadList(entries: [DownloadListEntry], group: String?) -> some View {
        List {
            ForEach(entries) { entry in
                switch entry {
                case .group(let downloadGroup, let tasks):
                    groupRow(downloadGroup, tasks: tasks)
                case .gallery(let task):
                    galleryRow(task)
                }
            }
            .onMove(perform: moveAction(entries, group: group))
        }
        .listStyle(.plain)
    }

    private func groupRow(_ group: DownloadGroup, tasks: [DownloadTask]) -> some View {
        NavigationLink(value: DownloadsRoute.group(group.dirname)) {
            DownloadGroupRow(
                group: group,
                tasks: tasks,
                storageSize: tasks.reduce(0) { $0 + (gallerySizes[$1.gallery.gid] ?? 0) }
            )
        }
        .contextMenu {
            groupMenu(group)
        }
        .modifier(GalleryDropModifier(enabled: supportsDragToGroup && canReorder) { gids in
            Task { await vm.moveGalleries(gids, toGroup: group.dirname) }
        })
    }

    /// 文件夹的长按菜单，列表与网格共用
    @ViewBuilder
    private func groupMenu(_ group: DownloadGroup) -> some View {
        Button {
            groupRenameText = group.name
            renamingGroup = group
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button(role: .destructive) {
            dissolvingGroup = group
        } label: {
            Label("解散分组", systemImage: "folder.badge.minus")
        }
    }

    @ViewBuilder
    private func galleryRow(_ task: DownloadTask) -> some View {
        let gid = task.gallery.gid
        let row = DownloadTaskRow(
            task: task,
            readingPage: readingProgress[gid],
            storageSize: gallerySizes[gid],
            groupName: isFiltering ? vm.layout.placement(of: gid).group.map { DownloadGroup(dirname: $0).name } : nil,
            onPause: { vm.pauseTask(gid: gid) },
            onResume: { vm.resumeTask(gid: gid) },
            onRequestDelete: {
                deletingTaskGid = gid
                showSingleDeleteConfirm = true
            },
            onShare: { Task { await shareGallery(task.gallery) } },
            onMoveToGroup: { requestMoveToGroup([gid]) },
            // 批量选择时点封面仍是选中
            onOpenDetail: isSelectMode ? nil : { navigationPath.append(.gallery(task.gallery)) }
        )

        if isSelectMode {
            Button {
                toggleSelection(gid: gid)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedGids.contains(gid) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedGids.contains(gid) ? Color.accentColor : Color.secondary)
                    row
                }
            }
            .buttonStyle(.plain)
        } else {
            // 点击打开阅读器 (使用 fullScreenCover 避免导航栏残留)
            Button {
                readerGallery = task.gallery
            } label: {
                row
            }
            .buttonStyle(.plain)
            .modifier(GalleryDragModifier(enabled: supportsDragToGroup && canReorder, gid: gid))
        }
    }

    /// iPad 和 Mac 支持把画廊拖到文件夹行上 (iPhone 上与列表拖动排序冲突，用长按菜单)
    private var supportsDragToGroup: Bool {
        #if os(macOS)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    /// 可拖动排序时返回拖动结束的处理，否则返回 nil (列表不可拖动)
    private func moveAction(_ entries: [DownloadListEntry], group: String?) -> ((IndexSet, Int) -> Void)? {
        guard canReorder else { return nil }
        return { indices, newOffset in
            moveEntries(entries, from: indices, to: newOffset, group: group)
        }
    }

    /// 拖动排序结束：把新顺序交给 DownloadManager 改目录名
    private func moveEntries(_ entries: [DownloadListEntry], from indices: IndexSet, to newOffset: Int, group: String?) {
        guard let first = indices.first else { return }
        let moved = entries[first].levelItem
        var reordered = entries.map(\.levelItem)
        reordered.move(fromOffsets: indices, toOffset: newOffset)
        Task { await vm.reorder(inGroup: group, items: reordered, moved: moved) }
    }

    // MARK: - 下载网格

    private func downloadGrid(entries: [DownloadListEntry], group: String?) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], alignment: .leading, spacing: 16) {
                ForEach(entries) { entry in
                    gridCell(entry)
                        .overlay {
                            gridDropIndicator(for: entry)
                        }
                        .modifier(GridDragDropModifier(
                            enabled: canReorder,
                            payload: entry.id,
                            acceptsInto: entry.galleryGid == nil,
                            target: $gridDropTarget
                        ) { payloads, position in
                            handleGridDrop(payloads, onto: entry, position: position, group: group)
                        })
                }
            }
            .padding(16)
        }
    }

    /// 拖动悬停时的落点提示：前后为格子间隙里的竖线，移入文件夹为整格描边
    @ViewBuilder
    private func gridDropIndicator(for entry: DownloadListEntry) -> some View {
        if let target = gridDropTarget, target.id == entry.id {
            switch target.position {
            case .into:
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(-4)
            case .before, .after:
                // 列间距 12，竖线宽 4，偏移 8 让它落在间隙正中
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: target.position == .before ? .leading : .trailing)
                    .offset(x: target.position == .before ? -8 : 8)
            }
        }
    }

    @ViewBuilder
    private func gridCell(_ entry: DownloadListEntry) -> some View {
        switch entry {
        case .group(let downloadGroup, let tasks):
            NavigationLink(value: DownloadsRoute.group(downloadGroup.dirname)) {
                DownloadGroupTile(group: downloadGroup, tasks: tasks)
            }
            .buttonStyle(.plain)
            .contextMenu {
                groupMenu(downloadGroup)
            }
        case .gallery(let task):
            let gid = task.gallery.gid
            Button {
                if isSelectMode {
                    toggleSelection(gid: gid)
                } else {
                    readerGallery = task.gallery
                }
            } label: {
                DownloadGalleryTile(
                    task: task,
                    readingPage: readingProgress[gid],
                    selection: isSelectMode ? selectedGids.contains(gid) : nil
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                DownloadTaskMenu(
                    task: task,
                    onPause: { vm.pauseTask(gid: gid) },
                    onResume: { vm.resumeTask(gid: gid) },
                    onShare: { Task { await shareGallery(task.gallery) } },
                    onMoveToGroup: { requestMoveToGroup([gid]) },
                    onRequestDelete: {
                        deletingTaskGid = gid
                        showSingleDeleteConfirm = true
                    },
                    onOpenDetail: { navigationPath.append(.gallery(task.gallery)) }
                )
            }
        }
    }

    /// 网格中松手：落在文件夹中间是把画廊移入分组；落在格子左半边插到它前面，右半边插到它后面
    private func handleGridDrop(
        _ payloads: [String], onto target: DownloadListEntry, position: GridDropPosition, group: String?
    ) -> Bool {
        let entries = listEntries(inGroup: group)
        let dragged = payloads.compactMap { id in entries.first { $0.id == id } }
        guard !dragged.isEmpty, !dragged.contains(where: { $0.id == target.id }) else { return false }

        if position == .into, case .group(let targetGroup, _) = target {
            let gids = dragged.compactMap(\.galleryGid)
            if gids.count == dragged.count {
                Task { await vm.moveGalleries(gids, toGroup: targetGroup.dirname) }
                return true
            }
        }

        guard dragged.count == 1,
              let from = entries.firstIndex(where: { $0.id == dragged[0].id }),
              let to = entries.firstIndex(where: { $0.id == target.id }) else { return false }
        // 文件夹拖到文件夹中间不能移入，按原来的"占据目标位置"处理
        let insertAfter = position == .after || (position == .into && to > from)
        let offset = insertAfter ? to + 1 : to
        // 插入点就在自己前后，位置不变
        guard offset != from, offset != from + 1 else { return false }
        moveEntries(entries, from: IndexSet(integer: from), to: offset, group: group)
        return true
    }

    // MARK: - 移动到分组 Sheet

    private var moveToGroupSheet: some View {
        NavigationStack {
            List {
                Button {
                    moveSelection(toGroup: nil)
                } label: {
                    Label("不分组", systemImage: "tray")
                }

                ForEach(vm.layout.groups) { group in
                    Button {
                        moveSelection(toGroup: group.dirname)
                    } label: {
                        Label(group.name, systemImage: "folder")
                    }
                }

                Button {
                    showMoveToGroupSheet = false
                    newGroupTakesMovingGids = true
                    showNewGroupAlert = true
                } label: {
                    Label("新建分组…", systemImage: "folder.badge.plus")
                }
            }
            .navigationTitle("移动到分组")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        movingGids = []
                        showMoveToGroupSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 辅助

    private func toggleSelection(gid: Int64) {
        if selectedGids.contains(gid) {
            selectedGids.remove(gid)
        } else {
            selectedGids.insert(gid)
        }
    }

    private func exitSelectMode() {
        isSelectMode = false
        selectedGids.removeAll()
    }

    // MARK: - 分组管理

    private func requestMoveToGroup(_ gids: [Int64]) {
        movingGids = gids
        showMoveToGroupSheet = true
    }

    private func moveSelection(toGroup group: String?) {
        let gids = movingGids
        movingGids = []
        showMoveToGroupSheet = false
        Task {
            await vm.moveGalleries(gids, toGroup: group)
            exitSelectMode()
        }
    }

    private func createGroup(_ name: String) {
        let gids = newGroupTakesMovingGids ? movingGids : []
        newGroupTakesMovingGids = false
        movingGids = []
        Task {
            guard let dirname = await vm.createGroup(name: name), !gids.isEmpty else { return }
            await vm.moveGalleries(gids, toGroup: dirname)
            exitSelectMode()
        }
    }

    // MARK: - 批量操作

    private func batchPause() {
        Task {
            for gid in selectedGids {
                await DownloadManager.shared.pauseDownload(gid: gid)
            }
            await vm.loadTasks()
            exitSelectMode()
        }
    }

    private func batchResume() {
        Task {
            for gid in selectedGids {
                await DownloadManager.shared.resumeDownload(gid: gid)
            }
            await vm.loadTasks()
            exitSelectMode()
        }
    }

    private func batchDelete(withFiles: Bool) {
        Task {
            for gid in selectedGids {
                await DownloadManager.shared.deleteDownload(gid: gid, deleteFiles: withFiles)
            }
            await vm.loadTasks()
            exitSelectMode()
        }
    }
}

// MARK: - 列表项

/// 下载页的导航目标
extension TagSearchDestination: Identifiable {
    var id: String { tag }
}

private enum DownloadsRoute: Hashable {
    /// 进入分组 (目录名)
    case group(String)
    /// 画廊详情页
    case gallery(GalleryInfo)
}

/// 下载列表中的一项：文件夹或画廊
private enum DownloadListEntry: Identifiable {
    case group(DownloadGroup, [DownloadTask])
    case gallery(DownloadTask)

    var id: String {
        switch self {
        case .group(let group, _): return "group:\(group.dirname)"
        case .gallery(let task): return "gallery:\(task.gallery.gid)"
        }
    }

    var levelItem: DownloadLevelItem {
        switch self {
        case .group(let group, _): return .group(group.dirname)
        case .gallery(let task): return .gallery(task.gallery.gid)
        }
    }

    var galleryGid: Int64? {
        if case .gallery(let task) = self { return task.gallery.gid }
        return nil
    }
}

/// 只在根目录提供搜索框；进入分组后按状态筛选仍然可用
private struct RootSearchModifier: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: "搜索标题或标签")
        } else {
            content
        }
    }
}

/// 画廊行可拖动 (拖到文件夹行上即移入分组)
private struct GalleryDragModifier: ViewModifier {
    let enabled: Bool
    let gid: Int64

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(String(gid))
        } else {
            content
        }
    }
}

/// 文件夹行接收拖入的画廊
private struct GalleryDropModifier: ViewModifier {
    let enabled: Bool
    let onDrop: ([Int64]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { items, _ in
                let gids = items.compactMap { Int64($0) }
                guard !gids.isEmpty else { return false }
                onDrop(gids)
                return true
            }
        } else {
            content
        }
    }
}

/// 网格中拖放的落点
private enum GridDropPosition: Equatable {
    case before, after
    /// 移入文件夹
    case into
}

private struct GridDropTarget: Equatable {
    let id: String
    let position: GridDropPosition
}

/// 网格格子既可拖动也可接收拖放；悬停时按指针位置算出落点写进 target，用于显示插入线或文件夹高亮
private struct GridDragDropModifier: ViewModifier {
    let enabled: Bool
    let payload: String
    /// 文件夹：中间一半区域表示移入，两侧表示排在它前后
    let acceptsInto: Bool
    @Binding var target: GridDropTarget?
    let onDrop: ([String], GridDropPosition) -> Bool

    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(payload)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .onDrop(of: [.text], delegate: GridDropDelegate(
                    id: payload, acceptsInto: acceptsInto, width: width, target: $target, onDrop: onDrop
                ))
        } else {
            content
        }
    }
}

/// 用 DropDelegate 而不是 dropDestination：拖动过程中要持续拿到指针位置才能显示插入线
private struct GridDropDelegate: DropDelegate {
    let id: String
    let acceptsInto: Bool
    let width: CGFloat
    @Binding var target: GridDropTarget?
    let onDrop: ([String], GridDropPosition) -> Bool

    private func position(_ info: DropInfo) -> GridDropPosition {
        let x = info.location.x
        if acceptsInto, x > width * 0.25, x < width * 0.75 { return .into }
        return x < width / 2 ? .before : .after
    }

    func dropEntered(info: DropInfo) {
        target = GridDropTarget(id: id, position: position(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = GridDropTarget(id: id, position: position(info))
        if target != next { target = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if target?.id == id { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let dropPosition = position(info)
        target = nil
        let providers = info.itemProviders(for: [.text])
        guard !providers.isEmpty else { return false }
        Task {
            var payloads: [String] = []
            for provider in providers {
                if let text = await Self.loadText(provider) { payloads.append(text) }
            }
            _ = onDrop(payloads, dropPosition)
        }
        return true
    }

    /// 回调在后台线程，标成 @Sendable 避免被推断为主线程隔离
    nonisolated private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            _ = provider.loadObject(ofClass: String.self) { @Sendable text, _ in
                continuation.resume(returning: text)
            }
        }
    }
}

// MARK: - 网格格子

/// 网格中的画廊：2:3 封面 + 两行标题 + 一行状态
struct DownloadGalleryTile: View {
    let task: DownloadTask
    let readingPage: Int?
    /// 批量选择时是否选中；不在选择模式时为 nil
    let selection: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { DownloadCoverImage(task: task) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if task.state != DownloadManager.stateFinish {
                        DownloadStatusIcon(state: task.state)
                            .font(.caption)
                            .padding(3)
                            .background(.regularMaterial, in: Circle())
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isActive {
                        ProgressView(value: downloadProgress)
                            .tint(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .padding(4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let selection {
                        Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selection ? Color.accentColor : Color.white)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .padding(4)
                    }
                }

            Text(task.gallery.bestTitle)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)

            Text(detailText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    private var isActive: Bool {
        task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait
    }

    private var downloadProgress: Double {
        guard task.gallery.pages > 0 else { return 0 }
        return Double(task.downloadedPages) / Double(task.gallery.pages)
    }

    /// 已完成显示阅读进度或页数，下载中显示百分比，其余显示状态
    private var detailText: String {
        switch task.state {
        case DownloadManager.stateFinish:
            if let page = readingPage, task.gallery.pages > 0 {
                return "已读 \(page + 1)/\(task.gallery.pages)"
            }
            return "\(task.gallery.pages) 页"
        case DownloadManager.stateDownload:
            return "下载中 · \(Int(downloadProgress * 100))%"
        default:
            return DownloadTaskRow.statusText(task: task)
        }
    }
}

/// 网格中的文件夹：2×2 封面拼贴 + 数量角标 + 组名
struct DownloadGroupTile: View {
    let group: DownloadGroup
    let tasks: [DownloadTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { mosaic }
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(tasks.count)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }

            HStack(spacing: 3) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                Text(group.name)
                    .lineLimit(2, reservesSpace: true)
            }
            .font(.caption.weight(.semibold))

            Text(DownloadGroupRow.summaryText(tasks: tasks, storageSize: 0))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var mosaic: some View {
        if tasks.isEmpty {
            Image(systemName: "folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        } else {
            let covers = Array(tasks.prefix(4))
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    mosaicCell(covers, at: 0)
                    mosaicCell(covers, at: 1)
                }
                HStack(spacing: 3) {
                    mosaicCell(covers, at: 2)
                    mosaicCell(covers, at: 3)
                }
            }
            .padding(5)
        }
    }

    @ViewBuilder
    private func mosaicCell(_ covers: [DownloadTask], at index: Int) -> some View {
        if index < covers.count {
            Color.clear
                .overlay { DownloadCoverImage(task: covers[index]) }
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Color.clear
        }
    }
}

// MARK: - 文件夹行

/// 文件夹行：与画廊行同高；封面区最多叠放 3 张封面，角上显示数量；淡色圆角底块
struct DownloadGroupRow: View {
    let group: DownloadGroup
    let tasks: [DownloadTask]
    let storageSize: Int64

    var body: some View {
        HStack(spacing: 12) {
            coverStack
                .frame(width: 52, height: 72)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                Text(Self.summaryText(tasks: tasks, storageSize: storageSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// 「N 本 · M 本未完成 · 大小」，大小为 0 时不显示
    static func summaryText(tasks: [DownloadTask], storageSize: Int64) -> String {
        var parts = ["\(tasks.count) 本"]
        let unfinished = tasks.filter { $0.state != DownloadManager.stateFinish }.count
        if unfinished > 0 {
            parts.append("\(unfinished) 本未完成")
        }
        if storageSize > 0 {
            parts.append(DownloadsView.formatFileSize(storageSize))
        }
        return parts.joined(separator: " · ")
    }

    /// 后两张缩小、错开、加阴影，第一张在最前
    private var coverStack: some View {
        let covers = Array(tasks.prefix(3))
        return ZStack(alignment: .bottomTrailing) {
            ZStack {
                if covers.isEmpty {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemFill))
                        .overlay {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                        }
                }
                ForEach(Array(covers.enumerated().reversed()), id: \.element.gallery.gid) { item in
                    let index = item.offset
                    let scale = 1.0 - CGFloat(index) * 0.12
                    DownloadCoverImage(task: item.element)
                        .frame(width: 44 * scale, height: 62 * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(index == 0 ? 0.15 : 0.25), radius: 2, x: 1, y: 1)
                        .offset(x: CGFloat(index) * 5, y: -CGFloat(index) * 4)
                }
            }
            .frame(width: 52, height: 72, alignment: .leading)

            Text("\(tasks.count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
                .offset(x: 4, y: 4)
        }
    }
}

/// 下载画廊的封面：优先读本地第一页并降采样 (离线也有封面)，没有再用 thumb URL
struct DownloadCoverImage: View {
    let task: DownloadTask

    @State private var localImage: PlatformImage?

    var body: some View {
        Group {
            if let localImage {
                #if os(macOS)
                Image(nsImage: localImage).resizable().aspectRatio(contentMode: .fill)
                #else
                Image(uiImage: localImage).resizable().aspectRatio(contentMode: .fill)
                #endif
            } else {
                CachedAsyncImage(url: URL(string: task.gallery.thumb ?? ""), showProgress: false) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color(.tertiarySystemFill)
                }
            }
        }
        .task(id: task.gallery.gid) {
            localImage = await LocalCoverCache.shared.cover(for: task.gallery)
        }
    }
}

/// 本地第一页的缩略图缓存 (约 300px，网格格子也够清晰)
actor LocalCoverCache {
    static let shared = LocalCoverCache()

    private let cache = NSCache<NSNumber, PlatformImage>()
    /// 没有本地文件的 gid，避免反复查盘
    private var missing = Set<Int64>()

    func cover(for gallery: GalleryInfo) async -> PlatformImage? {
        let key = NSNumber(value: gallery.gid)
        if let cached = cache.object(forKey: key) { return cached }
        if missing.contains(gallery.gid) { return nil }

        let dir = DownloadManager.shared.galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)
        guard let file = SpiderInfoFile.getLocalImageURL(in: dir, pageIndex: 0),
              let image = Self.thumbnail(of: file, maxPixelSize: 300) else {
            missing.insert(gallery.gid)
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func thumbnail(of file: URL, maxPixelSize: Int) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}

// MARK: - Download Task Row

/// 画廊的长按菜单，列表行与网格格子共用
struct DownloadTaskMenu: View {
    let task: DownloadTask
    let onPause: () -> Void
    let onResume: () -> Void
    let onShare: () -> Void
    let onMoveToGroup: () -> Void
    let onRequestDelete: () -> Void
    /// 网格中点格子是阅读，详情页从菜单进入；列表中点封面进详情页，不需要这一项
    var onOpenDetail: (() -> Void)? = nil

    var body: some View {
        // 暂停/恢复
        if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
            Button {
                onPause()
            } label: {
                Label("暂停", systemImage: "pause")
            }
        } else if task.state != DownloadManager.stateFinish {
            Button {
                onResume()
            } label: {
                Label("继续", systemImage: "play")
            }
        }

        if let onOpenDetail {
            Button {
                onOpenDetail()
            } label: {
                Label("画廊详情", systemImage: "info.circle")
            }
        }

        // 分享 (issue #2: 打包成 zip 交给系统分享)
        if task.state == DownloadManager.stateFinish {
            Button {
                onShare()
            } label: {
                Label("分享 (打包为 zip)", systemImage: "square.and.arrow.up")
            }
        }

        Button {
            onMoveToGroup()
        } label: {
            Label("移动到分组…", systemImage: "folder")
        }

        Divider()

        // 删除 (请求父视图弹出确认)
        Button(role: .destructive) {
            onRequestDelete()
        } label: {
            Label("删除", systemImage: "trash")
        }

        #if os(macOS)
        // Mac: 在 Finder 中显示 (Fix A-3: 使用统一路径算法)
        if task.state == DownloadManager.stateFinish {
            Button {
                let dir = DownloadManager.shared.galleryDirectory(gid: task.gallery.gid, title: task.gallery.bestTitle)
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
        }
        #endif
    }
}

/// 隐私视图的一行：只有序号和进度 (状态见段头)，不显示封面、标题，点击不打开任何页面
private struct PrivacyTaskRow: View {
    let index: Int
    let task: DownloadTask
    let onPause: () -> Void
    let onResume: () -> Void

    private var isActive: Bool {
        task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait
    }

    private var progress: Double {
        guard task.gallery.pages > 0 else { return 0 }
        return min(1, Double(task.downloadedPages) / Double(task.gallery.pages))
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(index)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                HStack {
                    Text("\(task.downloadedPages)/\(task.gallery.pages) 页 · \(Int(progress * 100))%")
                    Spacer()
                    if task.state == DownloadManager.stateDownload, task.speed > 0 {
                        Text(DownloadTaskRow.formatSpeed(task.speed))
                            .foregroundStyle(.blue)
                    } else if task.state == DownloadManager.stateFailed, let reason = task.failureReason {
                        Text(reason)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Button {
                isActive ? onPause() : onResume()
            } label: {
                Image(systemName: isActive ? "pause.circle" : "play.circle")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

/// 下载状态图标
struct DownloadStatusIcon: View {
    let state: Int

    var body: some View {
        switch state {
        case DownloadManager.stateDownload:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case DownloadManager.stateWait:
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
        case DownloadManager.stateFinish:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case DownloadManager.stateFailed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        default:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}


struct DownloadTaskRow: View {
    let task: DownloadTask
    let readingPage: Int?      // 阅读进度 (当前页索引)
    let storageSize: Int64?    // 画廊占用空间 (字节)
    let groupName: String?     // 所属分组 (搜索/筛选平铺显示时注明)
    let onPause: () -> Void
    let onResume: () -> Void
    let onRequestDelete: () -> Void   // 请求删除 (由父视图处理确认)
    let onShare: () -> Void           // 打包为 zip 并分享 (issue #2)
    let onMoveToGroup: () -> Void
    /// 点封面打开画廊详情页；nil 时点封面与点行内其他区域相同
    var onOpenDetail: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            // 封面
            CachedAsyncImage(url: URL(string: task.gallery.thumb ?? "")) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.tertiarySystemFill)
            }
            .frame(width: 52, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture().onEnded { onOpenDetail?() },
                including: onOpenDetail == nil ? .subviews : .all
            )

            VStack(alignment: .leading, spacing: 5) {
                // 标题
                Text(task.gallery.bestTitle)
                    .font(.subheadline)
                    .lineLimit(2)

                if let groupName {
                    Label(groupName, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // 状态 + 页数 + 存储
                HStack(spacing: 6) {
                    DownloadStatusIcon(state: task.state)
                        .font(.caption)
                    Text(Self.statusText(task: task))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    // 占用空间
                    if let size = storageSize, size > 0 {
                        Text(DownloadsView.formatFileSize(size))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    // 阅读进度 (已完成/暂停/失败 状态显示) — 与总页数去重
                    if let page = readingPage, task.gallery.pages > 0,
                       task.state != DownloadManager.stateDownload && task.state != DownloadManager.stateWait {
                        HStack(spacing: 4) {
                            ProgressView(value: Double(page + 1), total: Double(task.gallery.pages))
                                .tint(.green)
                                .frame(maxWidth: 60)
                            Text("\(page + 1)/\(task.gallery.pages) 页")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else if task.state != DownloadManager.stateDownload && task.state != DownloadManager.stateWait {
                        // 无阅读进度时才单独显示总页数
                        Text("\(task.gallery.pages) 页")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 下载进度条 + 页数详情 (下载中/等待中)
                if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                    VStack(spacing: 2) {
                        ProgressView(value: downloadProgress)
                            .tint(.accentColor)
                        HStack {
                            Text("\(task.downloadedPages)/\(task.gallery.pages)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if task.state == DownloadManager.stateDownload, task.speed > 0 {
                                Text(Self.formatSpeed(task.speed))
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            DownloadTaskMenu(
                task: task,
                onPause: onPause,
                onResume: onResume,
                onShare: onShare,
                onMoveToGroup: onMoveToGroup,
                onRequestDelete: onRequestDelete
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                Button {
                    onPause()
                } label: {
                    Label("暂停", systemImage: "pause")
                }
                .tint(.orange)
            } else if task.state != DownloadManager.stateFinish {
                Button {
                    onResume()
                } label: {
                    Label("继续", systemImage: "play")
                }
                .tint(.green)
            }
        }
    }

    /// 状态文字，失败时带上原因
    static func statusText(task: DownloadTask) -> String {
        let text = statusText(state: task.state)
        guard task.state == DownloadManager.stateFailed, let reason = task.failureReason else { return text }
        return "\(text) · \(reason)"
    }

    /// 状态文字，列表行、网格格子与隐私模式分段共用
    static func statusText(state: Int) -> String {
        switch state {
        case DownloadManager.stateDownload: return "下载中"
        case DownloadManager.stateWait: return "等待中"
        case DownloadManager.stateFinish: return "已完成"
        case DownloadManager.stateFailed: return "失败"
        default: return "已暂停"
        }
    }

    private var downloadProgress: Double {
        guard task.gallery.pages > 0 else { return 0 }
        return Double(task.downloadedPages) / Double(task.gallery.pages)
    }

    /// 自适应格式化下载速度 (KB/s 或 MB/s)
    static func formatSpeed(_ bytesPerSecond: Int64) -> String {
        let kb = Double(bytesPerSecond) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB/s", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.2f MB/s", mb)
    }
}

// MARK: - ViewModel

@Observable
class DownloadsViewModel {
    var tasks: [DownloadTask] = []
    /// 队列因 509、IP 封禁等整体暂停的原因
    var haltReason: String?
    /// 分组与每本画廊的位置 (来自下载目录结构)
    var layout = DownloadLayout()
    /// 分组、移动、排序失败时的提示
    var operationError: String?
    /// 进度刷新定时器 (有活跃下载时每秒刷新)
    private var refreshTimer: Timer?

    func loadTasks() async {
        tasks = await DownloadManager.shared.getAllTasks()
        haltReason = await DownloadManager.shared.haltReason
        layout = await DownloadManager.shared.directoryLayout()
        updateRefreshTimer()
    }

    // MARK: 分组与排序

    /// - Returns: 新分组的目录名，失败时返回 nil
    func createGroup(name: String) async -> String? {
        var dirname: String?
        do {
            dirname = try await DownloadManager.shared.createGroup(name: name)
        } catch {
            operationError = error.localizedDescription
        }
        await loadTasks()
        return dirname
    }

    func renameGroup(_ group: DownloadGroup, to name: String) async {
        await perform { try await DownloadManager.shared.renameGroup(dirname: group.dirname, to: name) }
    }

    func dissolveGroup(_ group: DownloadGroup) async {
        await perform { try await DownloadManager.shared.dissolveGroup(dirname: group.dirname) }
    }

    func moveGalleries(_ gids: [Int64], toGroup group: String?) async {
        await perform { try await DownloadManager.shared.moveGalleries(gids, toGroup: group) }
    }

    func reorder(inGroup group: String?, items: [DownloadLevelItem], moved: DownloadLevelItem) async {
        await perform { try await DownloadManager.shared.reorder(inGroup: group, items: items, moved: moved) }
    }

    /// 执行目录操作，失败时记录提示；无论成败都按磁盘重新加载
    private func perform(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            operationError = error.localizedDescription
        }
        await loadTasks()
    }

    /// 检查是否有活跃下载，有则启动定时刷新
    private func updateRefreshTimer() {
        let hasActive = tasks.contains(where: {
            $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
        })

        if hasActive && refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.tasks = await DownloadManager.shared.getAllTasks()
                    self.haltReason = await DownloadManager.shared.haltReason
                    // 如果没有活跃下载了，停止定时器
                    let stillActive = self.tasks.contains(where: {
                        $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
                    })
                    if !stillActive {
                        self.refreshTimer?.invalidate()
                        self.refreshTimer = nil
                    }
                }
            }
        } else if !hasActive {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    func pauseTask(gid: Int64) {
        Task {
            await DownloadManager.shared.pauseDownload(gid: gid)
            await loadTasks()
        }
    }

    func resumeTask(gid: Int64) {
        Task {
            await DownloadManager.shared.resumeDownload(gid: gid)
            await loadTasks()
        }
    }

    func deleteTask(gid: Int64, withFiles: Bool = false) {
        Task {
            await DownloadManager.shared.deleteDownload(gid: gid, deleteFiles: withFiles)
            await loadTasks()
        }
    }

    func pauseAll() {
        Task {
            // 使用 DownloadManager 的批量暂停，避免逐个暂停时 processQueue 不断启动下一个
            await DownloadManager.shared.pauseAllDownloads()
            await loadTasks()
        }
    }

    func resumeAll() {
        Task {
            for task in tasks where task.state == DownloadManager.stateNone || task.state == DownloadManager.stateFailed {
                await DownloadManager.shared.resumeDownload(gid: task.gallery.gid)
            }
            // 强制尝试处理队列 (防止 isRunning 残留为 true 导致队列卡死)
            await DownloadManager.shared.kickQueue()
            await loadTasks()
        }
    }

    /// Fix A-2: 清除已完成下载时同时删除文件，释放磁盘空间
    func clearFinished() {
        Task {
            for task in tasks where task.state == DownloadManager.stateFinish {
                await DownloadManager.shared.deleteDownload(gid: task.gallery.gid, deleteFiles: true)
            }
            await loadTasks()
        }
    }
}

// MARK: - 存储工具 (非 MainActor，可在后台线程安全调用)

enum StorageUtils: Sendable {
    /// 递归计算目录大小
    nonisolated static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true,
                  let fileSize = resourceValues.fileSize else { continue }
            totalSize += Int64(fileSize)
        }
        return totalSize
    }

    /// 格式化文件大小
    nonisolated static func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024.0
        return String(format: "%.2f GB", gb)
    }
}

// MARK: - 本机网速

/// 本机上下行网速：每秒读一次各网卡的累计收发字节数取差，包含其他 App 的流量
@Observable
final class DeviceNetworkSpeedMonitor {
    private(set) var downloadSpeed: Int64 = 0
    private(set) var uploadSpeed: Int64 = 0

    private var lastCounters: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var lastTime: Date?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        lastCounters = [:]
        lastTime = nil
        sample()
        // 定时器加在主线程 RunLoop 上，回调本来就在主线程
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        downloadSpeed = 0
        uploadSpeed = 0
    }

    private func sample() {
        let counters = Self.readCounters()
        let now = Date()
        if let lastTime, now.timeIntervalSince(lastTime) > 0 {
            var rx: UInt64 = 0
            var tx: UInt64 = 0
            // 按网卡分别取差：切换 Wi-Fi / 蜂窝时新出现的网卡从下一秒开始计
            for (name, current) in counters {
                guard let previous = lastCounters[name] else { continue }
                rx += Self.delta(current.rx, previous.rx)
                tx += Self.delta(current.tx, previous.tx)
            }
            let elapsed = now.timeIntervalSince(lastTime)
            downloadSpeed = Int64(Double(rx) / elapsed)
            uploadSpeed = Int64(Double(tx) / elapsed)
        }
        lastCounters = counters
        lastTime = now
    }

    /// 系统计数器是 32 位，超过 4 GB 会从 0 重新开始
    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : current + (1 << 32) - previous
    }

    /// 只统计物理网卡 (Wi-Fi 与有线 en*、蜂窝 pdp_ip*)：VPN 隧道 (utun、ipsec) 的流量同样经过物理网卡，再算会重复
    nonisolated private static func readCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [:] }
        defer { freeifaddrs(addresses) }

        var result: [String: (rx: UInt64, tx: UInt64)] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes))
        }
        return result
    }
}

#Preview {
    DownloadsView()
}
