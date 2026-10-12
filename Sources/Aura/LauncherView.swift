import AppKit
import SwiftUI

struct LauncherView: View {
    @StateObject private var model: LauncherModel
    @FocusState private var searchFocused: Bool

    var onRun: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    init(model: LauncherModel = LauncherModel(),
         onRun: (() -> Void)? = nil,
         onEscape: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: model)
        self.onRun = onRun
        self.onEscape = onEscape
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.6)
            resultsList
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
        }
        .onChange(of: model.query) { _, _ in
            model.resetSelection()
        }
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { runSelected(); return .handled }
        .onKeyPress(.escape) { onEscape?(); return .handled }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            TextField("", text: $model.query, prompt: promptView)
                .font(.system(size: 20, weight: .regular))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { runSelected() }

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }

            kbd("esc", trailing: 20)
        }
        .frame(height: 64)
    }

    private var promptView: Text {
        Text("Type a command, or “clip” for clipboard…").foregroundColor(.secondary)
    }

    // MARK: - Results

    private var resultsList: some View {
        let items = model.filtered
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        RowView(item: item, selected: idx == model.selectedIndex)
                            .id(item.id)
                            .onTapGesture {
                                model.selectedIndex = idx
                                runSelected()
                            }
                            .onHover { hovering in
                                if hovering { model.selectedIndex = idx }
                            }
                    }
                    if items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "moon.stars")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("No results")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .frame(height: 308)
            .onChange(of: model.selectedIndex) { _, idx in
                if idx < items.count {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(items[idx].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            hint(key: "↑↓", label: "navigate")
            hint(key: "⏎", label: "open")
            hint(key: "esc", label: "hide")
            Spacer()
            Text("\(model.filtered.count) results")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("•")
                .foregroundStyle(.quaternary)
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
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func kbd(_ s: String, trailing: CGFloat = 0) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 1))
            .padding(.trailing, trailing)
    }

    private func runSelected() {
        let items = model.filtered
        guard !items.isEmpty, model.selectedIndex < items.count else { return }
        let item = items[model.selectedIndex]
        let shouldHide = model.run(item)
        if shouldHide { onRun?() }
    }
}

// MARK: - Row

private struct RowView: View {
    let item: LauncherItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(item.category)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(selected ? 0.10 : 0.05), in: Capsule())
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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

    @ViewBuilder
    private var iconView: some View {
        if let nsImg = item.appIcon {
            Image(nsImage: nsImg)
                .resizable()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(item.tint.opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: item.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(item.tint)
            }
            .frame(width: 36, height: 36)
        }
    }
}

