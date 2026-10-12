import AppKit
import Combine

// MARK: - Kind

enum ClipKind: String, Codable {
    case text, link, email, color, image, code
}

// MARK: - Color detection (hex / rgb / hsl, like the ClipBook color rows)

struct DetectedColor {
    var red: Double; var green: Double; var blue: Double // 0...1

    var hex: String {
        String(format: "#%02X%02X%02X",
               Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    var rgb: String {
        "rgb(\(Int((red * 255).rounded())) \(Int((green * 255).rounded())) \(Int((blue * 255).rounded())))"
    }
    var hsl: String {
        let (h, s, l) = toHSL()
        return String(format: "hsl(%d %d%% %d%%)", Int(h.rounded()), Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    private func toHSL() -> (Double, Double, Double) {
        let mx = max(red, green, blue), mn = min(red, green, blue)
        var h = 0.0, s = 0.0
        let l = (mx + mn) / 2
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            if mx == red { h = (green - blue) / d + (green < blue ? 6 : 0) }
            else if mx == green { h = (blue - red) / d + 2 }
            else { h = (red - green) / d + 4 }
            h *= 60
        }
        return (h, s, l)
    }
}

/// Returns non-nil when the whole string is a single color value.
func detectColor(_ raw: String) -> DetectedColor? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // #rgb / #rrggbb
    if s.hasPrefix("#") {
        let hex = String(s.dropFirst())
        let chars = Array(hex)
        func nibble(_ c: Character) -> UInt8? {
            guard let v = c.hexDigitValue else { return nil }
            return UInt8(v)
        }
        if chars.count == 3, let r = nibble(chars[0]), let g = nibble(chars[1]), let b = nibble(chars[2]) {
            return DetectedColor(red: Double(r * 17) / 255, green: Double(g * 17) / 255, blue: Double(b * 17) / 255)
        }
        if chars.count == 6, let v = UInt32(hex, radix: 16) {
            return DetectedColor(red: Double((v >> 16) & 0xFF) / 255,
                                 green: Double((v >> 8) & 0xFF) / 255,
                                 blue: Double(v & 0xFF) / 255)
        }
        return nil
    }
    // rgb(...) / rgba(...) — comma, space, or slash-alpha syntax; first 3 numbers win
    for prefix in ["rgba(", "rgb("] where s.hasPrefix(prefix) && s.hasSuffix(")") {
        let inner = s.dropFirst(prefix.count).dropLast()
        let nums = inner.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        return DetectedColor(red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255)
    }
    // hsl(...) / hsla(...) — h deg, s/l percents
    for prefix in ["hsla(", "hsl("] where s.hasPrefix(prefix) && s.hasSuffix(")") {
        let inner = s.dropFirst(prefix.count).dropLast()
        let nums = inner.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        let (r, g, b) = hslToRGB(h: nums[0], s: nums[1] / 100, l: nums[2] / 100)
        return DetectedColor(red: r, green: g, blue: b)
    }
    return nil
}

private func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
    if s == 0 { return (l, l, l) }
    let hh = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    func ch(_ t: Double) -> Double {
        var t = t
        if t < 0 { t += 1 }; if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 0.5 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
    return (ch(hh + 1.0 / 3), ch(hh), ch(hh - 1.0 / 3))
}

func detectKind(_ text: String) -> ClipKind {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if detectColor(t) != nil { return .color }
    if t.hasPrefix("http://") || t.hasPrefix("https://") { return .link }
    if t.contains("@") && t.contains(".") && !t.contains(" ") && t.count < 120 { return .email }
    if detectCode(t) { return .code }
    return .text
}

/// Conservative code heuristic: needs ≥4 signal points so prose with
/// parens or apostrophes never misfires.
func detectCode(_ raw: String) -> Bool {
    guard raw.count >= 12, raw.count < 20_000 else { return false }
    var score = 0
    if raw.contains("{") && raw.contains("}") { score += 2 }
    if raw.contains(";") { score += 1 }
    let lower = raw.lowercased()
    let keywords = ["func ", "def ", "class ", "import ", "const ", "let ", "var ",
                    "=>", "->", "#include", "return ", "public ", "private ",
                    "fn ", "package ", "echo ", "select ", "struct ", "enum "]
    if keywords.contains(where: lower.contains) { score += 2 }
    if raw.range(of: "[A-Za-z_][A-Za-z0-9_]*\\([^)]*\\)", options: .regularExpression) != nil {
        score += 2
    }
    let lines = raw.components(separatedBy: .newlines)
    if lines.count >= 2 && lines.contains(where: { $0.hasPrefix(" ") || $0.hasPrefix("\t") }) {
        score += 1
    }
    return score >= 4
}

func djb2(_ data: Data) -> UInt64 {
    var h: UInt64 = 5381
    for b in data { h = ((h << 5) &+ h) &+ UInt64(b) }
    return h
}

// MARK: - Pinboard

/// A named collection (Paste-style pinboard tab). Entries can live on any
/// number of boards *and* stay in Clipboard history at the same time.
struct Board: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    /// Palette index into `Board.palette`.
    var colorIndex: Int

    /// Board dot colors.
    static let palette: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
        "#00C7BE", "#0A84FF", "#BF5AF2", "#FF375F",
    ]

    var hex: String { Self.palette[colorIndex % Self.palette.count] }
}

// MARK: - Entry

struct ClipboardEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var text: String
    var kind: ClipKind
    var date: Date        // last copy
    var firstDate: Date   // first copy
    var copies: Int
    var pinned: Bool      // = ★ favorite
    var sourceApp: String
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var imageBytes: Int?
    var imageHash: UInt64?
    /// Boards this entry is filed under (empty = Clipboard history only).
    var boardIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case id, text, kind, date, firstDate, copies, pinned, sourceApp
        case imageFile, imageWidth, imageHeight, imageBytes, imageHash
        case boardIDs
    }

    init(id: UUID = UUID(), text: String, kind: ClipKind? = nil, date: Date = Date(),
         firstDate: Date? = nil, copies: Int = 1, pinned: Bool = false,
         sourceApp: String = "Unknown", imageFile: String? = nil,
         imageWidth: Int? = nil, imageHeight: Int? = nil,
         imageBytes: Int? = nil, imageHash: UInt64? = nil,
         boardIDs: [UUID] = []) {
        self.id = id
        self.text = text
        self.kind = kind ?? detectKind(text)
        self.date = date
        self.firstDate = firstDate ?? date
        self.copies = copies
        self.pinned = pinned
        self.sourceApp = sourceApp
        self.imageFile = imageFile
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageBytes = imageBytes
        self.imageHash = imageHash
        self.boardIDs = boardIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        // Legacy entries: re-derive text kinds (adds code detection to old clips).
        if let k = try c.decodeIfPresent(ClipKind.self, forKey: .kind), k != .text {
            kind = k
        } else {
            kind = text.isEmpty ? .text : detectKind(text)
        }
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        firstDate = try c.decodeIfPresent(Date.self, forKey: .firstDate) ?? date
        copies = try c.decodeIfPresent(Int.self, forKey: .copies) ?? 1
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp) ?? "Unknown"
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try c.decodeIfPresent(Int.self, forKey: .imageHeight)
        imageBytes = try c.decodeIfPresent(Int.self, forKey: .imageBytes)
        imageHash = try c.decodeIfPresent(UInt64.self, forKey: .imageHash)
        boardIDs = try c.decodeIfPresent([UUID].self, forKey: .boardIDs) ?? []
    }

    /// Single-line list title.
    var title: String {
        if kind == .image {
            if let w = imageWidth, let h = imageHeight { return "Image (\(w)x\(h))" }
            return "Image"
        }
        let single = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let flat = single.trimmingCharacters(in: .whitespaces)
        if flat.isEmpty { return "(empty)" }
        return flat.count <= 80 ? flat : String(flat.prefix(80)) + "…"
    }

    var preview: String { title }

    var detectedColor: DetectedColor? {
        kind == .color ? detectColor(text) : nil
    }

    var ageString: String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var dateString: String { Self.dateFormatter.string(from: date) }
    var firstDateString: String { Self.dateFormatter.string(from: firstDate) }
}

// MARK: - Manager

@MainActor
final class ClipboardManager: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var boards: [Board] = []
    @Published var paused: Bool = false

    private var lastChangeCount: Int
    private var timer: Timer?
    private let saveURL: URL
    private let boardsURL: URL
    private let imagesDir: URL
    private let maxEntries = 100

    /// Disk-decode caches: rows render from these, never the filesystem.
    /// Hard limits — unbounded image caches are how clipboard apps balloon.
    private let fullImageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 40
        return c
    }()
    private let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        return c
    }()
    private let appIconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 120
        return c
    }()

    /// Bundle IDs we never record from (password managers etc.)
    private let ignoredBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.lastpass.lastpass",
        "com.dashlane.dashlane",
    ]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        saveURL = base.appendingPathComponent("Aura/clipboard.json", isDirectory: false)
        boardsURL = base.appendingPathComponent("Aura/boards.json", isDirectory: false)
        imagesDir = base.appendingPathComponent("Aura/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        // Force first poll to inspect the current clipboard contents.
        lastChangeCount = -1
        load()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // Note: timer lives for the app lifetime (owned by AppDelegate). No invalidate needed.

    var supportDir: URL { saveURL.deletingLastPathComponent() }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let f = entry.imageFile else { return nil }
        return imagesDir.appendingPathComponent(f)
    }

    func loadImage(_ entry: ClipboardEntry) -> NSImage? {
        cachedFullImage(entry)
    }

    /// Full image, decoded once then cached.
    func cachedFullImage(_ entry: ClipboardEntry) -> NSImage? {
        guard let f = entry.imageFile else { return nil }
        let key = f as NSString
        if let hit = fullImageCache.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOf: imagesDir.appendingPathComponent(f)) else { return nil }
        fullImageCache.setObject(img, forKey: key)
        return img
    }

    /// Small thumbnail for rails/rows/cards. Decoded + downscaled once.
    func thumbnail(_ entry: ClipboardEntry, pointSize: CGFloat = 96) -> NSImage? {
        guard entry.kind == .image, let f = entry.imageFile else { return nil }
        let key = "\(f)@\(Int(pointSize))" as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }
        guard let full = cachedFullImage(entry) else { return nil }
        let aspect = full.size.width / max(full.size.height, 1)
        let w = aspect >= 1 ? pointSize : pointSize * aspect
        let h = aspect >= 1 ? pointSize / aspect : pointSize
        let thumb = NSImage(size: NSSize(width: w, height: h))
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        full.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                  from: NSRect(origin: .zero, size: full.size),
                  operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        thumbCache.setObject(thumb, forKey: key)
        return thumb
    }

    /// Icon for the source app, best-effort (avoids deprecated lookup APIs).
    /// Cached: the rail renders up to 7 of these per frame.
    func appIcon(for name: String) -> NSImage? {
        cachedAppIcon(for: name)
    }

    func cachedAppIcon(for name: String) -> NSImage? {
        guard name != "Unknown" else { return nil }
        let key = name as NSString
        if let hit = appIconCache.object(forKey: key) { return hit }
        // 1. Running apps: exact localizedName → real bundle icon.
        //    This catches everything in /Applications, ~/Applications,
        //    Homebrew casks, and oddly-named bundles path guessing misses.
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let url = running.bundleURL {
            let img = NSWorkspace.shared.icon(forFile: url.path)
            img.size = NSSize(width: 96, height: 96)
            appIconCache.setObject(img, forKey: key)
            return img
        }
        // 2. Well-known path guesses.
        let candidates = [
            "/Applications/\(name).app",
            "/System/Applications/\(name).app",
            "\(NSHomeDirectory())/Applications/\(name).app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let img = NSWorkspace.shared.icon(forFile: path)
            img.size = NSSize(width: 96, height: 96)
            appIconCache.setObject(img, forKey: key)
            return img
        }
        return nil
    }

    // MARK: Poll (Samsung-style auto-capture)

    func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard !paused else { return }

        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier, ignoredBundleIDs.contains(bid) {
            return
        }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

        // Images win when image data is present (screenshots, copied photos).
        // Conversion happens off-main; poll() itself never blocks.
        if let img = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            captureImageAsync(img, sourceApp: appName)
            return
        }

        guard let raw = pb.string(forType: .string) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 20_000 else { return }
        insertOrBump(text: text, kind: nil, sourceApp: appName, pinned: false)
    }

    /// PNG conversion + disk write run off-main; only the insert touches state.
    private func captureImageAsync(_ img: NSImage, sourceApp: String) {
        guard let tiff = img.tiffRepresentation else { return }
        let dir = imagesDir
        Task {
            let result = await Task.detached(priority: .utility) {
                () -> (name: String, w: Int, h: Int, bytes: Int, hash: UInt64)? in
                guard let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]),
                      png.count < 25_000_000 else { return nil }
                let name = "\(UUID().uuidString).png"
                do {
                    try png.write(to: dir.appendingPathComponent(name), options: .atomic)
                } catch { return nil }
                return (name, rep.pixelsWide, rep.pixelsHigh, png.count, djb2(png))
            }.value
            guard let r = result else { return }
            self.insertImage(name: r.name, w: r.w, h: r.h, bytes: r.bytes, hash: r.hash, sourceApp: sourceApp)
        }
    }

    private func insertImage(name: String, w: Int, h: Int, bytes: Int, hash: UInt64, sourceApp: String) {
        // Same image re-copied → bump copies, don't duplicate.
        if let i = entries.firstIndex(where: { $0.kind == .image && $0.imageHash == hash }) {
            entries[i].copies += 1
            entries[i].date = Date()
            sortEntries()
            save()
            return
        }
        entries.insert(ClipboardEntry(
            text: "", kind: .image, sourceApp: sourceApp,
            imageFile: name, imageWidth: w, imageHeight: h,
            imageBytes: bytes, imageHash: hash
        ), at: 0)
        trim()
        save()
    }

    // MARK: Explicit saves ("Save to Aura" bubble)

    /// Explicit saves are pinned so they survive Clear.
    func saveText(_ raw: String, pinned: Bool = true) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 20_000 else { return }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        insertOrBump(text: text, kind: nil, sourceApp: appName, pinned: pinned)
    }

    /// Shared insert: de-dupe by text, bump copies + recency, pin on demand.
    private func insertOrBump(text: String, kind: ClipKind?, sourceApp: String, pinned: Bool) {
        if let i = entries.firstIndex(where: { $0.kind != .image && $0.text == text }) {
            entries[i].copies += 1
            entries[i].date = Date()
            if entries[i].sourceApp == "Unknown" { entries[i].sourceApp = sourceApp }
            if pinned { entries[i].pinned = true }
            sortEntries()
            save()
            return
        }
        entries.insert(ClipboardEntry(text: text, kind: kind, pinned: pinned, sourceApp: sourceApp), at: 0)
        sortEntries()
        trim()
        save()
    }

    private func sortEntries() {
        // Pinned first (newest first), then rest newest first.
        entries.sort { ($0.pinned ? 0 : 1, $0.date) < ($1.pinned ? 0 : 1, $1.date) }
    }

    // MARK: Search

    func search(_ query: String, limit: Int = 50) -> [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(entries.prefix(limit)) }
        // "image" matches image entries (no OCR — title match).
        var scored: [(ClipboardEntry, Int)] = []
        for e in entries {
            if e.kind == .image {
                if "image".contains(q.lowercased()) {
                    scored.append((e, 50))
                }
                continue
            }
            let hay = String(e.text.prefix(500))
            if let s = fuzzyScore(query: q, target: hay) {
                scored.append((e, s))
            } else if let s = fuzzyScore(query: q, target: e.title) {
                scored.append((e, s))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map(\.0)
    }

    // MARK: Actions

    /// Copy back + auto-paste into the previous app (CGEvent ⌘V needs Accessibility;
    /// falls back to copy-only so the user can ⌘V manually).
    func copyAndPaste(_ entry: ClipboardEntry) {
        writeToPasteboard(entry)
        bump(entry)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            down?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Copy to clipboard without pasting (toolbar Copy button).
    func copyOnly(_ entry: ClipboardEntry) {
        writeToPasteboard(entry)
        bump(entry)
    }

    private func writeToPasteboard(_ entry: ClipboardEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if entry.kind == .image, let img = cachedFullImage(entry) {
            pb.writeObjects([img])
        } else {
            pb.setString(entry.text, forType: .string)
        }
        lastChangeCount = pb.changeCount
    }

    private func bump(_ entry: ClipboardEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].copies += 1
        entries[i].date = Date()
        sortEntries()
        save()
    }

    func togglePin(_ entry: ClipboardEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].pinned.toggle()
        sortEntries()
        save()
    }

    func delete(_ entry: ClipboardEntry) {
        evictImage(entry)
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clearUnpinned() {
        for e in entries where !e.pinned { evictImage(e) }
        entries.removeAll { !$0.pinned }
        save()
    }

    private func evictImage(_ entry: ClipboardEntry) {
        if let f = entry.imageFile {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(f))
            fullImageCache.removeObject(forKey: f as NSString)
        }
    }

    // MARK: Pinboards

    /// Entries for a tab: nil = Clipboard (everything), otherwise board members.
    func entries(for board: Board?) -> [ClipboardEntry] {
        guard let board else { return entries }
        return entries.filter { $0.boardIDs.contains(board.id) }
    }

    func addBoard(name: String, colorIndex: Int) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        boards.append(Board(id: UUID(), name: String(name.prefix(24)), colorIndex: colorIndex))
        saveBoards()
    }

    func deleteBoard(_ board: Board) {
        boards.removeAll { $0.id == board.id }
        for i in entries.indices {
            entries[i].boardIDs.removeAll { $0 == board.id }
        }
        saveBoards()
        save()
    }

    func toggleBoard(_ entry: ClipboardEntry, _ board: Board) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        if entries[i].boardIDs.contains(board.id) {
            entries[i].boardIDs.removeAll { $0 == board.id }
        } else {
            entries[i].boardIDs.append(board.id)
        }
        save()
    }

    func boardNames(for entry: ClipboardEntry) -> [String] {
        boards.filter { entry.boardIDs.contains($0.id) }.map(\.name)
    }

    // MARK: Persistence (local JSON, private by design)

    private func trim() {
        if entries.count > maxEntries {
            let pinned = entries.filter(\.pinned)
            let rest = entries.filter { !$0.pinned }.prefix(max(0, maxEntries - pinned.count))
            // Drop image files for evicted entries.
            let keep = Set((pinned + rest).map(\.id))
            for e in entries where !keep.contains(e.id) { evictImage(e) }
            entries = pinned + rest
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            // Non-fatal; history just won't survive relaunch.
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: saveURL)
            entries = try JSONDecoder().decode([ClipboardEntry].self, from: data)
            sortEntries()
        } catch {
            entries = []
        }
        do {
            let data = try Data(contentsOf: boardsURL)
            boards = try JSONDecoder().decode([Board].self, from: data)
        } catch {
            // First launch: seed Paste-style starter boards.
            boards = [
                Board(id: UUID(), name: "Useful Links", colorIndex: 0),
                Board(id: UUID(), name: "Important Notes", colorIndex: 2),
                Board(id: UUID(), name: "Code Snippets", colorIndex: 5),
            ]
            saveBoards()
        }
    }

    private func saveBoards() {
        do {
            try FileManager.default.createDirectory(at: boardsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(boards)
            try data.write(to: boardsURL, options: .atomic)
        } catch {
            // Non-fatal.
        }
    }
}
