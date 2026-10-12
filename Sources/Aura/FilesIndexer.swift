import AppKit
import CryptoKit
import Darwin

// MARK: - File kinds

enum FileKind: String, CaseIterable, Codable {
    case image, video, music, document, archive, app, other

    var label: String {
        switch self {
        case .image: return "Images"
        case .video: return "Videos"
        case .music: return "Music"
        case .document: return "Documents"
        case .archive: return "Archives"
        case .app: return "Apps"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "video"
        case .music: return "music.note"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .app: return "app.badge"
        case .other: return "doc"
        }
    }
}

private let extKinds: [(FileKind, Set<String>)] = [
    (.image, ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg", "ico", "raw", "dng", "cr2", "nef", "arw", "avif"]),
    (.video, ["mp4", "mov", "mkv", "avi", "webm", "m4v", "mpg", "mpeg", "wmv", "flv", "3gp"]),
    (.music, ["mp3", "wav", "flac", "aac", "m4a", "ogg", "oga", "opus", "mid", "midi", "aiff", "alac"]),
    (.document, ["pdf", "doc", "docx", "pages", "txt", "md", "markdown", "rtf", "csv", "tsv", "xls", "xlsx", "ppt", "pptx", "key", "numbers", "tex", "epub", "odt", "ods", "odp", "json", "xml", "yaml", "yml", "log", "html", "htm", "swift", "c", "h", "cpp", "py", "js", "ts", "java", "rb", "go", "rs", "sh", "sql"]),
    (.archive, ["zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz", "dmg", "pkg", "iso", "cab", "zst"]),
]

func categorizeFile(name: String, isApp: Bool) -> FileKind {
    if isApp { return .app }
    let ext = (name as NSString).pathExtension.lowercased()
    guard !ext.isEmpty else { return .other }
    for (kind, set) in extKinds where set.contains(ext) { return kind }
    return .other
}

// MARK: - Indexed file

struct IndexedFile: Identifiable, Hashable, Codable, Sendable {
    /// Stable identity = full path.
    var id: String { path }
    var name: String
    var path: String
    var size: Int64
    var modified: Date
    var created: Date
    var accessed: Date?
    var kind: FileKind
    var sourceHost: String?
    var isScreenshot: Bool

    var ext: String { (name as NSString).pathExtension.lowercased() }
}

// MARK: - Helpers (where-froms, partial hash, atime, sizes)

/// Reads com.apple.metadata:kMDItemWhereFroms → downloader host (Safari/Chrome/Finder set this).
func whereFromsHost(at path: String) -> String? {
    let key = "com.apple.metadata:kMDItemWhereFroms"
    let n = (path as NSString).utf8String.map { getxattr($0, key, nil, 0, 0, 0) } ?? -1
    guard n > 0, n < 1_000_000 else { return nil }
    var buf = [UInt8](repeating: 0, count: n)
    let got = buf.withUnsafeMutableBytes { ptr in
        (path as NSString).utf8String.map { getxattr($0, key, ptr.baseAddress, n, 0, 0) } ?? -1
    }
    guard got == n else { return nil }
    guard let list = try? PropertyListSerialization.propertyList(from: Data(buf), format: nil) as? [String],
          let first = list.first, let host = URL(string: first)?.host, !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// Cheap near-exact identity: SHA256(first 64KB + last 64KB). Skips full reads of huge files.
func partialHash(path: String, size: Int64) -> String? {
    guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
    defer { try? fh.close() }
    var hasher = SHA256()
    let chunk = 65536
    do {
        if let head = try fh.read(upToCount: chunk) { hasher.update(data: head) }
        if size > Int64(chunk) {
            try fh.seek(toOffset: UInt64(max(0, size - Int64(chunk))))
            if let tail = try fh.readToEnd() { hasher.update(data: tail.prefix(chunk)) }
        }
    } catch { return nil }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func lastAccessDate(_ path: String) -> Date? {
    var st = stat()
    guard stat(path, &st) == 0, st.st_atimespec.tv_sec > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
}

/// Recursive allocated size (for .app bundles).
func directoryAllocatedSize(_ url: URL, fileCap: Int = 150_000) -> Int64 {
    var total: Int64 = 0
    var seen = 0
    guard let e = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    for case let u as URL in e {
        seen += 1
        if seen > fileCap { break }
        if let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
           v.isRegularFile == true {
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
    }
    return total
}

func byteString(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

// MARK: - Cached analysis (computed once per scan, off the main thread)
//
// Every derived list lives here. The UI reads these — never recomputes —
// so rendering stays at 60fps no matter how big the library gets.

struct FileAnalysis: Sendable {
    var byKind: [FileKind: [IndexedFile]] = [:]
    var counts: [FileKind: Int] = [:]
    var bytesByKind: [FileKind: Int64] = [:]
    var recents: [IndexedFile] = []
    var large: [IndexedFile] = []
    var largeCount = 0
    var shots: [IndexedFile] = []
    var dupGroups: [DupGroup] = []
    var forgotten: [IndexedFile] = []
    var oldShots: [IndexedFile] = []
    var unused: [IndexedFile] = []
    var sources: [DownloadSource] = []
    var dupExtraBytes: Int64 = 0
    var bytesTotal: Int64 = 0
    /// Pre-grouped by the Locations roots the UI actually queries.
    var byRoot: [String: [IndexedFile]] = [:]
    /// Per-kind created-date span (for stat-card date ranges).
    var spans: [FileKind: (oldest: Date, newest: Date)] = [:]
    /// 30-day trend % per kind (bytes created last 30d vs prior 30d).
    var trends: [FileKind: Double] = [:]
    /// Bytes by created month "yyyy-MM" / day "yyyy-MM-dd".
    var monthlyBytes: [String: Int64] = [:]
    var dailyBytes: [String: Int64] = [:]
    /// [year: [kind: bytes]] for the stacked bar chart.
    var yearlyKind: [Int: [FileKind: Int64]] = [:]

    static let empty = FileAnalysis()

    nonisolated static func compute(files: [IndexedFile], apps: [IndexedFile]) -> FileAnalysis {
        var a = FileAnalysis()
        let all = files + apps
        var byKind: [FileKind: [IndexedFile]] = [:]
        for f in files { byKind[f.kind, default: []].append(f) }
        byKind[.app] = apps.sorted { $0.size > $1.size }
        for k in byKind.keys where k != .app {
            byKind[k]?.sort { $0.modified > $1.modified }
        }
        a.byKind = byKind
        for k in FileKind.allCases {
            a.counts[k] = k == .app ? apps.count : byKind[k]?.count ?? 0
            a.bytesByKind[k] = (k == .app ? apps : byKind[k] ?? []).reduce(0) { $0 + $1.size }
        }
        a.recents = Array(all.sorted { $0.modified > $1.modified }.prefix(200))
        let large = files.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        a.large = Array(large.prefix(200))
        a.largeCount = large.filter { $0.size > 100_000_000 }.count
        a.shots = files.filter(\.isScreenshot).sorted { $0.modified > $1.modified }
        a.dupGroups = findDuplicates(in: files)
        a.dupExtraBytes = a.dupGroups.reduce(0) { $0 + $1.extraBytes }
        let cutoff30 = Date().addingTimeInterval(-30 * 86400)
        let dl = NSHomeDirectory() + "/Downloads/"
        a.forgotten = files.filter { $0.path.hasPrefix(dl) && $0.modified < cutoff30 }
            .sorted { $0.modified < $1.modified }
        a.oldShots = a.shots.filter { $0.modified < cutoff30 }
        let cutoff90 = Date().addingTimeInterval(-90 * 86400)
        a.unused = apps.filter { ($0.accessed ?? $0.modified) < cutoff90 }
            .sorted { ($0.accessed ?? $0.modified) < ($1.accessed ?? $1.modified) }
        var agg: [String: (count: Int, bytes: Int64)] = [:]
        for f in files {
            guard let h = f.sourceHost else { continue }
            let cur = agg[h] ?? (0, 0)
            agg[h] = (cur.count + 1, cur.bytes + f.size)
        }
        a.sources = agg.map { DownloadSource(host: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { $0.bytes > $1.bytes }
        a.bytesTotal = files.reduce(0) { $0 + $1.size } + apps.reduce(0) { $0 + $1.size }
        let homeRoot = NSHomeDirectory()
        for root in ["", "/Desktop", "/Documents", "/Downloads", "/Pictures", "/Movies", "/Music"] {
            let full = homeRoot + root
            a.byRoot[full] = files.filter { $0.path.hasPrefix(full == homeRoot ? homeRoot + "/" : full + "/") || $0.path == full }
                .sorted { $0.modified > $1.modified }
        }
        // Time analytics, single pass over created dates.
        let cal = Calendar.current
        let now = Date()
        let d30 = now.addingTimeInterval(-30 * 86400)
        let d60 = now.addingTimeInterval(-60 * 86400)
        var recent30: [FileKind: Int64] = [:]
        var prior30: [FileKind: Int64] = [:]
        for f in files {
            let c = f.created
            guard c.timeIntervalSince1970 > 0, c <= now else { continue }
            if let s = a.spans[f.kind] {
                a.spans[f.kind] = (min(s.oldest, c), max(s.newest, c))
            } else {
                a.spans[f.kind] = (c, c)
            }
            let comps = cal.dateComponents([.year, .month, .day], from: c)
            if let y = comps.year, let m = comps.month {
                let mk = String(format: "%04d-%02d", y, m)
                a.monthlyBytes[mk, default: 0] += f.size
                a.yearlyKind[y, default: [:]][f.kind, default: 0] += f.size
                if let d = comps.day {
                    a.dailyBytes[String(format: "%04d-%02d-%02d", y, m, d), default: 0] += f.size
                }
            }
            if c >= d30 { recent30[f.kind, default: 0] += f.size }
            else if c >= d60 { prior30[f.kind, default: 0] += f.size }
        }
        for k in FileKind.allCases {
            let r = Double(recent30[k] ?? 0), p = Double(prior30[k] ?? 0)
            a.trends[k] = p > 0 ? (r - p) / p * 100 : (r > 0 ? 100 : 0)
        }
        return a
    }

    nonisolated static func findDuplicates(in files: [IndexedFile]) -> [DupGroup] {
        var bySize: [Int64: [IndexedFile]] = [:]
        for f in files where f.size > 0 && f.kind != .app {
            bySize[f.size, default: []].append(f)
        }
        var groups: [DupGroup] = []
        for (size, list) in bySize where list.count > 1 {
            var byHash: [String: [IndexedFile]] = [:]
            for f in list {
                guard let h = partialHash(path: f.path, size: f.size) else { continue }
                byHash[h, default: []].append(f)
            }
            for (_, g) in byHash where g.count > 1 {
                groups.append(DupGroup(size: size, files: g.sorted { $0.path < $1.path }))
            }
        }
        return groups.sorted { $0.extraBytes > $1.extraBytes }
    }
}

// MARK: - Indexer

struct DupGroup: Identifiable {
    var id: String { "\(size)-\(files.first?.path ?? "")" }
    var size: Int64
    var files: [IndexedFile]
    var extraBytes: Int64 { size * Int64(max(0, files.count - 1)) }
}

struct DownloadSource: Identifiable {
    var id: String { host }
    var host: String
    var count: Int
    var bytes: Int64
}

@MainActor
final class FilesIndexer: ObservableObject {
    @Published private(set) var files: [IndexedFile] = []
    @Published private(set) var apps: [IndexedFile] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedCount = 0
    /// Everything derived, refreshed once per scan off-main. The UI reads
    /// these and never recomputes (duplicate hashing on the render path was
    /// the old freeze).
    @Published private(set) var analysis = FileAnalysis.empty

    private let iconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        return c
    }()
    private let maxFiles = 40_000
    private var indexURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Aura/files-index.json", isDirectory: false)
    }

    init(loadPersisted: Bool = true) {
        // Intentionally empty: 9.5MB JSON decode + analysis must never run
        // on the main thread at launch. Owners call loadPersisted().
        if loadPersisted {
            Task { await self.loadPersisted() }
        }
    }

    private struct PersistedIndex: Codable {
        var files: [IndexedFile]
        var apps: [IndexedFile]
    }

    /// Loads last scan off-main: decode + analytics both in background.
    func loadPersisted() async {
        let url = indexURL
        let decoded: PersistedIndex? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(PersistedIndex.self, from: data)
        }.value
        guard let saved = decoded, !scanning else { return }
        files = saved.files
        apps = saved.apps
        scannedCount = files.count + apps.count
        let snapshotFiles = files
        let snapshotApps = apps
        analysis = await Task.detached(priority: .utility) {
            FileAnalysis.compute(files: snapshotFiles, apps: snapshotApps)
        }.value
    }

    private func persist() {
        // Encode + write off-main: 40k objects must never block the UI.
        let snapshot = PersistedIndex(files: files, apps: apps)
        let url = indexURL
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                // Non-fatal; next open just rescans.
            }
        }
    }

    var allEntries: [IndexedFile] { files + apps }

    // MARK: Scan

    func scan() {
        guard !scanning else { return }
        Task { await runScan() }
    }

    func runScan() async {
        scanning = true
        defer { scanning = false }
        files = []
        apps = []
        analysis = .empty
        scannedCount = 0
        let cap = maxFiles

        // Phase 1: home folders (fast metadata pass, progressive).
        let home = NSHomeDirectory()
        let roots = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
        let batches = await Task.detached(priority: .utility) {
            Self.enumerateFiles(roots: roots, maxFiles: cap)
        }.value
        for batch in batches {
            files.append(contentsOf: batch)
            scannedCount = files.count
        }

        // Phase 2: app sizes in parallel (sequential sizing was the old stall).
        let appDirs = ["/Applications", home + "/Applications"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        let found = await Task.detached(priority: .utility) {
            Self.enumerateApps(dirs: appDirs)
        }.value
        let sized = await withTaskGroup(of: IndexedFile.self) { group in
            for app in found {
                group.addTask(priority: .utility) {
                    var a = app
                    a.size = directoryAllocatedSize(URL(fileURLWithPath: app.path))
                    return a
                }
            }
            var out: [IndexedFile] = []
            for await a in group { out.append(a) }
            return out
        }
        apps = sized.sorted { $0.size > $1.size }
        scannedCount = files.count + apps.count

        // Phase 3: analytics off-main, once. Persists for instant next open.
        let snapshotFiles = files
        let snapshotApps = apps
        analysis = await Task.detached(priority: .utility) {
            FileAnalysis.compute(files: snapshotFiles, apps: snapshotApps)
        }.value
        persist()
    }

    nonisolated static func enumerateFiles(roots: [String], maxFiles: Int) -> [[IndexedFile]] {
        /// Dependency/build outputs: thousands of files no human ever browses.
        /// Skipping these keeps counts, sizes and duplicates meaningful.
        let skippedDirs: Set<String> = [
            "node_modules", ".git", ".next", ".turbo", ".nuxt", "dist", "build", "out",
            ".venv", "venv", "__pycache__", "Pods", "Carthage", "target", ".gradle",
            ".idea", ".vscode", ".DS_Store",
        ]
        var batches: [[IndexedFile]] = []
        var batch: [IndexedFile] = []
        var count = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey,
                                      .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey, .creationDateKey]
        outer: for root in roots {
            guard let e = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isSymbolicLink == true { e.skipDescendants(); continue }
                if v.isPackage == true { e.skipDescendants(); continue }
                if v.isDirectory == true {
                    if skippedDirs.contains(url.lastPathComponent) { e.skipDescendants() }
                    continue
                }
                guard v.isRegularFile == true else { continue }
                let path = url.path
                let name = url.lastPathComponent
                let lower = name.lowercased()
                let kind = categorizeFile(name: name, isApp: false)
                batch.append(IndexedFile(
                    name: name, path: path,
                    size: Int64(v.fileSize ?? 0),
                    modified: v.contentModificationDate ?? .distantPast,
                    created: v.creationDate ?? .distantPast,
                    accessed: nil, kind: kind,
                    sourceHost: whereFromsHost(at: path),
                    isScreenshot: kind == .image && (lower.hasPrefix("screenshot") || lower.hasPrefix("cleanshot"))
                ))
                count += 1
                if batch.count >= 500 {
                    batches.append(batch)
                    batch = []
                }
                if count >= maxFiles { break outer }
            }
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    nonisolated static func enumerateApps(dirs: [String]) -> [IndexedFile] {
        var out: [IndexedFile] = []
        let fm = FileManager.default
        for dir in dirs {
            guard let urls = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for u in urls where u.pathExtension == "app" {
                let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                out.append(IndexedFile(
                    name: u.deletingPathExtension().lastPathComponent, path: u.path,
                    size: 0, // filled in phase 2
                    modified: v?.contentModificationDate ?? .distantPast,
                    created: v?.creationDate ?? .distantPast,
                    accessed: lastAccessDate(u.path),
                    kind: .app, sourceHost: nil, isScreenshot: false
                ))
            }
        }
        return out
    }

    // MARK: Derived — all reads hit the cached analysis (O(1)-ish, no I/O)

    var totalBytes: Int64 { analysis.bytesTotal }

    func count(for kind: FileKind) -> Int {
        analysis.counts[kind] ?? 0
    }

    func bytes(for kind: FileKind) -> Int64 {
        analysis.bytesByKind[kind] ?? 0
    }

    func byKind(_ kind: FileKind) -> [IndexedFile] {
        analysis.byKind[kind] ?? []
    }

    func recents(limit: Int = 60) -> [IndexedFile] {
        Array(analysis.recents.prefix(limit))
    }

    func largeFiles(limit: Int = 50) -> [IndexedFile] {
        Array(analysis.large.prefix(limit))
    }

    func largeOver100MB() -> Int { analysis.largeCount }

    func screenshots() -> [IndexedFile] {
        analysis.shots
    }

    func duplicates() -> [DupGroup] {
        analysis.dupGroups
    }

    func forgottenDownloads(days: Int = 30) -> [IndexedFile] {
        analysis.forgotten
    }

    func oldScreenshots(days: Int = 30) -> [IndexedFile] {
        analysis.oldShots
    }

    func unusedApps(days: Int = 90) -> [IndexedFile] {
        analysis.unused
    }

    func downloadSources(limit: Int = 12) -> [DownloadSource] {
        Array(analysis.sources.prefix(limit))
    }

    func search(_ query: String, in scope: [IndexedFile]? = nil, limit: Int = 60) -> [IndexedFile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let pool = scope ?? allEntries
        guard !q.isEmpty else { return Array(pool.sorted { $0.modified > $1.modified }.prefix(limit)) }
        var scored: [(IndexedFile, Int)] = []
        for f in pool {
            if let s = fuzzyScore(query: q, target: f.name) {
                scored.append((f, s + min(f.size > 0 ? 5 : 0, 5)))
            } else if f.ext == q.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
                scored.append((f, 60))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map(\.0)
    }

    /// Volume capacity (live syscall, microseconds — safe per render).
    func volumeInfo() -> (total: Int64, free: Int64) {
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let t = (a[.systemSize] as? NSNumber)?.int64Value,
              let f = (a[.systemFreeSize] as? NSNumber)?.int64Value else { return (0, 0) }
        return (t, f)
    }

    /// True disk usage (total − free). This is the number System Settings shows.
    /// Our category cards only cover indexed folders, so `used − indexed`
    /// is rendered as an explicit "Rest of disk" segment instead of vanishing.
    func volumeUsed() -> Int64 {
        let v = volumeInfo()
        return max(0, v.total - v.free)
    }

    // MARK: Icons (cached; rows must never touch disk per frame)

    func fileIcon(_ f: IndexedFile) -> NSImage {
        let key: NSString = (f.kind == .app ? "app:" + f.path : "ext:" + f.ext) as NSString
        if let hit = iconCache.object(forKey: key) { return hit }
        let img: NSImage
        if f.kind == .image, let thumb = imageThumb(f, pointSize: 64) {
            img = thumb
        } else if f.kind == .app || f.ext.isEmpty == false {
            img = NSWorkspace.shared.icon(forFile: f.path)
            img.size = NSSize(width: 64, height: 64)
        } else {
            img = NSImage(systemSymbolName: f.kind.symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!
        }
        // Thumbnails decode per path — don't poison the shared ext cache.
        if f.kind != .image {
            iconCache.setObject(img, forKey: key)
        }
        return img
    }

    private func imageThumb(_ f: IndexedFile, pointSize: CGFloat) -> NSImage? {
        guard let src = NSImage(contentsOfFile: f.path) else { return nil }
        let aspect = src.size.width / max(src.size.height, 1)
        guard aspect.isFinite, aspect > 0 else { return nil }
        let w = aspect >= 1 ? pointSize : pointSize * aspect
        let h = aspect >= 1 ? pointSize / aspect : pointSize
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        src.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                 from: NSRect(origin: .zero, size: src.size), operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
    }

    // MARK: Headless test hook (--files-scan)

    struct ScanSummary: Codable {
        var files: Int
        var apps: Int
        var bytes: Int64
        var byKind: [String: Int]
        var dupGroups: Int
        var dupExtraBytes: Int64
        var sources: [String]
        var largest: [String]
    }

    func scanSummary() -> ScanSummary {
        var byKind: [String: Int] = [:]
        for k in FileKind.allCases { byKind[k.rawValue] = count(for: k) }
        let dups = duplicates()
        return ScanSummary(
            files: files.count, apps: apps.count, bytes: totalBytes, byKind: byKind,
            dupGroups: dups.count, dupExtraBytes: dups.reduce(0) { $0 + $1.extraBytes },
            sources: downloadSources(limit: 5).map { "\($0.host) (\($0.count))" },
            largest: largeFiles(limit: 5).map { "\($0.name) \(byteString($0.size))" }
        )
    }
}
