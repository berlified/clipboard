import AppKit
@preconcurrency import ApplicationServices

// MARK: - Accessibility permission

enum AccessibilityPermission {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt once ("Aura would like to control this computer").
    /// Call at launch; harmless if already trusted.
    static func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        // Deep-link straight to Accessibility in System Settings.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Selection monitor

/// Polls the frontmost app's focused element for selected text via the
/// Accessibility API and reports stable selections. No event taps, no key
/// logging — we only read `kAXSelectedTextAttribute`.
@MainActor
final class SelectionMonitor {
    /// Called with the selected text once it is stable (2 polls in a row).
    var onSelection: ((String) -> Void)?
    /// Called when the selection is cleared / focus moves away.
    var onClear: (() -> Void)?

    private var timer: Timer?
    private var pendingText: String?
    private var lastShownText: String?
    private let interval: TimeInterval = 0.4

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard AccessibilityPermission.isTrusted() else { return }
        guard let text = Self.selectedText(), !text.isEmpty else {
            pendingText = nil
            if lastShownText != nil {
                lastShownText = nil
                onClear?()
            }
            return
        }
        // Require stability across 2 polls so dragging doesn't flicker the bubble.
        if pendingText != text {
            pendingText = text
            return
        }
        // Stable — but only fire once per distinct selection.
        guard lastShownText != text else { return }
        lastShownText = text
        onSelection?(text)
    }

    /// Returns the currently selected text in the frontmost app, or nil.
    /// Nil when: no selection, unsupported control, our own UI is focused.
    static func selectedText() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        // Never react to selections inside our own panels (search field etc.).
        // SPM binary has no bundle ID, so match on process name.
        if front.localizedName == "Aura" { return nil }

        let pid = front.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return nil }

        let element = focusedRef as! AXUIElement
        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &textRef
        ) == .success, let s = textRef as? String else { return nil }

        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 20_000 else { return nil }
        return s
    }
}
