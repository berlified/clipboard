import AppKit
import Combine

// MARK: - Clipboard entry

enum ClipboardType: String, Codable {
    case text, link, email
}

struct ClipboardEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var text: String
    var date: Date
    var pinned: Bool

    var type: ClipboardType {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return .link }
        if t.contains("@") && t.contains(".") && !t.contains(" ") && t.count < 120 { return .email }
        return .text
    }

    /// Single-line preview for the row title.
    var preview: String {
        let single = text
            .split(whereSeparator: \.isNewline)
            .first.map(String.init) ?? text
        let flat = single.trimmingCharacters(in: .whitespaces)
        if flat.count <= 80 { return flat }
        return String(flat.prefix(80)) + "…"
    }

    var ageString: String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}

// MARK: - Manager: polls NSPasteboard, persists locally, searches

@MainActor
final class ClipboardManager: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []

    private var lastChangeCount: Int
    private var timer: Timer?
    private let saveURL: URL
    private let maxEntries = 50

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
        // Force first poll to inspect the current clipboard contents.
        lastChangeCount = -1
        load()
        // Capture whatever is already on the clipboard at launch.
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // Note: timer lives for the app lifetime (manager is owned by LauncherModel,
    // which lives as long as the panel). No explicit invalidate needed.

    // MARK: Poll

    func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // Skip password-manager copies.
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier, ignoredBundleIDs.contains(bid) {
            return
        }

        guard let raw = pb.string(forType: .string) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 20_000 else { return }

        // Already the newest? Don't duplicate.
        if entries.first?.text == text { return }

        // De-dupe: move existing copy to top instead of duplicating.
        entries.removeAll { $0.text == text }
        entries.insert(ClipboardEntry(id: UUID(), text: text, date: Date(), pinned: false), at: 0)
        trim()
        save()
    }

    // MARK: Explicit saves ("Save to Aura" bubble, Samsung-style pins)

    /// Explicitly saves text (e.g. from the selection bubble).
    /// Unlike passive Cmd+C capture, explicit saves are pinned so they survive Clear.
    func saveText(_ raw: String, pinned: Bool = true) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 20_000 else { return }
        // De-dupe: refresh existing entry instead of duplicating.
        if let i = entries.firstIndex(where: { $0.text == text }) {
            entries[i].date = Date()
            if pinned { entries[i].pinned = true }
            // Pinned float to top.
            entries.sort { ($0.pinned ? 0 : 1, $0.date) < ($1.pinned ? 0 : 1, $1.date) }
            save()
            return
        }
        entries.insert(ClipboardEntry(id: UUID(), text: text, date: Date(), pinned: pinned), at: 0)
        entries.sort { ($0.pinned ? 0 : 1, $0.date) < ($1.pinned ? 0 : 1, $1.date) }
        trim()
        save()
    }

    // MARK: Search

    func search(_ query: String, limit: Int = 8) -> [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(entries.prefix(limit)) }
        var scored: [(ClipboardEntry, Int)] = []
        for e in entries {
            // Score against first 500 chars to keep it fast.
            let hay = String(e.text.prefix(500))
            if let s = fuzzyScore(query: q, target: hay) {
                scored.append((e, s))
            } else if let s = fuzzyScore(query: q, target: e.preview) {
                scored.append((e, s))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map(\.0)
    }

    // MARK: Actions

    /// Copy back to clipboard and try to auto-paste into the previous app.
    /// Auto-paste uses CGEvent (needs Accessibility); if not granted it
    /// silently falls back to copy-only so the user can ⌘V manually.
    func copyAndPaste(_ entry: ClipboardEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
        lastChangeCount = pb.changeCount

        // Recency bump.
        entries.removeAll { $0.id == entry.id }
        var bumped = entry
        bumped.date = Date()
        entries.insert(bumped, at: 0)
        trim()
        save()

        // Give the panel time to hide, then synthesize ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            let source = CGEventSource(stateID: .hidSystemState)
            // Virtual key 0x09 = "v".
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            down?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    func togglePin(_ entry: ClipboardEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].pinned.toggle()
        // Pinned items float to top.
        entries.sort { ($0.pinned ? 0 : 1, $0.date) < ($1.pinned ? 0 : 1, $1.date) }
        // Re-sort: pinned first (newest first), then rest newest first.
        save()
    }

    func delete(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clearAll() {
        entries.removeAll { !$0.pinned }
        save()
    }

    // MARK: Persistence (local JSON, private by design)

    private func trim() {
        // Keep pinned + newest, cap at maxEntries.
        if entries.count > maxEntries {
            let pinned = entries.filter(\.pinned)
            let rest = entries.filter { !$0.pinned }.prefix(max(0, maxEntries - pinned.count))
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
        } catch {
            entries = []
        }
    }
}
