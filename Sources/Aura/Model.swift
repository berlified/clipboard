import AppKit
import Combine
import SwiftUI

// MARK: - Item kind

enum ItemKind: Hashable {
    case app(path: String)
    case url(URL)
    case system(SystemAction)
    case calculator(result: String)
    case webSearch(query: String)
    case clipboard(entry: ClipboardEntry)
    case clipboardMode
    case filesMode
    case filesSearch(query: String)
}

enum SystemAction: String, Hashable {
    case lockScreen
    case emptyTrash
    case toggleDarkMode
    case openSettings
    case sleepDisplays
}

// MARK: - Item

struct LauncherItem: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var subtitle: String
    var category: String
    var symbol: String
    var tint: Color
    var keywords: String
    var kind: ItemKind

    // Resolved app icon (if kind == .app)
    var appIcon: NSImage? {
        if case .app(let path) = kind {
            let img = NSWorkspace.shared.icon(forFile: path)
            img.size = NSSize(width: 64, height: 64)
            return img
        }
        return nil
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: LauncherItem, rhs: LauncherItem) -> Bool { lhs.id == rhs.id }
}

// MARK: - Fuzzy matching (subsequence with bonuses)

/// Returns a score (higher = better) or nil if no match.
func fuzzyScore(query: String, target: String) -> Int? {
    let q = query.lowercased()
    let t = target.lowercased()
    if q.isEmpty { return 0 }
    if t.contains(q) {
        // Exact substring gets a big bonus; prefix even bigger.
        var s = 100 + q.count * 10
        if t.hasPrefix(q) { s += 80 }
        // Word-boundary bonus
        if t.contains(" " + q) { s += 40 }
        return s
    }
    // Subsequence match
    var qi = q.startIndex
    var score = 0
    var consecutive = 0
    var lastMatch = -2
    let tChars = Array(t)
    for (i, ch) in tChars.enumerated() {
        if qi < q.endIndex && ch == q[qi] {
            // bonus for start / after space / consecutive
            if i == 0 { score += 30 }
            else if tChars[i - 1] == " " || tChars[i - 1] == "-" || tChars[i - 1] == "/" { score += 20 }
            if i == lastMatch + 1 { consecutive += 1; score += 10 + consecutive * 5 }
            else { consecutive = 0; score += 8 }
            lastMatch = i
            qi = q.index(after: qi)
        }
    }
    guard qi == q.endIndex else { return nil }
    return score
}

func matches(query: String, item: LauncherItem) -> Int? {
    let hay = "\(item.title) \(item.subtitle) \(item.keywords) \(item.category)"
    // Try title first for better scoring, fall back to full haystack
    if let s = fuzzyScore(query: query, target: item.title) { return s + 50 }
    return fuzzyScore(query: query, target: hay)
}

// MARK: - Calculator

/// Very small safe math evaluator. Returns formatted result or nil.
func evaluateMath(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    // Allow only math chars
    let allowed = CharacterSet(charactersIn: "0123456789+-*/().% ^,")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    // Must contain at least one digit and one operator
    guard trimmed.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
    guard trimmed.contains("+") || trimmed.contains("-") || trimmed.contains("*") || trimmed.contains("/") || trimmed.contains("%") || trimmed.contains("^") || trimmed.contains("(") else { return nil }
    // Use NSExpression (supports +-*/() and %). Replace ^ with pow via ** not supported -> use pow function? Keep simple: reject ^ for now, or compute via pow.
    var exprString = trimmed.replacingOccurrences(of: " ", with: "")
    // Handle simple a^b -> pow(a,b)
    if exprString.contains("^") {
        // Only support single ^ like "2^10"
        let parts = exprString.split(separator: "^")
        guard parts.count == 2,
              let base = Double(String(parts[0]).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")),
              let exp = Double(String(parts[1]).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")) else { return nil }
        // If there are parens/operators around, bail to NSExpression path without ^
        if exprString.filter({ $0 == "^" }).count == 1,
           exprString.filter({ $0 == "(" || $0 == ")" }).isEmpty,
           exprString.filter({ $0 == "+" || $0 == "*" || $0 == "/" || $0 == "%" }).isEmpty {
            let v = pow(base, exp)
            return formatNumber(v)
        }
        return nil
    }
    // % as percentage: NSExpression treats % as modulo? Actually format "50%*200" fails. Replace "N%" with "(N/100)".
    // Simple regex-free replacement:
    var out = ""
    var i = exprString.startIndex
    while i < exprString.endIndex {
        let c = exprString[i]
        if c.isNumber || c == "." {
            var j = i
            while j < exprString.endIndex && (exprString[j].isNumber || exprString[j] == ".") {
                j = exprString.index(after: j)
            }
            let num = String(exprString[i..<j])
            if j < exprString.endIndex && exprString[j] == "%" {
                out += "(\(num)/100)"
                i = exprString.index(after: j)
            } else {
                out += num
                i = j
            }
        } else {
            out += String(c)
            i = exprString.index(after: i)
        }
    }
    exprString = out
    let expr = NSExpression(format: exprString)
    guard let value = expr.expressionValue(with: nil, context: nil) as? NSNumber else { return nil }
    let d = value.doubleValue
    guard d.isFinite else { return nil }
    return formatNumber(d)
}

private func formatNumber(_ d: Double) -> String {
    if d.truncatingRemainder(dividingBy: 1) == 0 && abs(d) < 1e15 {
        return String(Int64(d))
    }
    let f = NumberFormatter()
    f.maximumFractionDigits = 6
    f.minimumFractionDigits = 0
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: d)) ?? String(d)
}

// MARK: - Built-in commands

func builtinCommands() -> [LauncherItem] {
    [
        LauncherItem(title: "Open Safari", subtitle: "Application", category: "Apps",
                     symbol: "safari", tint: .blue, keywords: "browser web surf",
                     kind: .app(path: "/Applications/Safari.app")),
        LauncherItem(title: "Open Terminal", subtitle: "Application", category: "Apps",
                     symbol: "terminal", tint: .primary, keywords: "shell console zsh bash",
                     kind: .app(path: "/System/Applications/Utilities/Terminal.app")),
        LauncherItem(title: "Open Notes", subtitle: "Application", category: "Apps",
                     symbol: "note.text", tint: .yellow, keywords: "notes memo write",
                     kind: .app(path: "/System/Applications/Notes.app")),
        LauncherItem(title: "Open Calculator", subtitle: "Application", category: "Apps",
                     symbol: "plus.forwardslash.minus", tint: .orange, keywords: "calc math",
                     kind: .app(path: "/System/Applications/Calculator.app")),
        LauncherItem(title: "System Settings…", subtitle: "Open macOS Settings", category: "System",
                     symbol: "gearshape", tint: .gray, keywords: "settings preferences system",
                     kind: .system(.openSettings)),
        LauncherItem(title: "Toggle Dark Mode", subtitle: "System • Appearance", category: "System",
                     symbol: "moonphase.first.quarter", tint: .purple, keywords: "dark light appearance theme night",
                     kind: .system(.toggleDarkMode)),
        LauncherItem(title: "Lock Screen", subtitle: "System • ⌃⌘Q", category: "System",
                     symbol: "lock", tint: .red, keywords: "lock screen logout secure",
                     kind: .system(.lockScreen)),
        LauncherItem(title: "Sleep Displays", subtitle: "System • Power", category: "System",
                     symbol: "moon.zzz", tint: .indigo, keywords: "sleep display monitor off",
                     kind: .system(.sleepDisplays)),
        LauncherItem(title: "Empty Trash…", subtitle: "System • Finder", category: "System",
                     symbol: "trash", tint: .secondary, keywords: "trash delete empty finder",
                     kind: .system(.emptyTrash)),
        LauncherItem(title: "Search Google for…", subtitle: "Web search", category: "Web",
                     symbol: "magnifyingglass", tint: .blue, keywords: "google search web",
                     kind: .url(URL(string: "https://www.google.com")!)),
        LauncherItem(title: "Open GitHub", subtitle: "https://github.com", category: "Web",
                     symbol: "chevron.left.forwardslash.chevron.right", tint: .primary, keywords: "github code git repo",
                     kind: .url(URL(string: "https://github.com")!)),
        LauncherItem(title: "Open YouTube", subtitle: "https://youtube.com", category: "Web",
                     symbol: "play.rectangle", tint: .red, keywords: "youtube video watch",
                     kind: .url(URL(string: "https://youtube.com")!)),
        LauncherItem(title: "Clipboard History…", subtitle: "Search your copies • type “clip”", category: "Clipboard",
                     symbol: "clipboard", tint: .mint, keywords: "clipboard history copy paste clip",
                     kind: .clipboardMode),
        LauncherItem(title: "Files…", subtitle: "Browse storage & files • type “files pdf” to search", category: "Files",
                     symbol: "folder", tint: .blue, keywords: "files finder folders storage disk documents browse search",
                     kind: .filesMode),
    ]
}

// MARK: - Scan installed apps

func scannedApps(limit: Int = 60) -> [LauncherItem] {
    let fm = FileManager.default
    let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "\(NSHomeDirectory())/Applications"]
    var seen = Set<String>()
    var out: [LauncherItem] = []
    // Seed with builtins so we don't duplicate
    for b in builtinCommands() {
        if case .app(let p) = b.kind { seen.insert(p) }
    }
    for dir in dirs {
        guard let urls = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
        for u in urls where u.pathExtension == "app" {
            let path = u.path
            if seen.contains(path) { continue }
            seen.insert(path)
            let name = u.deletingPathExtension().lastPathComponent
            out.append(LauncherItem(
                title: "Open \(name)",
                subtitle: "Application",
                category: "Apps",
                symbol: "app",
                tint: .accentColor,
                keywords: name.lowercased(),
                kind: .app(path: path)
            ))
            if out.count >= limit { return out }
        }
    }
    return out
}

// MARK: - Execution

@MainActor
func execute(_ item: LauncherItem) {
    switch item.kind {
    case .app(let path):
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    case .url(let url):
        // If this is the generic "Search Google" item, treat title as-is; real query items use .webSearch
        NSWorkspace.shared.open(url)
    case .webSearch(let query):
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://www.google.com/search?q=\(q)") {
            NSWorkspace.shared.open(url)
        }
    case .calculator(let result):
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        // Little confirmation beep-less flash: also open calculator? No — just copy.
    case .system(let action):
        runSystemAction(action)
    case .clipboard(let entry):
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    case .clipboardMode:
        break // handled by LauncherModel.run (enters "clip " mode)
    case .filesMode, .filesSearch:
        break // handled by LauncherModel.run (opens the Files window)
    }
}

private func runSystemAction(_ action: SystemAction) {
    switch action {
    case .openSettings:
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:") ?? URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    case .lockScreen:
        // CGSession -suspend locks the screen
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
        p.arguments = ["-suspend"]
        try? p.run()
    case .sleepDisplays:
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    case .emptyTrash:
        let script = "tell application \"Finder\" to empty trash"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    case .toggleDarkMode:
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}

// MARK: - Model

/// Maps a clipboard entry to a launcher row.
func clipboardItem(_ entry: ClipboardEntry) -> LauncherItem {
    let icon: String
    switch entry.kind {
    case .link: icon = "link"
    case .email: icon = "envelope"
    case .text: icon = "clipboard"
    case .image: icon = "photo"
    case .color: icon = "paintpalette"
    case .code: icon = "chevron.left.forwardslash.chevron.right"
    }
    let kindLabel: String
    switch entry.kind {
    case .link: kindLabel = "Link"
    case .email: kindLabel = "Email"
    case .text: kindLabel = "Text"
    case .image: kindLabel = "Image"
    case .color: kindLabel = "Color"
    case .code: kindLabel = "Code"
    }
    return LauncherItem(
        title: entry.title.isEmpty ? "(empty)" : entry.title,
        subtitle: "Clipboard • \(kindLabel) • \(entry.ageString) • ⏎ to paste",
        category: "Clipboard",
        symbol: icon,
        tint: .mint,
        keywords: String(entry.text.prefix(500)),
        kind: .clipboard(entry: entry)
    )
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectedIndex: Int = 0
    @Published var allItems: [LauncherItem] = []
    @Published var recentTitles: [String] = []

    let clipboard: ClipboardManager
    private var cancellables = Set<AnyCancellable>()

    /// Set by the app delegate: opens the Files window (nil = dashboard).
    var onOpenFiles: ((String?) -> Void)?

    init(clipboard: ClipboardManager = ClipboardManager()) {
        self.clipboard = clipboard
        // Builtins paint instantly; the /Applications walk lands async.
        allItems = builtinCommands()
        Task { await self.loadApps() }
        // Refresh results when clipboard history changes (new copy while open).
        clipboard.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func loadApps() async {
        let found = await Task.detached(priority: .utility) { scannedApps() }.value
        allItems = builtinCommands() + found
    }

    /// Dedicated clipboard mode: query starts with "clip".
    /// `clip` → all history, `clip foo` → filtered.
    var isClipboardMode: Bool {
        query.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("clip")
    }

    var filtered: [LauncherItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        // Calculator takes top slot
        var calcTop: [LauncherItem] = []
        if let result = evaluateMath(q) {
            calcTop = [LauncherItem(
                title: "= \(result)",
                subtitle: "Calculator • ⏎ to copy",
                category: "Calc",
                symbol: "plus.forwardslash.minus",
                tint: .orange,
                keywords: "calc",
                kind: .calculator(result: result)
            )]
        }

        // --- Files mode ("files" / "files <query>") ---
        let lower = q.lowercased()
        if lower == "files" || lower.hasPrefix("files ") {
            let rest = String(q.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            var rows = [LauncherItem(
                title: "Files…",
                subtitle: "Browse storage & files across your Mac",
                category: "Files",
                symbol: "folder",
                tint: .blue,
                keywords: "files",
                kind: .filesMode
            )]
            if !rest.isEmpty {
                rows.append(LauncherItem(
                    title: "Search files for “\(rest)”",
                    subtitle: "Files • names, kinds and folders",
                    category: "Files",
                    symbol: "magnifyingglass",
                    tint: .blue,
                    keywords: "files",
                    kind: .filesSearch(query: rest)
                ))
            }
            return calcTop + rows
        }

        // --- Clipboard mode ("clip ...") ---
        if q.lowercased().hasPrefix("clip") {
            let sub = String(q.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            let found = clipboard.search(sub)
            var rows = found.map(clipboardItem)
            if rows.isEmpty {
                rows = [LauncherItem(
                    title: clipboard.entries.isEmpty ? "Clipboard is empty" : "No clipboard match",
                    subtitle: clipboard.entries.isEmpty
                        ? "Copy something (⌘C) and it will appear here"
                        : "Try a different search",
                    category: "Clipboard",
                    symbol: "clipboard",
                    tint: .mint,
                    keywords: "",
                    kind: .clipboardMode
                )]
            }
            return calcTop + Array(rows.prefix(8))
        }

        guard !q.isEmpty else {
            // Empty query: recents + top apps + newest clips (the daily-driver view).
            var base = allItems
            let recents = recentTitles.compactMap { t in base.first(where: { $0.title == t }) }
            base.removeAll(where: { r in recentTitles.contains(r.title) })
            let apps = Array((recents + base).prefix(5))
            let clips = clipboard.entries.prefix(3).map(clipboardItem)
            return apps + clips + calcTop.reversed()
        }

        // --- Normal search: score apps + clipboard, merge by score ---
        var scored: [(LauncherItem, Int)] = []
        for item in allItems {
            if let s = matches(query: q, item: item) {
                scored.append((item, s))
            }
        }
        for entry in clipboard.entries.prefix(30) {
            let hay = String(entry.text.prefix(500)) + " " + entry.title
            if let s = fuzzyScore(query: q, target: hay) {
                // Slight penalty so apps win ties; clipboard still surfaces on good matches.
                scored.append((clipboardItem(entry), s - 10))
            }
        }
        scored.sort { $0.1 > $1.1 }
        var results = scored.prefix(8).map(\.0)
        // Prepend calculator result if any
        results = calcTop + results
        // Fallback: web search
        if !q.isEmpty {
            results.append(LauncherItem(
                title: "Search Google for “\(q)”",
                subtitle: "Web • google.com",
                category: "Web",
                symbol: "magnifyingglass",
                tint: .blue,
                keywords: "search",
                kind: .webSearch(query: q)
            ))
        }
        return results
    }

    func moveSelection(by delta: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        selectedIndex = (selectedIndex + delta + n) % n
    }

    func resetSelection() { selectedIndex = 0 }

    func markRecent(_ item: LauncherItem) {
        recentTitles.removeAll { $0 == item.title }
        recentTitles.insert(item.title, at: 0)
        recentTitles = Array(recentTitles.prefix(5))
    }

    /// Executes an item. Returns `false` when the panel should stay open
    /// (clipboard-mode entry), `true` when it should hide.
    @discardableResult
    func run(_ item: LauncherItem) -> Bool {
        switch item.kind {
        case .clipboardMode:
            // "Clipboard History…" row or empty-state row → enter clip mode.
            if !isClipboardMode {
                query = "clip "
            }
            resetSelection()
            return false
        case .clipboard(let entry):
            markRecent(item)
            clipboard.copyAndPaste(entry)
            query = ""
            resetSelection()
            return true
        case .filesMode:
            markRecent(item)
            onOpenFiles?(nil)
            query = ""
            resetSelection()
            return true
        case .filesSearch(let fq):
            markRecent(item)
            onOpenFiles?(fq)
            query = ""
            resetSelection()
            return true
        default:
            markRecent(item)
            execute(item)
            query = ""
            resetSelection()
            return true
        }
    }
}
