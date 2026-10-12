import AppKit
import SwiftUI

/// Samsung-style clipboard history: every ⌘C lands here, search + ⏎ pastes.
/// This is the entire product surface — Aura *is* the clipboard manager.
struct ClipboardPanelView: View {
    @ObservedObject var clipboard: ClipboardManager
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var axTrusted: Bool = AccessibilityPermission.isTrusted()
    @FocusState private var searchFocused: Bool

    var onPaste: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    private var results: [ClipboardEntry] {
        Array(clipboard.search(query, limit: 30))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !axTrusted { axBanner }
            Divider().opacity(0.6)
            list
            footer
        }
        .frame(width: 680, height: 442)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 40, x: 0, y: 20)
        .onAppear {
            searchFocused = true
            axTrusted = AccessibilityPermission.isTrusted()
        }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            axTrusted = AccessibilityPermission.isTrusted()
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: results.count) { _, _ in
            if selectedIndex >= results.count { selectedIndex = max(0, results.count - 1) }
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { pasteSelected(); return .handled }
        .onKeyPress(.escape) { onEscape?(); return .handled }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.mint.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: "clipboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.mint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Aura Clipboard")
                    .font(.system(size: 15, weight: .semibold))
                Text(query.isEmpty ? "Everything you copy lives here" : "\(results.count) matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("", text: $query, prompt: Text("Search clips…").foregroundColor(.secondary))
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { pasteSelected() }
                .frame(width: 220)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            kbd("esc")
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: - AX banner

    private var axBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.cursor")
                .foregroundStyle(.orange)
            Text("Select-to-save bubble needs Accessibility access")
                .font(.system(size: 12.5, weight: .medium))
            Spacer()
            Button("Grant…") { AccessibilityPermission.prompt() }
                .buttonStyle(.link)
                .font(.system(size: 12.5, weight: .semibold))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.10))
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { idx, entry in
                        ClipRow(
                            entry: entry,
                            selected: idx == selectedIndex,
                            onPaste: { paste(entry) },
                            onPin: { clipboard.togglePin(entry) },
                            onDelete: { clipboard.delete(entry) }
                        )
                        .id(entry.id)
                        .onHover { if $0 { selectedIndex = idx } }
                    }
                    if results.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: clipboard.entries.isEmpty ? "clipboard" : "magnifyingglass")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text(clipboard.entries.isEmpty ? "Nothing saved yet" : "No matches")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(clipboard.entries.isEmpty
                                 ? "Copy anything with ⌘C — it lands here.\nOr select text anywhere → Save to Aura."
                                 : "Try a different search.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 64)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .frame(height: 308)
            .onChange(of: selectedIndex) { _, idx in
                if idx < results.count {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(results[idx].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            hint(key: "↑↓", label: "navigate")
            hint(key: "⏎", label: "paste")
            hint(key: "esc", label: "hide")
            Spacer()
            if !clipboard.entries.isEmpty {
                Button("Clear unpinned") { clipboard.clearAll() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text("Aura")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .background(.white.opacity(0.04))
    }

    private func hint(key: String, label: String) -> some View {
        HStack(spacing: 6) {
            kbd(key)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func kbd(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    // MARK: - Actions

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
}

// MARK: - Row

private struct ClipRow: View {
    let entry: ClipboardEntry
    let selected: Bool
    var onPaste: () -> Void
    var onPin: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.mint.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.mint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.preview.isEmpty ? "(empty)" : entry.preview)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if entry.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(kindLabel) • \(entry.ageString) • ⏎ to paste")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { onPaste() }

            Spacer()

            if selected {
                Button(action: onPin) {
                    Image(systemName: entry.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(entry.pinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(entry.pinned ? "Unpin" : "Pin (survives Clear)")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete")

                Image(systemName: "return")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? .white.opacity(0.10) : .clear)
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private var icon: String {
        switch entry.type {
        case .link: return "link"
        case .email: return "envelope"
        case .text: return "text.alignleft"
        }
    }

    private var kindLabel: String {
        switch entry.type {
        case .link: return "Link"
        case .email: return "Email"
        case .text: return "Text"
        }
    }
}
