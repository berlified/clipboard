import AppKit
import SwiftUI

// MARK: - Bubble panel (never steals focus)

final class SaveBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Pill view (dark capsule, like the screenshot's inline pill)

private struct SaveBubbleView: View {
    var saved: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: saved ? "checkmark" : "sparkles")
                    .font(.system(size: 12, weight: .bold))
                Text(saved ? "Saved to LiveDocs" : "Save to LiveDocs")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(saved ? Color.green.opacity(0.9) : Color.black.opacity(0.88))
            )
            .overlay {
                Capsule().stroke(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(saved)
    }
}

// MARK: - Controller

/// Tiny floating "Save to Aura" pill that appears next to the cursor when
/// text is selected in any app. Clicking pins the selection into Aura.
@MainActor
final class SaveBubbleController {
    var onSave: ((String) -> Void)?

    private var panel: SaveBubblePanel?
    private var hideTimer: Timer?
    private var currentText: String = ""
    private var saved = false

    func show(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentText = text
        saved = false
        render()

        let mouse = NSEvent.mouseLocation
        // Below-right of the cursor, like an inline autocomplete pill.
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y - 48)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main {
            let f = screen.visibleFrame
            let size = panel?.frame.size ?? NSSize(width: 200, height: 44)
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
            origin.y = min(max(origin.y, f.minY + 8), f.maxY - size.height - 8)
        }
        panel?.setFrameOrigin(origin)
        panel?.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        currentText = ""
        saved = false
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: Private

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = SaveBubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar  // above selection highlights
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.animationBehavior = .none
        panel = p
    }

    private func render() {
        ensurePanel()
        guard let panel else { return }
        let view = SaveBubbleView(saved: saved) { [weak self] in
            Task { @MainActor in self?.tap() }
        }
        if let host = panel.contentView as? NSHostingView<SaveBubbleView> {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 44)
            panel.contentView = host
        }
    }

    private func tap() {
        guard !saved, !currentText.isEmpty else { return }
        saved = true
        let text = currentText
        render()
        onSave?(text)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }
}
