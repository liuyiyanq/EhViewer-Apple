import Foundation
import EhDatabase

// MARK: - DownloadDirectoryName

/// 下载目录的命名规则
///
/// ```
/// download/
/// ├── 000100_汉化精选/              分组：序号_组名，目录内没有 .ehviewer
/// │   ├── 000100_2345678-标题A/     已排序画廊：序号_gid-标题
/// │   └── 2345680-标题C/            未排序画廊：旧格式
/// └── 1111111-旧画廊/               旧版本画廊，原样兼容
/// ```
///
/// 序号前缀是可选的 6 位数字加 `_`；旧格式中 gid 后面是 `-`，两者不会混淆。
public enum DownloadDirectoryName {
    static let orderDigits = 6

    /// 拆出可选的序号前缀，返回 (序号, 去掉前缀后的名字)
    public static func parseOrder(_ name: String) -> (order: Int?, rest: String) {
        let chars = Array(name)
        guard chars.count > orderDigits, chars[orderDigits] == "_",
              chars[0..<orderDigits].allSatisfy({ $0.isASCII && $0.isNumber }),
              let order = Int(String(chars[0..<orderDigits])) else {
            return (nil, name)
        }
        return (order, String(chars[(orderDigits + 1)...]))
    }

    /// 给名字加上序号前缀（已有前缀会先去掉）
    public static func withOrder(_ order: Int?, name: String) -> String {
        let rest = parseOrder(name).rest
        guard let order else { return rest }
        return String(format: "%0\(orderDigits)d_", order) + rest
    }

    /// 从画廊目录名还原标题：去掉序号前缀和 `gid-`
    public static func galleryTitle(fromDirectoryName name: String, gid: Int64) -> String {
        let rest = parseOrder(name).rest
        let prefix = "\(gid)-"
        return rest.hasPrefix(prefix) ? String(rest.dropFirst(prefix.count)) : rest
    }
}

// MARK: - GalleryDirectoryIndex

/// gid → 画廊目录相对路径（相对下载根目录，如 `000100_组/2345678-标题`）的索引
///
/// 画廊身份只认 .ehviewer 中的 gid：目录名会因序号、分组或用户在「文件」App 中改动而变化，
/// 所以路径以扫描磁盘的结果为准，数据库 downloadDirname 表只做缓存，启动时不必先扫盘也能用。
/// 加锁实现，可在任意线程同步读取。
final class GalleryDirectoryIndex: @unchecked Sendable {
    private let lock = NSLock()
    /// nil 表示还没从数据库加载
    private var paths: [Int64: String]?

    func relativePath(gid: Int64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadedPaths()[gid]
    }

    func set(gid: Int64, relativePath: String) {
        lock.lock()
        var current = loadedPaths()
        let changed = current[gid] != relativePath
        current[gid] = relativePath
        paths = current
        lock.unlock()
        if changed {
            try? EhDatabase.shared.putDownloadDirname(gid: gid, dirname: relativePath)
        }
    }

    func remove(gid: Int64) {
        lock.lock()
        var current = loadedPaths()
        current.removeValue(forKey: gid)
        paths = current
        lock.unlock()
        try? EhDatabase.shared.removeDownloadDirname(gid: gid)
    }

    /// 用一次完整扫描的结果替换整个索引
    func replaceAll(_ newPaths: [Int64: String]) {
        lock.lock()
        let changed = loadedPaths() != newPaths
        paths = newPaths
        lock.unlock()
        if changed {
            try? EhDatabase.shared.replaceDownloadDirnames(newPaths)
        }
    }

    /// 调用方须已持有锁
    private func loadedPaths() -> [Int64: String] {
        if let paths { return paths }
        let records = (try? EhDatabase.shared.getAllDownloadDirnames()) ?? []
        let loaded = Dictionary(records.map { ($0.gid, $0.dirname) }, uniquingKeysWith: { first, _ in first })
        paths = loaded
        return loaded
    }
}

extension GalleryDirectoryIndex {
    /// 当前全部 gid → 相对路径
    func allPaths() -> [Int64: String] {
        lock.lock()
        defer { lock.unlock() }
        return loadedPaths()
    }
}

// MARK: - 分组与排序的布局

/// 下载根目录下的一个分组（目录内没有 .ehviewer，也没有页面图片）
public struct DownloadGroup: Sendable, Hashable, Identifiable {
    /// 目录名，含序号前缀
    public let dirname: String
    public var id: String { dirname }
    /// 组名：目录名去掉序号前缀
    public var name: String { DownloadDirectoryName.parseOrder(dirname).rest }
    public var order: Int? { DownloadDirectoryName.parseOrder(dirname).order }
    /// 目录创建时间：空分组按它参与未排序项的倒序
    public let createdAt: Date?

    public init(dirname: String, createdAt: Date? = nil) {
        self.dirname = dirname
        self.createdAt = createdAt
    }
}

/// 一本画廊在目录结构中的位置
public struct GalleryPlacement: Sendable, Hashable {
    /// 所在分组的目录名，nil 表示在根目录
    public let group: String?
    /// 序号，nil 表示未排序
    public let order: Int?

    init(relativePath: String?) {
        guard let relativePath else {
            group = nil
            order = nil
            return
        }
        let components = relativePath.split(separator: "/").map(String.init)
        group = components.count >= 2 ? components[0] : nil
        order = components.last.flatMap { DownloadDirectoryName.parseOrder($0).order }
    }
}

/// 下载目录的布局快照：根目录下的分组，以及每本画廊的位置
public struct DownloadLayout: Sendable {
    public var groups: [DownloadGroup]
    public var placements: [Int64: GalleryPlacement]

    public init(groups: [DownloadGroup] = [], placements: [Int64: GalleryPlacement] = [:]) {
        self.groups = groups
        self.placements = placements
    }

    public func placement(of gid: Int64) -> GalleryPlacement {
        placements[gid] ?? GalleryPlacement(relativePath: nil)
    }
}

/// 同一层（根目录或某个分组内）中参与排序的一项
public enum DownloadLevelItem: Sendable, Hashable {
    case group(String)
    case gallery(Int64)
}

public enum DownloadGroupError: LocalizedError, Sendable {
    case invalidName
    case nameExists
    case groupNotFound
    case targetExists(String)
    case onlyOtherFiles

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "分组名称无效"
        case .nameExists: return "已存在同名分组"
        case .groupNotFound: return "分组不存在"
        case .targetExists(let name): return "目标位置已有同名目录：\(name)"
        case .onlyOtherFiles: return "分组里没有可移出的画廊，目录中的其他文件已保留"
        }
    }
}
