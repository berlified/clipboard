import AppKit
import SwiftUI

// MARK: Tile gradients (clean iOS-style)

func tileColors(_ kind: ClipKind) -> [Color] {
    switch kind {
    case .text: return [Color(red: 0.04, green: 0.52, blue: 1.0), Color(red: 0.37, green: 0.36, blue: 0.9)]
    case .link: return [Color(red: 0.2, green: 0.78, blue: 0.35), Color(red: 0.0, green: 0.78, blue: 0.74)]
    case .email: return [Color(red: 0.39, green: 0.82, blue: 1.0), Color(red: 0.04, green: 0.52, blue: 1.0)]
    case .image: return [.clear, .clear]
    case .color: return [.clear, .clear]
    }
}

func tileSymbol(_ kind: ClipKind) -> String {
    switch kind {
    case .text: return "doc.text.fill"
    case .link: return "link"
    case .email: return "envelope.fill"
    case .image: return "photo.fill"
    case .color: return "paintpalette.fill"
    }
}

// MARK: - Rail (a real Dock, pinned left)

struct DockRailView: View {
    @ObservedObject var clipboard: ClipboardManager
    // Row index, -1 logo, -2 search, -3 trash, nil none.
    @State private var hovered: Int?
    var onLogo: () -> Void = {}
    var onSearch: () -> Void = {}
    var onClear: () -> Void = {}
    var onPaste: (ClipboardEntry) -> Void = { _ in }
    var onPin: (ClipboardEntry) -> Void = { _ in }
    var onDelete: (ClipboardEntry) -> Void = { _ in }
    var onCopy: (ClipboardEntry) -> Void = { _ in }
    var onToggleBoard: (ClipboardEntry, Board) -> Void = { _, _ in }

    private var items: [ClipboardEntry] { Array(clipboard.entries.prefix(7)) }
    private var overflow: Int { max(0, clipboard.entries.count - 7) }

    /// Dock falloff: hovered + two neighbors swell (visual only — no layout
    /// change, so the hosting view's ideal size stays frozen; AppKit panels
    /// with dynamically-sized SwiftUI content trap inside updateConstraints).
    private func scale(_ idx: Int) -> CGFloat {
        guard let h = hovered, h >= 0 else { return 1.0 }
        let d = abs(idx - h)
        if d == 0 { return 1.4 }
        if d == 1 { return 1.22 }
        if d == 2 { return 1.08 }
        return 1.0
    }

    var body: some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            // Finder-equivalent: Aura mark, bare on glass.
            Button(action: onLogo) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .frame(width: 56, height: 46)
                    .scaleEffect(hovered == -1 ? 1.2 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 ? -1 : nil }
            .help("Aura — ⌃Space for search")

            Divider().background(.white.opacity(0.22)).padding(.horizontal, 16)

            ForEach(Array(items.enumerated()), id: \.element.id) { idx, entry in
                DockIcon(entry: entry,
                         thumbnail: entry.kind == .image ? clipboard.loadImage(entry) : nil)
                    .scaleEffect(scale(idx))
                    .onTapGesture { onPaste(entry) }
                    .onHover { hovered = $0 ? idx : nil }
                    .help("\(entry.title)\n\(kindLabel(entry.kind)) · \(entry.sourceApp) · \(entry.ageString)")
                    .overlay(alignment: .bottom) {
                        if entry.pinned {
                            Circle().fill(.white.opacity(0.9))
                                .frame(width: 4, height: 4)
                                .offset(y: 5)
                        }
                    }
                    .contextMenu {
                        Button(entry.pinned ? "Unpin" : "Pin", action: { onPin(entry) })
                        if !clipboard.boards.isEmpty {
                            Menu("File in") {
                                ForEach(clipboard.boards) { board in
                                    Button {
                                        onToggleBoard(entry, board)
                                    } label: {
                                        HStack {
                                            Text(board.name)
                                            if entry.boardIDs.contains(board.id) { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Copy", action: { onCopy(entry) })
                        Button("Delete", role: .destructive, action: { onDelete(entry) })
                    }
            }

            if overflow > 0 {
                Button(action: onSearch) {
                    Text("+\(overflow)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 40)
                }
                .buttonStyle(.plain)
                .help("Show all \(clipboard.entries.count) clips")
            }

            Divider().background(.white.opacity(0.22)).padding(.horizontal, 16)

            // Tools, bare glyphs like Dock utilities.
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .frame(width: 56, height: 42)
                    .scaleEffect(hovered == -2 ? 1.2 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 ? -2 : nil }
            .help("Search clips (⌃Space)")

            Button(action: onClear) {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .frame(width: 56, height: 42)
                    .scaleEffect(hovered == -3 ? 1.2 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 ? -3 : nil }
            .help("Empty unpinned clips (\(clipboard.entries.filter { !$0.pinned }.count))")

            if clipboard.paused {
                Circle().fill(.orange).frame(width: 5, height: 5)
                    .help("Capturing paused")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        // Frozen layout size: the panel is 96x640 and this view always fills
        // it exactly, so NSHostingView never renegotiates constraints.
        .frame(width: 96, height: 640)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, x: 3, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hovered)
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
}

// MARK: - Dock icons: bare on glass, like Finder documents

/// White document with folded corner + type glyph, the way macOS draws
/// generic file icons sitting in the Dock. No tiles, no boxes.
private struct DockIcon: View {
    let entry: ClipboardEntry
    let thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let t = thumbnail {
                Image(nsImage: t)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(.white.opacity(0.4), lineWidth: 0.5)
                    }
            } else if let c = entry.detectedColor {
                Circle()
                    .fill(Color(red: c.red, green: c.green, blue: c.blue))
                    .frame(width: 38, height: 38)
                    .overlay { Circle().stroke(.white.opacity(0.5), lineWidth: 1) }
            } else {
                ZStack {
                    DocPaper()
                        .fill(.white)
                        .frame(width: 38, height: 46)
                    Image(systemName: tileSymbol(entry.kind))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(glyphColor)
                }
            }
        }
        .frame(width: 56, height: 50)
        .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
    }

    private var glyphColor: Color {
        switch entry.kind {
        case .text: return .blue
        case .link: return .green
        case .email: return .teal
        default: return .gray
        }
    }
}

/// macOS document silhouette with a folded top-right corner.
private struct DocPaper: Shape {
    func path(in r: CGRect) -> Path {
        let fold: CGFloat = 10
        let radius: CGFloat = 6
        var p = Path()
        p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addArc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addArc(center: CGPoint(x: r.minX + radius, y: r.minY + radius), radius: radius,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Flyout (search + boards + list)

struct DockFlyoutView: View {
    @ObservedObject var clipboard: ClipboardManager
    @State private var query = ""
    @State private var selectedBoardID: UUID?
    @State private var selectedIndex = 0
    @State private var hoverID: UUID?
    @State private var showAddBoard = false
    @State private var newBoardName = ""
    @FocusState private var searchFocused: Bool

    var onPaste: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    private var activeBoard: Board? {
        clipboard.boards.first(where: { $0.id == selectedBoardID })
    }

    private var results: [ClipboardEntry] {
        let scoped = clipboard.entries(for: activeBoard)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(scoped.prefix(40)) }
        var scored: [(ClipboardEntry, Int)] = []
        for e in scoped {
            if e.kind == .image {
                if "image".contains(q.lowercased()) { scored.append((e, 50)) }
                continue
            }
            if let s = fuzzyScore(query: q, target: String(e.text.prefix(500))) {
                scored.append((e, s))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(30).map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                TextField("", text: $query, prompt: Text("Search clips…").foregroundColor(.secondary))
                    .font(.system(size: 14)).textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.08), lineWidth: 1) }
            .padding(10)

            // Board chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(title: "All", active: selectedBoardID == nil) { selectedBoardID = nil }
                    ForEach(clipboard.boards) { board in
                        chip(title: board.name, dot: board.hex, active: selectedBoardID == board.id,
                             onDelete: { clipboard.deleteBoard(board) }) {
                            selectedBoardID = board.id
                        }
                    }
                    Button { showAddBoard.toggle() } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(.black.opacity(0.05), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showAddBoard, arrowEdge: .top) {
                        HStack(spacing: 8) {
                            TextField("New board…", text: $newBoardName)
                                .font(.system(size: 12)).textFieldStyle(.roundedBorder).frame(width: 130)
                            Button("Add") {
                                clipboard.addBoard(name: newBoardName,
                                                   colorIndex: clipboard.boards.count % Board.palette.count)
                                newBoardName = ""
                                showAddBoard = false
                            }
                            .disabled(newBoardName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(10).frame(width: 240)
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.bottom, 8)

            Divider().background(.black.opacity(0.08))

            // List
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, entry in
                            FlyRow(
                                entry: entry,
                                thumbnail: entry.kind == .image ? clipboard.loadImage(entry) : nil,
                                selected: idx == selectedIndex,
                                starred: entry.pinned || idx == selectedIndex || entry.id == hoverID,
                                onStar: { clipboard.togglePin(entry) }
                            )
                            .id(entry.id)
                            .onTapGesture {
                                selectedIndex = idx
                                paste(entry)
                            }
                            .onHover { if $0 { hoverID = entry.id } else if hoverID == entry.id { hoverID = nil } }
                        }
                        if results.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "tray").font(.system(size: 22)).foregroundStyle(.tertiary)
                                Text(query.isEmpty ? "Nothing here yet" : "No matches")
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                Text(query.isEmpty ? "Copy with ⌘C — it lands here." : "Try a different search.")
                                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedIndex) { _, idx in
                    if idx < results.count {
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(results[idx].id, anchor: .center) }
                    }
                }
            }

            // Footer hints
            HStack(spacing: 0) {
                Group {
                    Text("↑↓").bold() + Text(" move  ")
                    Text("⏎").bold() + Text(" paste  ")
                    Text("⌘D").bold() + Text(" pin")
                }
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Text("\(results.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.black.opacity(0.03))
        }
        .frame(width: 380, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.black.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 40, x: 8, y: 12)
        .preferredColorScheme(.light)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: selectedBoardID) { _, _ in selectedIndex = 0 }
        .onChange(of: results.count) { _, n in
            if selectedIndex >= n { selectedIndex = max(0, n - 1) }
        }
        .onKeyPress { press in handleKey(press) }
    }

    private func chip(title: String, dot: String? = nil, active: Bool,
                      onDelete: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let dot { Circle().fill(Color(hex: dot)).frame(width: 8, height: 8) }
                    Text(title).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                }
                .foregroundStyle(active ? .white : .primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(active ? Color(nsColor: .controlAccentColor).opacity(0.85) : .black.opacity(0.05),
                            in: Capsule())
            }
            .buttonStyle(.plain)
            if active, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let cmd = press.modifiers.contains(.command)
        switch press.key {
        case .upArrow: move(-1); return .handled
        case .downArrow: move(1); return .handled
        case .escape: onEscape?(); return .handled
        case .return:
            if cmd { copySelected() } else { pasteSelected() }
            return .handled
        case .delete:
            if cmd || query.isEmpty { deleteSelected(); return .handled }
            return .ignored
        default: break
        }
        if cmd {
            let ch = String(describing: press.key)
            if let n = Int(ch), (1...9).contains(n) { quickPaste(n); return .handled }
            if ch.lowercased() == "d" { togglePinSelected(); return .handled }
        }
        return .ignored
    }

    private func move(_ delta: Int) {
        let n = results.count
        guard n > 0 else { return }
        selectedIndex = (selectedIndex + delta + n) % n
    }

    private func pasteSelected() {
        guard !results.isEmpty, selectedIndex < results.count else { return }
        paste(results[selectedIndex])
    }

    private func paste(_ entry: ClipboardEntry) {
        clipboard.copyAndPaste(entry)
        query = ""
        selectedIndex = 0
        onPaste?()
    }

    private func copySelected() {
        guard !results.isEmpty, selectedIndex < results.count else { return }
        clipboard.copyOnly(results[selectedIndex])
        onPaste?()
    }

    private func deleteSelected() {
        guard !results.isEmpty, selectedIndex < results.count else { return }
        clipboard.delete(results[selectedIndex])
        if selectedIndex >= results.count - 1 { selectedIndex = max(0, results.count - 2) }
    }

    private func togglePinSelected() {
        guard !results.isEmpty, selectedIndex < results.count else { return }
        clipboard.togglePin(results[selectedIndex])
    }

    private func quickPaste(_ n: Int) {
        guard n <= results.count else { return }
        paste(results[n - 1])
    }
}

// MARK: - Flyout row

private struct FlyRow: View {
    let entry: ClipboardEntry
    let thumbnail: NSImage?
    let selected: Bool
    let starred: Bool
    var onStar: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let t = thumbnail {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                } else if let c = entry.detectedColor {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(red: c.red, green: c.green, blue: c.blue))
                        .frame(width: 40, height: 40)
                } else {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: tileColors(entry.kind), startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: tileSymbol(entry.kind))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Text("\(kindLabel) · \(entry.sourceApp) · \(entry.ageString)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if starred {
                Button(action: onStar) {
                    Image(systemName: entry.pinned ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(entry.pinned ? .yellow : .gray.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            if selected {
                Image(systemName: "return").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? .black.opacity(0.06) : .clear))
        .animation(.easeOut(duration: 0.1), value: selected)
    }

    private var kindLabel: String {
        switch entry.kind {
        case .text: return "Text"
        case .link: return "Link"
        case .email: return "Email"
        case .color: return "Color"
        case .image: return "Image"
        }
    }
}

// MARK: - Hex color (shared with cards)

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        if h.count == 6 {
            self.init(red: Double((v >> 16) & 0xFF) / 255,
                      green: Double((v >> 8) & 0xFF) / 255,
                      blue: Double(v & 0xFF) / 255)
        } else {
            self.init(red: 0.5, green: 0.5, blue: 0.5)
        }
    }
}
