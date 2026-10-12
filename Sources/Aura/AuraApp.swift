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

    // Single source of truth: every ⌘C lands here; the launcher reads it live.
    private var clipboard: ClipboardManager!
    private var launcherModel: LauncherModel!
    private var selectionMonitor: SelectionMonitor!
    private var bubble: SaveBubbleController!
    private var filesIndexer: FilesIndexer!
    private var filesController: FilesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless test hook: scan the Mac and print JSON, then quit.
        if CommandLine.arguments.contains("--files-scan") {
            let indexer = FilesIndexer(loadPersisted: false)
            Task { @MainActor in
                await indexer.runScan()
                let summary = indexer.scanSummary()
                let data = (try? JSONEncoder().encode(summary)) ?? Data()
                print(String(data: data, encoding: .utf8) ?? "{}")
                NSApp.terminate(nil)
            }
            return
        }

        sharedDelegate = self
        NSApp.setActivationPolicy(.accessory)

        clipboard = ClipboardManager()
        launcherModel = LauncherModel(clipboard: clipboard)
        launcherModel.onOpenFiles = { [weak self] q in self?.openFiles(initial: q) }
        filesIndexer = FilesIndexer()

        setupPanel()
        setupMenuBar()
        registerHotKey()
        observeOutsideClicks()
        setupSelectionBubble()

        show()
    }

    // MARK: Files window

    func openFiles(initial query: String? = nil) {
        if filesController == nil {
            filesController = FilesWindowController(indexer: filesIndexer)
        }
        filesController?.show(initialQuery: query)
    }

    @objc private func openFilesFromMenu() { openFiles() }

    // MARK: Raycast-style floating panel

    private func setupPanel() {
        let rect = NSRect(x: 0, y: 0, width: 680, height: 442)
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

        let view = LauncherView(
            model: launcherModel,
            onRun: { [weak self] in self?.hide() },
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
            // Don't fight the launcher panel.
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
            button.image = Self.menuBarIcon()
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open LiveDocs  (⌃Space)", action: #selector(showFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Files…", action: #selector(openFilesFromMenu), keyEquivalent: ""))
        pauseItem = NSMenuItem(title: "Pause LiveDocs", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(NSMenuItem(title: "Enable select-to-save bubble…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LiveDocs", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private var pauseItem = NSMenuItem()

    @objc private func togglePause() {
        clipboard.paused.toggle()
        pauseItem.title = clipboard.paused ? "Resume LiveDocs" : "Pause LiveDocs"
    }

    @objc private func openAccessibility() { AccessibilityPermission.prompt() }

    /// Menu-bar mark, drawn once: aura gradient squircle + white fingerprint.
    nonisolated static func menuBarIcon() -> NSImage {
        let s: CGFloat = 22
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        let rect = NSRect(x: 2, y: 2, width: s - 4, height: s - 4)
        let bg = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        bg.setClip()
        let grad = NSGradient(colors: [NSColor.systemIndigo, NSColor.systemTeal])!
        grad.draw(in: rect, angle: -45)
        NSGraphicsContext.restoreGraphicsState()
        if let glyph = NSImage(systemSymbolName: "touchid", accessibilityDescription: "LiveDocs") {
            let tinted = NSImage(size: glyph.size)
            tinted.lockFocus()
            let r = NSRect(origin: .zero, size: glyph.size)
            glyph.draw(in: r, from: NSZeroRect, operation: .copy, fraction: 1.0)
            NSColor.white.setFill()
            r.fill(using: .sourceIn)
            tinted.unlockFocus()
            let gw: CGFloat = 12
            let gh = gw * glyph.size.height / glyph.size.width
            tinted.draw(in: NSRect(x: (s - gw) / 2, y: (s - gh) / 2 - 0.5, width: gw, height: gh),
                        from: NSZeroRect, operation: .sourceOver, fraction: 1.0)
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

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
