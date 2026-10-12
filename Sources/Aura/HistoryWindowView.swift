import AppKit
import SwiftUI

// MARK: - ClipBook-style two-pane history window (dark, always)

/// Left: searchable icon list. Right: rich preview + metadata.
/// Bottom: live status bar (Paste to <app>, copy time).
struct HistoryWindowView: View {
    @ObservedObject var clipboard: ClipboardManager
    @State private var query: String = ""
    @State private var selectedID: UUID?
    @State private var hoverID: UUID?
    @State private var favoritesOnly: Bool = false
    @State private var lastApp: String = "Finder"
    @State private var axTrusted: Bool = AccessibilityPermission.isTrusted()
    @FocusState private var searchFocused: Bool

    var onPaste: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    private var base: [ClipboardEntry] {
        let found = clipboard.search(query, limit: 100)
        return favoritesOnly ? found.filter(\.pinned) : found
    }

    private var selected: ClipboardEntry? {
        if let id = selectedID, let hit = base.first(where: { $0.id == id }) { return hit }
        return base.first
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                listPane.frame(width: 400)
                Divider().background(.white.opacity(0.08))
                detailPane.frame(maxWidth: .infinity)
            }
            .frame(height: 502)
            statusBar
        }
        .frame(width: 940, height: 620)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 50, x: 0, y: 24)
        .preferredColorScheme(.dark)
        .onAppear {
            searchFocused = true
            axTrusted = AccessibilityPermission.isTrusted()
            refreshApp()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            refreshApp()
            axTrusted = AccessibilityPermission.isTrusted()
        }
        .onChange(of: query) { _, _ in
            if let s = selected, base.contains(where: { $0.id == s.id }) {
                selectedID = s.id
            } else {
                selectedID = base.first?.id
            }
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { pasteSelected(); return .handled }
        .onKeyPress(.escape) { onEscape?(); return .handled }
        .onKeyPress(keys: [.init("c")], phases: .down, action: { _ in copySelected(); return .handled })
    }

    private func refreshApp() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.localizedName != "Aura",
           let name = front.localizedName {
            lastApp = name
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $query, prompt: Text("Type to search…").foregroundColor(.secondary))
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { pasteSelected() }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            toolButton(icon: "doc.on.clipboard", tip: "Paste to \(lastApp) (⏎)") { pasteSelected() }
            toolButton(icon: "doc.on.doc", tip: "Copy to clipboard") { copySelected() }
            toolButton(icon: clipboard.paused ? "play.fill" : "pause.fill",
                       tip: clipboard.paused ? "Resume capturing" : "Pause capturing") {
                clipboard.paused.toggle()
            }
            Divider().frame(height: 18).opacity(0.5)
            Button {
                favoritesOnly.toggle()
            } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(favoritesOnly ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show favorites only")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.white.opacity(0.03))
    }

    private func toolButton(icon: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    // MARK: - List pane

    private var listPane: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(base) { entry in
                        HistoryRow(
                            entry: entry,
                            thumbnail: entry.kind == .image ? clipboard.loadImage(entry) : nil,
                            selected: entry.id == selected?.id,
                            showStar: entry.pinned || entry.id == selected?.id || entry.id == hoverID,
                            onSelect: { selectedID = entry.id },
                            onStar: { clipboard.togglePin(entry) }
                        )
                        .id(entry.id)
                        .onHover { if $0 { hoverID = entry.id } else if hoverID == entry.id { hoverID = nil } }
                    }
                    if base.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: clipboard.entries.isEmpty ? "clipboard" : "magnifyingglass")
                                .font(.system(size: 26)).foregroundStyle(.secondary)
                            Text(clipboard.entries.isEmpty ? "Nothing saved yet" : "No matches")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            Text(clipboard.entries.isEmpty
                                 ? "Copy with ⌘C — it lands here.\nSelect text anywhere → Save to Aura."
                                 : "Try a different search.")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                }
                .padding(8)
            }
            .onChange(of: selected?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        Group {
            if let entry = selected {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        preview(for: entry)
                        Divider().opacity(0.5)
                        metadata(for: entry)
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "note.text").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("Select an item").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.white.opacity(0.02))
    }

    @ViewBuilder
    private func preview(for entry: ClipboardEntry) -> some View {
        switch entry.kind {
        case .image:
            if let img = clipboard.loadImage(entry) {
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12), lineWidth: 1) }
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                Text("Images you copy are remembered, previewed here, and paste straight into the active app.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text("Image file missing").foregroundStyle(.secondary)
            }
        case .color:
            if let c = entry.detectedColor {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: c.red, green: c.green, blue: c.blue))
                    .frame(height: 80)
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.2), lineWidth: 1) }
                copyRow(label: "HEX", value: c.hex)
                copyRow(label: "RGB", value: c.rgb)
                copyRow(label: "HSL", value: c.hsl)
            } else {
                Text(entry.text).font(.system(size: 13)).textSelection(.enabled)
            }
        case .link:
            Text(entry.text)
                .font(.system(size: 13)).foregroundStyle(.blue)
                .textSelection(.enabled)
            Button("Open link") {
                if let url = URL(string: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link).font(.system(size: 13, weight: .semibold))
        default:
            Text(entry.text.isEmpty ? "(empty)" : entry.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Copy \(label)")
        }
    }

    private func metadata(for entry: ClipboardEntry) -> some View {
        VStack(spacing: 7) {
            metaRow(label: "Application", value: entry.sourceApp,
                    icon: clipboard.appIcon(for: entry.sourceApp))
            metaRow(label: "Type", value: kindLabel(entry.kind))
            switch entry.kind {
            case .image:
                if let w = entry.imageWidth, let h = entry.imageHeight {
                    metaRow(label: "Image dimensions", value: "\(w)x\(h)")
                }
                if let b = entry.imageBytes {
                    metaRow(label: "Image size", value: byteString(b))
                }
                metaRow(label: "Copy time", value: entry.dateString)
            case .text, .link, .email:
                metaRow(label: "Number of copies", value: "\(entry.copies)")
                metaRow(label: "First copy time", value: entry.firstDateString)
                metaRow(label: "Last copy time", value: entry.dateString)
            case .color:
                metaRow(label: "Copy time", value: entry.dateString)
            }
        }
    }

    private func metaRow(label: String, value: String, icon: NSImage? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            Text(value)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            statusHint(key: "↑↓", label: "Navigate")
            Button { pasteSelected() } label: {
                HStack(spacing: 6) {
                    Text("⏎").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text("Paste to \(lastApp)").font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                kbd("⌘K")
                Text("Actions").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !axTrusted {
                Button("Enable select-to-save…") { AccessibilityPermission.prompt() }
                    .buttonStyle(.link).font(.system(size: 12))
            } else if clipboard.paused {
                Text("Paused").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            } else if let s = selected {
                Text(s.dateString).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if !clipboard.entries.isEmpty {
                Button("Clear") { clipboard.clearUnpinned() }
                    .buttonStyle(.link).font(.system(size: 12)).foregroundStyle(.secondary)
                    .help("Delete everything except ★ favorites")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.white.opacity(0.03))
    }

    private func statusHint(key: String, label: String) -> some View {
        HStack(spacing: 6) {
            kbd(key)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func kbd(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        guard !base.isEmpty else { return }
        let cur = base.firstIndex(where: { $0.id == selected?.id }) ?? 0
        let next = (cur + delta + base.count) % base.count
        selectedID = base[next].id
    }

    private func pasteSelected() {
        guard let s = selected else { return }
        clipboard.copyAndPaste(s)
        query = ""
        onPaste?()
    }

    private func copySelected() {
        guard let s = selected else { return }
        clipboard.copyOnly(s)
    }

    private func kindLabel(_ k: ClipKind) -> String {
        switch k {
        case .text: return "Text"
        case .link: return "Link"
        case .email: return "Email"
        case .color: return "Color"
        case .image: return "Image"
        }
    }

    private func byteString(_ b: Int) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        return String(format: "%.2f MB", Double(b) / (1024 * 1024))
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let entry: ClipboardEntry
    let thumbnail: NSImage?
    let selected: Bool
    let showStar: Bool
    var onSelect: () -> Void
    var onStar: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            rowIcon
            Text(entry.title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showStar {
                Button(action: onStar) {
                    Image(systemName: entry.pinned ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(entry.pinned ? Color.yellow : Color.gray.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(entry.pinned ? "Unfavorite" : "Favorite")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? .white.opacity(0.10) : .clear)
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { onSelect() }
    }

    @ViewBuilder
    private var rowIcon: some View {
        switch entry.kind {
        case .image:
            if let t = thumbnail {
                Image(nsImage: t)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
        case .color:
            if let c = entry.detectedColor {
                Circle()
                    .fill(Color(red: c.red, green: c.green, blue: c.blue))
                    .frame(width: 14, height: 14)
                    .overlay { Circle().stroke(.white.opacity(0.3), lineWidth: 1) }
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
        case .link:
            Image(systemName: "link").font(.system(size: 13)).foregroundStyle(.blue)
                .frame(width: 26, height: 26)
        case .email:
            Image(systemName: "envelope").font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        case .text:
            Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
    }
}
