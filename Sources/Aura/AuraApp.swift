import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - Panel that can become key (required for TextField focus)

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Hotkey (Carbon, no Accessibility permission needed)
// Single global shortcut: Ctrl+Space only.

nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
nonisolated(unsafe) private weak var sharedDelegate: AppDelegate?

private let hotKeyProc: EventHandlerUPP = { _, _, _ in
    DispatchQueue.main.async {
        sharedDelegate?.toggle()
    }
    return noErr
}

extension Notification.Name {
    static let toggleLauncher = Notification.Name("toggleLauncher")
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: LauncherPanel!
    private var statusItem: NSStatusItem!

    // Single source of truth: Samsung-style store (every ⌘C lands here).
    private var clipboard: ClipboardManager!
    private var selectionMonitor: SelectionMonitor!
    private var bubble: SaveBubbleController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedDelegate = self
        NSApp.setActivationPolicy(.accessory)

        clipboard = ClipboardManager()

        setupPanel()
        setupMenuBar()
        registerHotKey()
        observeOutsideClicks()
        setupSelectionBubble()

        show()
    }

    // MARK: Panel

    private func setupPanel() {
        let rect = NSRect(x: 0, y: 0, width: 940, height: 620)
        panel = LauncherPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow

        let view = HistoryWindowView(
            clipboard: clipboard,
            onPaste: { [weak self] in self?.hide() },
            onEscape: { [weak self] in self?.hide() }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
    }

    // MARK: Selection bubble ("Save to Aura" on any text selection)

    private func setupSelectionBubble() {
        bubble = SaveBubbleController()
        bubble.onSave = { [weak self] text in
            self?.clipboard.saveText(text, pinned: true)
        }
        selectionMonitor = SelectionMonitor()
        selectionMonitor.onSelection = { [weak self] text in
            guard let self else { return }
            // Don't fight the history panel.
            if self.panel.isVisible { return }
            self.bubble.show(for: text)
        }
        selectionMonitor.onClear = { [weak self] in
            self?.bubble.hide()
        }
        selectionMonitor.start()

        // Nudge for Accessibility once — the bubble depends on it.
        // The history panel itself works without it.
        let prompted = UserDefaults.standard.bool(forKey: "aura.axPrompted")
        if !prompted && !AccessibilityPermission.isTrusted() {
            UserDefaults.standard.set(true, forKey: "aura.axPrompted")
            // Small delay so the main panel paints first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AccessibilityPermission.prompt()
            }
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clipboard.fill", accessibilityDescription: "Aura Clipboard")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Aura  (⌃Space)", action: #selector(showFromMenu), keyEquivalent: ""))
        pauseItem = NSMenuItem(title: "Pause Aura", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(NSMenuItem(title: "Enable select-to-save bubble…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Aura", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private var pauseItem = NSMenuItem()

    @objc private func togglePause() {
        clipboard.paused.toggle()
        pauseItem.title = clipboard.paused ? "Resume Aura" : "Pause Aura"
    }

    @objc private func openAccessibility() { AccessibilityPermission.prompt() }

    @objc private func showFromMenu() { show() }

    // MARK: Show / hide

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        bubble?.hide()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }

    // MARK: Outside click -> hide (Raycast behavior)

    private func observeOutsideClicks() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            // If the click is on our own panel, AppKit still reports it globally;
            // check mouse location against panel frame.
            let mouse = NSEvent.mouseLocation
            if !self.panel.frame.contains(mouse) {
                DispatchQueue.main.async { self.hide() }
            }
        }
    }

    // MARK: Global hotkey: ⌃Space only

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Install handler once
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyProc,
            1,
            &eventType,
            nil,
            nil
        )

        // 'AURA' signature — Ctrl+Space only
        let signature: OSType = 0x41555241
        let hid = EventHotKeyID(signature: signature, id: 1)
        let mods = UInt32(controlKey)
        RegisterEventHotKey(UInt32(kVK_Space), mods, hid, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - App entry

@main
struct AuraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Accessory app: no main window, only floating panel + menu bar.
        Settings {
            EmptyView()
        }
    }
}
