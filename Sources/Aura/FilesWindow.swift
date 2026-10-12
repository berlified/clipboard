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
            w.title = "LiveDocs"
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
            Divider().background(.white.opacity(0.1))
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1020, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
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
                            .fill(.black)
                            .frame(width: 28, height: 28)
                        Image(systemName: "touchid").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.25), lineWidth: 0.5)
                    }
                    Text("LiveDocs").font(.system(size: 15, weight: .semibold))
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
                storageMeter
            }
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var storageMeter: some View {
        let v = indexer.volumeInfo()
        let used = indexer.volumeUsed()
        let frac = v.total > 0 ? min(1, Double(used) / Double(v.total)) : 0
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text("Storage").font(.system(size: 13, weight: .semibold))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.12))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.white, Color(white: 0.45)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * frac), height: 6)
                }
            }
            .frame(height: 6)
            Text("\(byteString(used)) of \(byteString(v.total)) used")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Free Up Space") { selection = .forgotten }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1)
        }
        .padding(.horizontal, 8)
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
                    .foregroundStyle(folder ? .white : .secondary)
                    .frame(width: 18)
                Text(title).font(.system(size: 13, weight: active ? .semibold : .regular))
                Spacer()
                if let badge {
                    Text(badge).font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.white, in: Capsule())
                } else if let green {
                    Text(green).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                } else if let count {
                    Text(count).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(active ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
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
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.14), lineWidth: 1) }
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
                    Text("\(indexer.files.count + indexer.apps.count) files · \(byteString(indexer.totalBytes)) indexed · \(byteString(indexer.volumeUsed())) of \(byteString(indexer.volumeInfo().total)) on disk")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }

                // Stat cards (Cloudy-style: size + trend + date span)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    StatCard(icon: "doc.text.fill", tint: kindColor(.document), label: "Documents",
                             bytes: indexer.bytes(for: .document),
                             trend: indexer.analysis.trends[.document] ?? 0,
                             span: indexer.analysis.spans[.document])
                    StatCard(icon: "photo.fill", tint: kindColor(.image), label: "Images",
                             bytes: indexer.bytes(for: .image),
                             trend: indexer.analysis.trends[.image] ?? 0,
                             span: indexer.analysis.spans[.image])
                    StatCard(icon: "video.fill", tint: kindColor(.video), label: "Videos",
                             bytes: indexer.bytes(for: .video),
                             trend: indexer.analysis.trends[.video] ?? 0,
                             span: indexer.analysis.spans[.video])
                    StatCard(icon: "folder.fill", tint: .gray, label: "Others",
                             bytes: othersBytes, trend: othersTrend, span: othersSpan)
                }

                // Library
                sectionHeader("Library", count: 6)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach([FileKind.image, .video, .music, .document, .archive, .app], id: \.self) { kind in
                        FolderCard(kind: kind,
                                   count: indexer.count(for: kind),
                                   bytes: indexer.bytes(for: kind)) {
                            selection = .kind(kind)
                        }
                    }
                }

                // Storage bar (Cloudy-style volume breakdown)
                StorageBarCard(indexer: indexer)

                // Clean Up
                HStack {
                    Text("Clean Up").font(.system(size: 17, weight: .bold))
                    Text("Free up to \(byteString(cleanupBytes))").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black).padding(.horizontal, 9).padding(.vertical, 3)
                        .background(.white, in: Capsule())
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    let dups = indexer.duplicates()
                    let dupBytes = dups.reduce(0) { $0 + $1.extraBytes }
                    let dupCount = dups.reduce(0) { $0 + $1.files.count - 1 }
                    CleanupCard(icon: "doc.on.doc.fill", iconTint: .white,
                                label: "Duplicates", big: byteString(dupBytes), detail: "\(dupCount) extra copies") {
                        selection = .duplicates
                    }
                    let forg = indexer.forgottenDownloads()
                    CleanupCard(icon: "arrow.down.circle.fill", iconTint: .white,
                                label: "Forgotten Downloads", big: byteString(forg.reduce(0) { $0 + $1.size }),
                                detail: "\(forg.count) items") {
                        selection = .forgotten
                    }
                    let old = indexer.oldScreenshots()
                    CleanupCard(icon: "camera.fill", iconTint: .white,
                                label: "Old Screenshots", big: byteString(old.reduce(0) { $0 + $1.size }),
                                detail: "\(old.count) items") {
                        selection = .oldScreenshots
                    }
                    let un = indexer.unusedApps()
                    CleanupCard(icon: "app.badge.fill", iconTint: .white,
                                label: "Unused Apps", big: byteString(un.reduce(0) { $0 + $1.size }),
                                detail: "\(un.count) items") {
                        selection = .unusedApps
                    }
                }

                // Charts + recent uploads (Cloudy-style analytics)
                HStack(alignment: .top, spacing: 14) {
                    ActivityCard(indexer: indexer).frame(maxWidth: .infinity)
                    KindBarsCard(indexer: indexer).frame(width: 300)
                }
                RecentUploadsCard(indexer: indexer, open: { openFile($0) })

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

    private var otherKinds: [FileKind] { [.music, .archive, .app, .other] }
    private var othersBytes: Int64 { otherKinds.reduce(0) { acc, k in acc + indexer.bytes(for: k) } }
    private var othersTrend: Double {
        let ts = otherKinds.map { indexer.analysis.trends[$0] ?? 0 }
        return ts.reduce(0, +) / Double(max(ts.count, 1))
    }
    private var othersSpan: (oldest: Date, newest: Date)? {
        let spans = otherKinds.compactMap { indexer.analysis.spans[$0] }
        guard !spans.isEmpty else { return nil }
        return (spans.map(\.oldest).min()!, spans.map(\.newest).max()!)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 17, weight: .bold))
            Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(.white.opacity(0.12), in: Capsule())
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
                    .background(.white.opacity(0.12), in: Capsule())
                Spacer()
                Picker("", selection: $sort) {
                    Text("Date").tag(ListSort.date)
                    Text("Name").tag(ListSort.name)
                    Text("Size").tag(ListSort.size)
                }
                .pickerStyle(.segmented).frame(width: 200)
            }
            .padding(16)
            Divider().background(.white.opacity(0.1))
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

// MARK: - Kind accents (charts, tabs, badges, placeholder tiles)

// Monochrome kind ramp: distinct grays keep charts/legends readable
// with zero hue. Dark mode only.
private func kindColor(_ kind: FileKind) -> Color {
    switch kind {
    case .document: return .white
    case .app: return Color(white: 0.88)
    case .image: return Color(white: 0.74)
    case .video: return Color(white: 0.6)
    case .music: return Color(white: 0.46)
    case .archive: return Color(white: 0.34)
    case .other: return Color(white: 0.24)
    }
}

/// Gradient placeholder tiles, monochrome: stepped grays per kind.
private func kindGradient(_ kind: FileKind) -> LinearGradient {
    func g(_ top: Double, _ bottom: Double) -> LinearGradient {
        LinearGradient(colors: [Color(white: top), Color(white: bottom)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    switch kind {
    case .document: return g(0.95, 0.7)
    case .image: return g(0.8, 0.55)
    case .video: return g(0.66, 0.42)
    case .music: return g(0.52, 0.3)
    case .archive: return g(0.4, 0.22)
    case .app: return g(0.92, 0.66)
    case .other: return g(0.32, 0.18)
    }
}

private func kindSymbol(_ kind: FileKind) -> String {
    switch kind {
    case .document: return "doc.text.fill"
    case .image: return "photo.fill"
    case .video: return "video.fill"
    case .music: return "music.note"
    case .archive: return "archivebox.fill"
    case .app: return "app.badge.fill"
    case .other: return "doc.fill"
    }
}

private func compactBytes(_ b: Double) -> String {
    if b >= 1_000_000_000 { return String(format: "%.0fG", b / 1_000_000_000) }
    if b >= 1_000_000 { return String(format: "%.0fM", b / 1_000_000) }
    if b >= 1_000 { return String(format: "%.0fK", b / 1_000) }
    return "\(Int(b))"
}

// MARK: - Folder card (dark body, kind-tinted tab, stacked-circle icons)

private struct FolderCard: View {
    let kind: FileKind
    let count: Int
    let bytes: Int64
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                // Tab
                RoundedRectangle(cornerRadius: 10)
                    .fill(kindColor(kind).opacity(0.85))
                    .frame(width: 100, height: 34)
                    .offset(x: 14, y: 0)
                // Body
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.1), lineWidth: 1)
                    }
                    .padding(.top, 16)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().fill(kindColor(kind).opacity(0.2)).frame(width: 30, height: 30)
                            Image(systemName: kind.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(kindColor(kind))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.top, 24)
                    Text(kind.label)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14).padding(.top, 6)
                    Divider().background(.white.opacity(0.1)).padding(.horizontal, 14).padding(.top, 8)
                    HStack {
                        ThumbStackView(kind: kind, count: count)
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
    /// Every circle shares the card's kind gradient — photos included — so
    /// the stack reads as one family, with +N in the same style.
    let kind: FileKind
    let count: Int

    var body: some View {
        HStack(spacing: -8) {
            ForEach(0..<min(3, count), id: \.self) { _ in
                ZStack {
                    kindGradient(kind)
                    Image(systemName: kindSymbol(kind))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(kind == .document || kind == .app || kind == .image ? .black : .white)
                        .shadow(color: .black.opacity(0.2), radius: 2)
                }
                .frame(width: 26, height: 26)
                .clipShape(Circle())
                .overlay { Circle().stroke(.white.opacity(0.35), lineWidth: 1.5) }
                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
            }
            if count > 3 {
                Text("+\(min(count - 3, 99))\(count - 3 > 99 ? "+" : "")")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(kindGradient(kind), in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.35), lineWidth: 1.5) }
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
            }
        }
    }
}

// MARK: - Cleanup + source cards

private struct CleanupCard: View {
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
                        Circle().fill(iconTint.opacity(0.18)).frame(width: 36, height: 36)
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
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1)
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
                    Circle()
                        .fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.45)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                    Text(String(source.host.prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.host).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(source.count) files · \(byteString(source.bytes))")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(10)
            .frame(width: 210, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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
                    .background(.white.opacity(0.12), in: Capsule())
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(byteString(file.size)).font(.system(size: 12, weight: .medium))
                Text(Self.dateFormatter.string(from: file.modified)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? .white.opacity(0.1) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.3), lineWidth: 1)
            }
        }
    }
}

// MARK: - Storage analytics (Cloudy-style, dark)

private struct StatCard: View {
    let icon: String
    let tint: Color
    let label: String
    let bytes: Int64
    let trend: Double
    let span: (oldest: Date, newest: Date)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                Text(label).font(.system(size: 13, weight: .medium))
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(byteString(bytes)).font(.system(size: 22, weight: .bold))
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: trend >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 7))
                    Text("\(trend >= 0 ? "+" : "")\(Int(trend.rounded()))%")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(trend >= 0 ? .black : .white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(trend >= 0 ? .white : .white.opacity(0.14), in: Capsule())
            }
            HStack(spacing: 5) {
                Image(systemName: "calendar").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(spanText).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1)
        }
    }

    private var spanText: String {
        guard let span else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MMM dd, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "\(f.string(from: span.oldest)) - \(f.string(from: span.newest))"
    }
}

private struct StorageBarCard: View {
    @ObservedObject var indexer: FilesIndexer

    private struct Seg { let label: String; let bytes: Int64; let color: Color }

    var body: some View {
        let v = indexer.volumeInfo()
        let used = indexer.volumeUsed()
        let indexed = indexer.totalBytes
        let docs = indexer.bytes(for: .document)
        let media = indexer.bytes(for: .image) + indexer.bytes(for: .video) + indexer.bytes(for: .music)
        let apps = indexer.bytes(for: .app)
        let indexedRest = max(0, indexed - docs - media - apps)
        // The truthful remainder: mail, messages, Library app data, dev
        // dependencies, macOS itself — counted by the volume, not our index.
        let restOfDisk = max(0, used - indexed)
        // Row 1: indexed breakdown, scaled to the INDEXED total so every
        // category stays visible and proportionally honest.
        let cats = [Seg(label: "Documents", bytes: docs, color: .white),
                    Seg(label: "Media", bytes: media, color: Color(white: 0.66)),
                    Seg(label: "Apps", bytes: apps, color: Color(white: 0.42)),
                    Seg(label: "Other files", bytes: indexedRest, color: Color(white: 0.24))]
        let catTotal = max(indexed, 1)
        // Row 2: whole-disk truth — indexed vs rest vs free, scaled to volume.
        let volTotal = max(v.total, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("This Mac").font(.system(size: 14, weight: .bold))
                    + Text(" Space's").font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer()
                Text("Using \(byteString(used)) of \(byteString(v.total))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(cats, id: \.label) { s in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(s.color)
                            .frame(width: max(s.bytes > 0 ? 3 : 0, geo.size.width * Double(s.bytes) / Double(catTotal)))
                    }
                }
            }
            .frame(height: 16)
            GeometryReader { geo in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(white: 0.32))
                        .frame(width: max(indexed > 0 ? 3 : 0, geo.size.width * Double(indexed) / Double(volTotal)))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(white: 0.18))
                        .frame(width: max(restOfDisk > 0 ? 3 : 0, geo.size.width * Double(restOfDisk) / Double(volTotal)))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.1))
                }
            }
            .frame(height: 7)
            HStack(spacing: 14) {
                ForEach(cats, id: \.label) { s in
                    HStack(spacing: 5) {
                        Circle().fill(s.color).frame(width: 8, height: 8)
                        Text("\(s.label) (\(byteString(s.bytes)))")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(Color(white: 0.32)).frame(width: 8, height: 8)
                    Text("Rest of disk (\(byteString(restOfDisk)))")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle().fill(.white.opacity(0.25)).frame(width: 8, height: 8)
                    Text("Free space (\(byteString(v.free)))")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Text("Top bar: your indexed folders. Bottom strip: the whole disk — categories plus app data, mail, dev dependencies, macOS and more.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1)
        }
    }
}

private struct ActivityCard: View {
    @ObservedObject var indexer: FilesIndexer
    @State private var range = 0
    private let tabs = ["12 Months", "30 Days", "7 Days"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Upload Activity").font(.system(size: 14, weight: .bold))
                Spacer()
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                        Button {
                            range = i
                        } label: {
                            Text(t).font(.system(size: 11, weight: range == i ? .semibold : .regular))
                                .foregroundStyle(range == i ? .white : .secondary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(range == i ? .white.opacity(0.16) : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(.white.opacity(0.06), in: Capsule())
            }
            LineChart(values: series.values, labels: series.labels)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1)
        }
    }

    private var series: (values: [Double], labels: [String]) {
        let cal = Calendar.current
        let now = Date()
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "MMM"
        if range == 0 {
            var vals: [Double] = []
            var labels: [String] = []
            for i in stride(from: 11, through: 0, by: -1) {
                guard let d = cal.date(byAdding: .month, value: -i, to: now) else { continue }
                let c = cal.dateComponents([.year, .month], from: d)
                let key = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
                vals.append(Double(indexer.analysis.monthlyBytes[key] ?? 0))
                labels.append(monthFmt.string(from: d))
            }
            return (vals, labels)
        }
        let days = range == 1 ? 30 : 7
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = range == 1 ? "d" : "E"
        var vals: [Double] = []
        var labels: [String] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -i, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            vals.append(Double(indexer.analysis.dailyBytes[key] ?? 0))
            labels.append(dayFmt.string(from: d))
        }
        return (vals, labels)
    }
}

private struct LineChart: View {
    let values: [Double]
    let labels: [String]

    var body: some View {
        GeometryReader { geo in
            let left: CGFloat = 34
            let w = max(geo.size.width - left, 10)
            let h: CGFloat = 150
            let maxV = max(values.max() ?? 1, 1)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { i in
                        HStack(spacing: 4) {
                            Text(compactBytes(maxV * Double(3 - i) / 3))
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                                .frame(width: 30, alignment: .trailing)
                            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                        }
                        if i < 3 { Spacer() }
                    }
                }
                .frame(height: h)
                .padding(.leading, 0)
                chartPath(w: w, h: h, maxV: maxV)
                    .offset(x: left)
                chartFill(w: w, h: h, maxV: maxV)
                    .offset(x: left)
                xLabels(w: w, h: h)
                    .offset(x: left)
            }
        }
        .frame(height: 172)
    }

    private func pt(_ i: Int, w: CGFloat, h: CGFloat, maxV: Double) -> CGPoint {
        let n = max(values.count - 1, 1)
        let x = w * Double(i) / Double(n)
        let y = h - 6 - (values[i] / maxV) * (h - 12)
        return CGPoint(x: x, y: y)
    }

    private func chartPath(w: CGFloat, h: CGFloat, maxV: Double) -> some View {
        Path { p in
            guard !values.isEmpty else { return }
            p.move(to: pt(0, w: w, h: h, maxV: maxV))
            for i in 1..<values.count { p.addLine(to: pt(i, w: w, h: h, maxV: maxV)) }
        }
        .stroke(Color.white, lineWidth: 1.5)
    }

    private func chartFill(w: CGFloat, h: CGFloat, maxV: Double) -> some View {
        Path { p in
            guard !values.isEmpty else { return }
            p.move(to: CGPoint(x: pt(0, w: w, h: h, maxV: maxV).x, y: h))
            p.addLine(to: pt(0, w: w, h: h, maxV: maxV))
            for i in 1..<values.count { p.addLine(to: pt(i, w: w, h: h, maxV: maxV)) }
            p.addLine(to: CGPoint(x: pt(values.count - 1, w: w, h: h, maxV: maxV).x, y: h))
            p.closeSubpath()
        }
        .fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
    }

    private func xLabels(w: CGFloat, h: CGFloat) -> some View {
        let stride = max(1, labels.count / 6)
        return ZStack {
            ForEach(Array(labels.enumerated()).filter { $0.offset % stride == 0 }, id: \.offset) { idx, lab in
                let n = max(labels.count - 1, 1)
                Text(lab).font(.system(size: 9)).foregroundStyle(.tertiary)
                    .position(x: w * Double(idx) / Double(n), y: h + 12)
            }
        }
        .frame(width: w, height: h + 22)
    }
}

private struct KindBarsCard: View {
    @ObservedObject var indexer: FilesIndexer
    private let order: [FileKind] = [.document, .image, .video, .music, .app, .archive, .other]

    var body: some View {
        let years = Array(indexer.analysis.yearlyKind.keys.sorted().suffix(3))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Storage by Kind").font(.system(size: 14, weight: .bold))
            HStack(alignment: .bottom, spacing: 16) {
                ForEach(years, id: \.self) { y in
                    VStack(spacing: 5) {
                        let segs = segments(year: y)
                        let total = max(segs.reduce(0) { $0 + $1.1 }, 1)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08))
                                .frame(width: 44, height: 140)
                            VStack(spacing: 0) {
                                ForEach(segs.reversed(), id: \.0) { kind, bytes in
                                    kindColor(kind)
                                        .frame(width: 44, height: max(2, 140 * Double(bytes) / Double(total)))
                                }
                            }
                            .frame(width: 44, height: 140, alignment: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Text("\(y)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if years.isEmpty {
                    Text("No dated files yet.").font(.system(size: 12)).foregroundStyle(.tertiary)
                        .frame(height: 140)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(order.filter { hasData($0, years: years) }, id: \.self) { k in
                    HStack(spacing: 6) {
                        Circle().fill(kindColor(k)).frame(width: 8, height: 8)
                        Text(k.label).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text(byteString(yearTotal(k, years: years)))
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1)
        }
    }

    private func segments(year: Int) -> [(FileKind, Int64)] {
        let m = indexer.analysis.yearlyKind[year] ?? [:]
        return order.compactMap { k in
            let b = m[k] ?? 0
            return b > 0 ? (k, b) : nil
        }
    }

    private func hasData(_ k: FileKind, years: [Int]) -> Bool {
        years.contains { (indexer.analysis.yearlyKind[$0]?[k] ?? 0) > 0 }
    }

    private func yearTotal(_ k: FileKind, years: [Int]) -> Int64 {
        years.reduce(0) { $0 + (indexer.analysis.yearlyKind[$1]?[k] ?? 0) }
    }
}

private struct RecentUploadsCard: View {
    @ObservedObject var indexer: FilesIndexer
    var open: (IndexedFile) -> Void

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Uploads").font(.system(size: 14, weight: .bold))
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            HStack {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Source").frame(width: 150, alignment: .leading)
                Text("Date").frame(width: 100, alignment: .leading)
                Text("Size").frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.white.opacity(0.04))
            ForEach(indexer.recents(limit: 8), id: \.id) { f in
                RecentUploadRow(file: f, icon: indexer.fileIcon(f), open: open)
            }
        }
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1)
        }
    }
}

private struct RecentUploadRow: View {
    let file: IndexedFile
    let icon: NSImage
    var open: (IndexedFile) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button { open(file) } label: {
                HStack {
                    Image(nsImage: icon)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(file.kind.label).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(file.sourceHost ?? "—").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    Text(RecentUploadsCard.dateFormatter.string(from: file.modified))
                        .font(.system(size: 12)).frame(width: 100, alignment: .leading)
                    Text(byteString(file.size)).font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            Divider().background(.white.opacity(0.06)).padding(.leading, 60)
        }
    }
}
