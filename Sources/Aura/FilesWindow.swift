import AppKit
import Quartz
import SwiftUI

// MARK: - Quick Look (Space on a row, like Finder)

/// System Quick Look panel driven by file URLs. Zero rendering code of ours.
/// Unisolated with a lock: QL data-source callbacks arrive outside Swift
/// actors, so this class stays off @MainActor and guards its one field.
final class QuickLooker: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, @unchecked Sendable {
    static let shared = QuickLooker()
    private let lock = NSLock()
    private var _current: String?
    private var current: String? {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }

    @MainActor
    func toggle(_ file: IndexedFile) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, current == file.path {
            panel.orderOut(nil)
            current = nil
            return
        }
        current = file.path
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { current == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let current else { return nil }
        return URL(fileURLWithPath: current) as NSURL
    }
}

// MARK: - Files window: Homy-style storage browser (light, Apple-native)

enum FilesSel: Hashable {
    case home
    case recents
    case kind(FileKind)
    case largeFiles
    case screenshots
    case duplicates
    case forgotten
    case oldScreenshots
    case unusedApps
    case downloaded
    case source(host: String)
    case location(name: String, path: String)
    case searchAll
}

@MainActor
final class FilesWindowController {
    private var window: NSWindow?
    private let indexer: FilesIndexer

    init(indexer: FilesIndexer) {
        self.indexer = indexer
    }

    func show(initialQuery: String? = nil) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            w.title = "Aura Files"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.minSize = NSSize(width: 1020, height: 660)
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces]
            window = w
        }
        guard let window else { return }
        window.contentView = NSHostingView(rootView: FilesRootView(indexer: indexer, initialQuery: initialQuery))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Root

private struct FilesRootView: View {
    @ObservedObject var indexer: FilesIndexer
    @State private var selection: FilesSel = .home
    @State private var search: String = ""
    /// Debounced filter text: heavy fuzzy matching runs at most ~7×/s while typing.
    @State private var appliedQuery: String = ""
    @FocusState private var searchFocused: Bool
    @State private var sort: ListSort = .date
    @State private var selectedRow: Int = 0

    init(indexer: FilesIndexer, initialQuery: String? = nil) {
        self.indexer = indexer
        _search = State(initialValue: initialQuery ?? "")
        _selection = State(initialValue: initialQuery == nil ? .home : .searchAll)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 218)
            Divider().background(.black.opacity(0.08))
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1020, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
        .onAppear { indexer.scan() }
        .onChange(of: appliedQuery) { _, _ in selectedRow = 0 }
        .onChange(of: selection) { _, _ in selectedRow = 0 }
        .task(id: search) {
            // Debounce: restart the clock on every keystroke.
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { appliedQuery = search }
        }
    }

    // MARK: Sidebar

    private var locations: [(String, String)] {
        let home = NSHomeDirectory()
        return [("Home", home), ("Desktop", home + "/Desktop"), ("Documents", home + "/Documents"),
                ("Downloads", home + "/Downloads"), ("Pictures", home + "/Pictures"),
                ("Movies", home + "/Movies"), ("Music", home + "/Music")]
            .filter { FileManager.default.fileExists(atPath: $0.1) }
    }

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [.blue, .mint], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 28, height: 28)
                        Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text("Aura Files").font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

                sideItem(icon: "house", title: "Home", sel: .home)
                sideItem(icon: "clock", title: "Recents", sel: .recents)
                ForEach([FileKind.image, .video, .music, .document, .archive, .app], id: \.self) { kind in
                    sideItem(icon: kind.symbol, title: kind.label, sel: .kind(kind),
                             count: "\(indexer.count(for: kind))")
                }

                Divider().padding(.vertical, 6)
                sideItem(icon: "archivebox", title: "Large Files", sel: .largeFiles,
                         badge: "\(indexer.largeOver100MB())")
                sideItem(icon: "camera", title: "Screenshots", sel: .screenshots,
                         count: "\(indexer.screenshots().count)")
                let dups = indexer.duplicates()
                sideItem(icon: "doc.on.doc", title: "Duplicates", sel: .duplicates,
                         green: byteString(dups.reduce(0) { $0 + $1.extraBytes }))
                sideItem(icon: "sparkles", title: "Clean Up", sel: .forgotten,
                         green: byteString(cleanupBytes))
                sideItem(icon: "arrow.down.circle", title: "Downloaded From", sel: .downloaded,
                         count: "\(indexer.downloadSources().count)")

                Divider().padding(.vertical, 6)
                Text("Locations").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 2)
                ForEach(locations, id: \.0) { name, path in
                    sideItem(icon: "folder.fill", title: name, sel: .location(name: name, path: path), folder: true)
                }
                Spacer(minLength: 12)
            }
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var cleanupBytes: Int64 {
        let dups = indexer.duplicates().reduce(0) { $0 + $1.extraBytes }
        let forg = indexer.forgottenDownloads().reduce(0) { $0 + $1.size }
        let old = indexer.oldScreenshots().reduce(0) { $0 + $1.size }
        let un = indexer.unusedApps().reduce(0) { $0 + $1.size }
        return dups + forg + old + un
    }

    private func sideItem(icon: String, title: String, sel: FilesSel,
                          count: String? = nil, badge: String? = nil, green: String? = nil,
                          folder: Bool = false) -> some View {
        let active = selection == sel
        return Button {
            selection = sel
            if sel != .searchAll { search = "" }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(folder ? .blue : .secondary)
                    .frame(width: 18)
                Text(title).font(.system(size: 13, weight: active ? .semibold : .regular))
                Spacer()
                if let badge {
                    Text(badge).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.red, in: Capsule())
                } else if let green {
                    Text(green).font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                } else if let count {
                    Text(count).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(active ? .black.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if selection == .home {
            dashboard
        } else {
            fileList
        }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                // Top bar
                HStack {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
                        TextField("", text: $search, prompt: Text("Search, or try \"pdfs from last week\"…").foregroundColor(.secondary))
                            .font(.system(size: 13)).textFieldStyle(.plain)
                            .focused($searchFocused)
                            .frame(width: 250)
                            .onSubmit {
                                if !search.isEmpty {
                                    appliedQuery = search
                                    selection = .searchAll
                                }
                            }
                        Text("⌘F").font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.1), lineWidth: 1) }
                    Spacer()
                    if indexer.scanning {
                        ProgressView().controlSize(.small)
                        Text("Scanning… \(indexer.scannedCount)").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text("Library size  ").font(.system(size: 12)).foregroundStyle(.secondary)
                            + Text(byteString(indexer.totalBytes)).font(.system(size: 12, weight: .semibold))
                    }
                    Button("Refresh") { indexer.scan() }
                        .font(.system(size: 12)).buttonStyle(.link)
                }

                // Greeting
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting).font(.system(size: 26, weight: .bold))
                    Text("\(indexer.files.count + indexer.apps.count) files · \(byteString(indexer.totalBytes)) across your Mac")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }

                // Library
                sectionHeader("Library", count: 6)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach([FileKind.image, .video, .music, .document, .archive, .app], id: \.self) { kind in
                        FolderCard(kind: kind,
                                   count: indexer.count(for: kind),
                                   bytes: indexer.bytes(for: kind),
                                   thumbs: Array(indexer.byKind(kind).prefix(3)),
                                   icon: { indexer.fileIcon($0) }) {
                            selection = .kind(kind)
                        }
                    }
                }

                // Clean Up
                HStack {
                    Text("Clean Up").font(.system(size: 17, weight: .bold))
                    Text("Free up to \(byteString(cleanupBytes))").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color(red: 0.2, green: 0.65, blue: 0.35), in: Capsule())
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    let dups = indexer.duplicates()
                    let dupBytes = dups.reduce(0) { $0 + $1.extraBytes }
                    let dupCount = dups.reduce(0) { $0 + $1.files.count - 1 }
                    CleanupCard(tint: Color(red: 0.98, green: 0.87, blue: 0.89), icon: "doc.on.doc.fill", iconTint: .red,
                                label: "Duplicates", big: byteString(dupBytes), detail: "\(dupCount) extra copies") {
                        selection = .duplicates
                    }
                    let forg = indexer.forgottenDownloads()
                    CleanupCard(tint: Color(red: 0.86, green: 0.91, blue: 0.99), icon: "arrow.down.circle.fill", iconTint: .blue,
                                label: "Forgotten Downloads", big: byteString(forg.reduce(0) { $0 + $1.size }),
                                detail: "\(forg.count) items") {
                        selection = .forgotten
                    }
                    let old = indexer.oldScreenshots()
                    CleanupCard(tint: Color(red: 0.98, green: 0.9, blue: 0.92), icon: "camera.fill", iconTint: .pink,
                                label: "Old Screenshots", big: byteString(old.reduce(0) { $0 + $1.size }),
                                detail: "\(old.count) items") {
                        selection = .oldScreenshots
                    }
                    let un = indexer.unusedApps()
                    CleanupCard(tint: Color(red: 0.87, green: 0.95, blue: 0.89), icon: "app.badge.fill", iconTint: .green,
                                label: "Unused Apps", big: byteString(un.reduce(0) { $0 + $1.size }),
                                detail: "\(un.count) items") {
                        selection = .unusedApps
                    }
                }

                // Downloaded From
                sectionHeader("Downloaded From", count: indexer.downloadSources().count)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(indexer.downloadSources()) { src in
                            SourceCard(source: src) { selection = .source(host: src.host) }
                        }
                        if indexer.downloadSources().isEmpty && !indexer.scanning {
                            Text("No downloads with source info yet.")
                                .font(.system(size: 12)).foregroundStyle(.tertiary).padding(8)
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 17, weight: .bold))
            Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(.black.opacity(0.06), in: Capsule())
        }
    }

    // MARK: File list

    private var listScope: [IndexedFile] {
        switch selection {
        case .home: return []
        case .recents: return indexer.recents()
        case .kind(let k): return indexer.byKind(k)
        case .largeFiles: return indexer.largeFiles()
        case .screenshots: return indexer.screenshots()
        case .duplicates:
            return indexer.duplicates().flatMap(\.files).sorted { $0.size > $1.size }
        case .forgotten: return indexer.forgottenDownloads()
        case .oldScreenshots: return indexer.oldScreenshots()
        case .unusedApps: return indexer.unusedApps()
        case .downloaded: return indexer.files.filter { $0.sourceHost != nil }.sorted { $0.modified > $1.modified }
        case .source(let host): return indexer.files.filter { $0.sourceHost == host }.sorted { $0.modified > $1.modified }
        case .location(_, let path):
            return indexer.analysis.byRoot[path] ?? []
        case .searchAll: return indexer.allEntries
        }
    }

    private var listTitle: String {
        switch selection {
        case .home: return ""
        case .recents: return "Recents"
        case .kind(let k): return k.label
        case .largeFiles: return "Large Files"
        case .screenshots: return "Screenshots"
        case .duplicates: return "Duplicates"
        case .forgotten: return "Forgotten Downloads"
        case .oldScreenshots: return "Old Screenshots"
        case .unusedApps: return "Unused Apps"
        case .downloaded: return "Downloaded"
        case .source(let h): return h
        case .location(let n, _): return n
        case .searchAll: return "All Files"
        }
    }

    private var listResults: [IndexedFile] {
        let scope = listScope
        let q = appliedQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            switch sort {
            case .date: return scope.sorted { $0.modified > $1.modified }
            case .name: return scope.sorted { $0.name.lowercased() < $1.name.lowercased() }
            case .size: return scope.sorted { $0.size > $1.size }
            }
        }
        return indexer.search(q, in: scope)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Button { selection = .home } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                }.buttonStyle(.plain).help("Back to Home")
                Text(listTitle).font(.system(size: 17, weight: .bold))
                Text("\(listResults.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.black.opacity(0.06), in: Capsule())
                Spacer()
                Picker("", selection: $sort) {
                    Text("Date").tag(ListSort.date)
                    Text("Name").tag(ListSort.name)
                    Text("Size").tag(ListSort.size)
                }
                .pickerStyle(.segmented).frame(width: 200)
            }
            .padding(16)
            Divider().background(.black.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(listResults.enumerated()), id: \.element.id) { idx, f in
                            FileRow(file: f, icon: indexer.fileIcon(f), selected: idx == selectedRow)
                                .id(f.id)
                                .onTapGesture {
                                    selectedRow = idx
                                }
                                .onTapGesture(count: 2) { openFile(f) }
                                .contextMenu {
                                    Button("Open") { openFile(f) }
                                    Button("Quick Look (Space)") { QuickLooker.shared.toggle(f) }
                                    Button("Reveal in Finder") { revealFile(f) }
                                    Button("Copy Path") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(f.path, forType: .string)
                                    }
                                }
                        }
                        if listResults.isEmpty {
                            Text(appliedQuery.isEmpty ? "Nothing here yet." : "No matches.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 60)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: selectedRow) { _, idx in
                    if idx < listResults.count {
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(listResults[idx].id, anchor: .center) }
                    }
                }
            }
        }
        .onKeyPress(.upArrow) { moveRow(-1); return .handled }
        .onKeyPress(.downArrow) { moveRow(1); return .handled }
        .onKeyPress(.return) { openSelected(); return .handled }
        .onKeyPress(keys: [" "], phases: .down) { _ in
            // Space = Quick Look, Finder-style — but never while typing.
            guard !searchFocused else { return .ignored }
            quickLookSelected()
            return .handled
        }
    }

    private func quickLookSelected() {
        guard !listResults.isEmpty, selectedRow < listResults.count else { return }
        QuickLooker.shared.toggle(listResults[selectedRow])
    }

    private func moveRow(_ d: Int) {
        let n = listResults.count
        guard n > 0 else { return }
        selectedRow = (selectedRow + d + n) % n
    }

    private func openSelected() {
        guard !listResults.isEmpty, selectedRow < listResults.count else { return }
        openFile(listResults[selectedRow])
    }

    private func openFile(_ f: IndexedFile) {
        NSWorkspace.shared.open(URL(fileURLWithPath: f.path))
    }

    private func revealFile(_ f: IndexedFile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)])
    }
}

private enum ListSort { case date, name, size }

// MARK: - Folder card (pastel folder with tab + icon stack)

private struct FolderCard: View {
    let kind: FileKind
    let count: Int
    let bytes: Int64
    let thumbs: [IndexedFile]
    let icon: (IndexedFile) -> NSImage
    var action: () -> Void

    private var pastel: Color {
        switch kind {
        case .image: return Color(red: 0.9, green: 0.88, blue: 0.96)
        case .video: return Color(red: 0.85, green: 0.9, blue: 0.97)
        case .music: return Color(red: 0.97, green: 0.89, blue: 0.83)
        case .document: return Color(red: 0.85, green: 0.94, blue: 0.89)
        case .archive: return Color(red: 0.97, green: 0.93, blue: 0.81)
        case .app: return Color(red: 0.97, green: 0.85, blue: 0.89)
        case .other: return Color(red: 0.92, green: 0.92, blue: 0.94)
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                // Tab
                RoundedRectangle(cornerRadius: 10)
                    .fill(pastel.shadow(.inner(color: .black.opacity(0.06), radius: 4)))
                    .frame(width: 100, height: 34)
                    .offset(x: 14, y: 0)
                // Body
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(pastel)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.black.opacity(0.06), lineWidth: 1)
                    }
                    .padding(.top, 16)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer()
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 34, height: 22)
                            .background(.white.opacity(0.7), in: Capsule())
                    }
                    .padding(.horizontal, 12).padding(.top, 24)
                    Text(kind.label)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14).padding(.top, 2)
                    Divider().background(.black.opacity(0.12)).padding(.horizontal, 14).padding(.top, 8)
                    HStack {
                        ThumbStackView(files: thumbs, icon: icon, total: count)
                        Spacer()
                        Text("\(count) items · \(byteString(bytes))")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .padding(.top, 16)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ThumbStackView: View {
    let files: [IndexedFile]
    let icon: (IndexedFile) -> NSImage
    let total: Int

    var body: some View {
        HStack(spacing: -8) {
            ForEach(files.prefix(3)) { f in
                Image(nsImage: icon(f))
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                    .overlay { Circle().stroke(.white, lineWidth: 2) }
            }
            if total > 3 {
                Text("+\(min(total - 3, 99))\(total - 3 > 99 ? "+" : "")")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.white, in: Circle())
                    .overlay { Circle().stroke(.black.opacity(0.08), lineWidth: 1) }
            }
        }
    }
}

// MARK: - Cleanup + source cards

private struct CleanupCard: View {
    let tint: Color
    let icon: String
    let iconTint: Color
    let label: String
    let big: String
    let detail: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ZStack {
                        Circle().fill(.white.opacity(0.8)).frame(width: 36, height: 36)
                        Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(iconTint)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Text(label).font(.system(size: 13))
                HStack(alignment: .firstTextBaseline) {
                    Text(big).font(.system(size: 24, weight: .bold))
                    Spacer()
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SourceCard: View {
    let source: DownloadSource
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(hue: hue, saturation: 0.45, brightness: 0.92)).frame(width: 38, height: 38)
                    Text(String(source.host.prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.host).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(source.count) files · \(byteString(source.bytes))")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(10)
            .frame(width: 210, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var hue: Double {
        Double(abs(source.host.hashValue) % 100) / 100.0
    }
}

// MARK: - File row

private struct FileRow: View {
    let file: IndexedFile
    let icon: NSImage
    let selected: Bool

    static var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Text(file.path).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if let host = file.sourceHost {
                Text(host).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.black.opacity(0.05), in: Capsule())
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(byteString(file.size)).font(.system(size: 12, weight: .medium))
                Text(Self.dateFormatter.string(from: file.modified)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .controlAccentColor).opacity(0.5), lineWidth: 1)
            }
        }
    }
}
