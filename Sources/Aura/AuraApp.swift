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
    private var railPanel: NSPanel!
    private var flyoutPanel: LauncherPanel!
    private var statusItem: NSStatusItem!
    private var railShown = false
    private var autohide: Bool {
        get {
            if UserDefaults.standard.object(forKey: "aura.railAutohide") == nil { return true }
            return UserDefaults.standard.bool(forKey: "aura.railAutohide")
        }
        set { UserDefaults.standard.set(newValue, forKey: "aura.railAutohide") }
    }

    // Single source of truth: Samsung-style store (every ⌘C lands here).
    private var clipboard: ClipboardManager!
    private var selectionMonitor: SelectionMonitor!
    private var bubble: SaveBubbleController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedDelegate = self
        NSApp.setActivationPolicy(.accessory)

        clipboard = ClipboardManager()

        setupRail()
        setupFlyout()
        setupMenuBar()
        registerHotKey()
        observeOutsideClicks()
        setupSelectionBubble()
        startEdgeAutohide()

        // Dock-style: rail (or its sliver) is home. No flyout at launch.
        placeRail(animated: false)
        if !autohide { showRail(animated: false) }
    }

    // MARK: Rail (left-edge dock)

    private let railSize = NSSize(width: 96, height: 640)
    private let flyoutSize = NSSize(width: 380, height: 560)

    private func setupRail() {
        railPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: railSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        railPanel.isFloatingPanel = true
        railPanel.level = .floating
        railPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        railPanel.backgroundColor = .clear
        railPanel.isOpaque = false
        railPanel.hasShadow = false
        railPanel.hidesOnDeactivate = false

        let view = DockRailView(
            clipboard: clipboard,
            onLogo: { [weak self] in self?.toggleFlyout() },
            onSearch: { [weak self] in self?.showFlyout() },
            onClear: { [weak self] in self?.clipboard.clearUnpinned() },
            onPaste: { [weak self] entry in self?.clipboard.copyAndPaste(entry) },
            onPin: { [weak self] entry in self?.clipboard.togglePin(entry) },
            onDelete: { [weak self] entry in self?.clipboard.delete(entry) },
            onCopy: { [weak self] entry in self?.clipboard.copyOnly(entry) },
            onToggleBoard: { [weak self] entry, board in self?.clipboard.toggleBoard(entry, board) }
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: railSize)
        railPanel.contentView = host
    }

    private func setupFlyout() {
        flyoutPanel = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: flyoutSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        flyoutPanel.isFloatingPanel = true
        flyoutPanel.level = .floating
        flyoutPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        flyoutPanel.backgroundColor = .clear
        flyoutPanel.isOpaque = false
        flyoutPanel.hasShadow = false
        flyoutPanel.hidesOnDeactivate = false
        flyoutPanel.animationBehavior = .utilityWindow

        let view = DockFlyoutView(
            clipboard: clipboard,
            onPaste: { [weak self] in self?.hideFlyout() },
            onEscape: { [weak self] in self?.hideFlyout() }
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: flyoutSize)
        flyoutPanel.contentView = host
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
            // Don't fight the flyout.
            if self.flyoutPanel.isVisible { return }
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
        autohideItem = NSMenuItem(title: "Autohide rail", action: #selector(toggleAutohide), keyEquivalent: "")
        autohideItem.target = self
        autohideItem.state = autohide ? .on : .off
        menu.addItem(autohideItem)
        menu.addItem(NSMenuItem(title: "Enable select-to-save bubble…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Aura", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private var pauseItem = NSMenuItem()
    private var autohideItem = NSMenuItem()

    @objc private func toggleAutohide() {
        autohide.toggle()
        autohideItem.state = autohide ? .on : .off
        if autohide { hideRail(animated: true) } else { showRail(animated: true) }
    }

    @objc private func togglePause() {
        clipboard.paused.toggle()
        pauseItem.title = clipboard.paused ? "Resume Aura" : "Pause Aura"
    }

    @objc private func openAccessibility() { AccessibilityPermission.prompt() }

    @objc private func showFromMenu() { show() }

    // MARK: Show / hide (rail + flyout)

    func toggle() { toggleFlyout() }

    func show() { showFlyout() }

    func hide() { hideFlyout() }

    private var flyoutVisible: Bool { flyoutPanel.isVisible }

    private func toggleFlyout() {
        if flyoutVisible { hideFlyout() } else { showFlyout() }
    }

    private func showFlyout() {
        bubble?.hide()
        showRail(animated: true)
        placeFlyout()
        NSApp.activate(ignoringOtherApps: true)
        flyoutPanel.makeKeyAndOrderFront(nil)
        flyoutPanel.orderFrontRegardless()
    }

    private func hideFlyout() {
        flyoutPanel.orderOut(nil)
    }

    // MARK: Rail placement + Dock-style edge autohide

    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
    }

    private func railShownOrigin(on screen: NSScreen) -> NSPoint {
        let f = screen.visibleFrame
        return NSPoint(x: f.minX + 8, y: f.midY - railSize.height / 2)
    }

    private func railHiddenOrigin(on screen: NSScreen) -> NSPoint {
        let f = screen.visibleFrame
        return NSPoint(x: f.minX - railSize.width + 6, y: f.midY - railSize.height / 2)
    }

    private func placeRail(animated: Bool) {
        guard let screen = activeScreen() else { return }
        let origin = railShown || !autohide ? railShownOrigin(on: screen) : railHiddenOrigin(on: screen)
        setOrigin(of: railPanel, to: origin, animated: animated)
        if railShown || !autohide {
            railPanel.orderFrontRegardless()
        } else if !railPanel.isVisible {
            railPanel.orderFrontRegardless() // sliver must stay hittable
        }
    }

    private func showRail(animated: Bool) {
        railShown = true
        guard let screen = activeScreen() else { return }
        setOrigin(of: railPanel, to: railShownOrigin(on: screen), animated: animated)
        railPanel.orderFrontRegardless()
    }

    private func hideRail(animated: Bool) {
        railShown = false
        guard autohide, let screen = activeScreen() else { return }
        setOrigin(of: railPanel, to: railHiddenOrigin(on: screen), animated: animated)
    }

    private func setOrigin(of window: NSWindow, to origin: NSPoint, animated: Bool) {
        var frame = window.frame
        frame.origin = origin
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private func placeFlyout() {
        guard let screen = activeScreen() else { return }
        let f = screen.visibleFrame
        var x = railPanel.frame.maxX + 8
        if x + flyoutSize.width > f.maxX - 8 { x = f.maxX - flyoutSize.width - 8 }
        let y = max(f.minY + 20, min(f.midY - flyoutSize.height / 2, f.maxY - flyoutSize.height - 20))
        flyoutPanel.setFrame(NSRect(x: x, y: y, width: flyoutSize.width, height: flyoutSize.height), display: false)
    }

    private func startEdgeAutohide() {
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autohideTick() }
        }
    }

    private func autohideTick() {
        guard autohide else { return }
        let mouse = NSEvent.mouseLocation
        if flyoutVisible {
            // Flyout owns the screen; rail stays put while it's open.
            return
        }
        if !railShown {
            // 3px hot edge, like the Dock.
            let edge = activeScreen()?.visibleFrame.minX ?? 0
            if mouse.x <= edge + 3 {
                showRail(animated: true)
            }
            return
        }
        // Generous grab area so moving toward the rail doesn't dismiss it.
        let grab = railPanel.frame.insetBy(dx: -80, dy: -60)
        if !grab.contains(mouse) {
            hideRail(animated: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }

    // MARK: Outside click -> hide (Raycast behavior)

    private func observeOutsideClicks() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.flyoutPanel.isVisible else { return }
            // Clicks on rail or flyout don't dismiss; anything else does.
            let mouse = NSEvent.mouseLocation
            if !self.flyoutPanel.frame.contains(mouse) && !self.railPanel.frame.contains(mouse) {
                DispatchQueue.main.async { self.hideFlyout() }
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
