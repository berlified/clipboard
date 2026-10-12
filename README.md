# Aura — the Samsung-style clipboard manager for Mac

Aura is **only** a clipboard manager. No launcher, no fluff.

- **Normal `⌘C` just works** — every copy is auto-saved into history, like the Samsung keyboard clipboard.
- **Select any sentence anywhere** → a small **✨ Save to Aura** pill pops up next to your cursor → one click pins it into Aura forever.
- **`⌃Space`** opens the history → search → `⏎` pastes it back.

![stack](https://img.shields.io/badge/Swift-6.2-orange) ![platform](https://img.shields.io/badge/macOS-14%2B-blue)

## The two features (that's it)

### 1. Auto-capture (`⌘C` → Aura, Samsung-style)

Copy anything in any app with `⌘C`. Aura watches `NSPasteboard` and appends it to history (text, links, emails — newest on top, de-duped, capped at 50, persisted to `~/Library/Application Support/Aura/clipboard.json`). Password managers (1Password, Bitwarden, Keychain…) are never recorded. Works with **zero permissions**.

### 2. Select-to-save bubble (the screenshot moment)

Select a sentence in any app — like the highlighted text in your screenshot — and a dark **✨ Save to Aura** pill appears right under the cursor. Click it → the text is **pinned** in Aura (pins survive Clear). It fades to `Saved ✓` and disappears.

This needs **Accessibility permission** (macOS only lets apps read other apps' selected text with it):
1. Launch Aura — it prompts once on first run.
2. Or: menu bar 📋 → `Enable select-to-save bubble…`, or `System Settings → Privacy & Security → Accessibility → Aura ON`.
3. Without it, auto-capture + history still work; only the bubble sleeps (the panel shows a slim grant banner until then).

## `⌃Space` history panel

Single global hotkey: **`⌃Space`** (Carbon hotkey, no permission needed for the hotkey itself).

- Empty → newest clips. Type to fuzzy-search. `↑↓` navigate, `⏎`/click pastes (copies back + synthesizes `⌘V`; the paste part wants Accessibility, otherwise it copies and you `⌘V` yourself).
- 📌 pin (pinned float to top, survive Clear), 🗑 delete per row, `Clear unpinned` in the footer.
- `esc` or click-outside hides.

⚠️ **macOS steals `⌃Space` by default** (`Input Sources → Select the previous input source`). If the hotkey does nothing: `System Settings → Keyboard → Shortcuts → Input Sources` → uncheck it → relaunch Aura.

## Run it

Only Command Line Tools needed (no full Xcode).

```bash
cd /Users/berlin/Desktop/pay/launcher

# dev run (panel appears, terminal blocks — Ctrl+C to stop)
swift run

# or background
swift build
./.build/debug/Aura &

# release
swift build -c release
./.build/release/Aura &
```

Menu bar 📋 → `Quit Aura` to stop.

## How it's built

```
launcher/
  Package.swift               # swift-tools 6.0, macOS 14+, executable "Aura"
  Sources/Aura/
    AuraApp.swift             # accessory app, single ClipboardManager, ⌃Space, menu bar, bubble wiring
    ClipboardManager.swift    # NSPasteboard polling, saveText(pinned:), search, copyAndPaste, local JSON store
    SelectionMonitor.swift    # AX selected-text polling (kAXSelectedTextAttribute), stable-selection detection
    SaveBubble.swift          # non-activating floating pill (Save to Aura → Saved ✓)
    ClipboardPanelView.swift  # the ⌃Space history UI (search, pin, delete, paste)
    Model.swift / LauncherView.swift  # legacy launcher code, unused since the clipboard-only pivot
```

Key tricks:

- One shared `ClipboardManager` owned by `AppDelegate` — panel + bubble use the same instance (never two timers/writers).
- Bubble is a `.nonactivatingPanel` at `.statusBar` level — it never steals focus from the app you're selecting in.
- Selection detection is poll-only (`0.4s`, stable-twice fires once); no event taps, no key logging — we only read the selected-text attribute and skip our own process.
- `NSApp.setActivationPolicy(.accessory)` — no Dock icon, menu-bar only.

## Troubleshooting

- Bubble never appears → Accessibility off (see above). Grant → select text again.
- `⌃Space` does nothing → Input Sources conflict (see above).
- `⏎` copies but doesn't paste → Accessibility off; paste manually with `⌘V`.
- History empty after copy → some apps (password fields, 1Password) are intentionally skipped.
