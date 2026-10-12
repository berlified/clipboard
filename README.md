# Aura — Samsung-style clipboard manager for Mac

Aura is **only** a clipboard manager. No launcher, no fluff.

- **Normal `⌘C` just works** — every copy (text, links, emails, **images**, colors) is auto-saved into history, like the Samsung keyboard clipboard.
- **Select any sentence anywhere** → a small **✨ Save to Aura** pill pops up next to your cursor → one click pins it forever.
- **`⌃Space`** opens the dark two-pane history window → search → `⏎` pastes it back into whatever app you were in.

![stack](https://img.shields.io/badge/Swift-6.2-orange) ![platform](https://img.shields.io/badge/macOS-14%2B-blue)

## The window

Dark, two-pane, ClipBook-style:

- **Toolbar** — search field, Paste-to-app, Copy, Pause/Resume, ★ favorites-only filter.
- **Left: history list** — type icons per row (doc / link / envelope / color dot / image thumbnail), single-line titles (`Image (1456x1074)` for images), ★ to favorite. Hover a row to reveal its star.
- **Right: preview + metadata**
  - Text → full selectable text; links get an Open button.
  - Images → large preview + dimensions + file size.
  - Colors (`#65a30d`, `rgb(255 100 3)`, `hsl(330 100% 50%)`) → swatch + HEX / RGB / HSL rows, each with its own copy button.
  - Metadata block: source app (with icon), type, number of copies, first/last copy time.
- **Status bar** — `↑↓` navigate, `⏎ Paste to <live frontmost app>`, `⌘K` hint, last copy time, Clear (keeps ★ favorites).

Everything stays local in `~/Library/Application Support/Aura/` (`clipboard.json` + `images/`). Password managers (1Password, Bitwarden, Keychain…) are never recorded.

## Select-to-save bubble

Select text in any app → the **✨ Save to Aura** pill appears under the cursor → click → `Saved ✓` → the text is **pinned** in history. Needs **Accessibility permission** (macOS only shares other apps' selected text with it):

1. Launch Aura — it asks once on first run, or use menu bar 📋 → `Enable select-to-save bubble…`.
2. Without it, auto-capture + history still work; only the bubble sleeps.

## Hotkey

Single global hotkey: **`⌃Space`** (Carbon, no permission needed for the hotkey itself). `esc` or click-outside hides.

⚠️ **macOS steals `⌃Space` by default** (`Input Sources → Select the previous input source`). If nothing happens: `System Settings → Keyboard → Shortcuts → Input Sources` → uncheck it → relaunch Aura.

`⏎`-to-paste synthesizes `⌘V` (wants Accessibility; otherwise it copies and you paste manually).

## Run it

Only Command Line Tools needed (no full Xcode).

```bash
git clone https://github.com/berlified/clipboard.git
cd clipboard

# dev run (window appears, terminal blocks — Ctrl+C to stop)
swift run

# or background / release
swift build -c release
./.build/release/Aura &
```

Menu bar 📋 → `Pause Aura` / `Quit Aura`.

## Code map

```
Package.swift               # swift-tools 6.0, macOS 14+, executable "Aura"
Sources/Aura/
  AuraApp.swift             # accessory app, shared ClipboardManager, ⌃Space, menu bar, bubble wiring
  ClipboardManager.swift    # pasteboard polling, image/color capture, search, paste, local JSON store
  HistoryWindowView.swift   # the two-pane window (toolbar, list, preview+metadata, status bar)
  SelectionMonitor.swift    # AX selected-text polling (stable-selection detection, no key logging)
  SaveBubble.swift          # non-activating floating pill (Save to Aura → Saved ✓)
  Model.swift               # shared fuzzy matcher
```

## Troubleshooting

- Bubble never appears → Accessibility off (see above).
- `⌃Space` does nothing → Input Sources conflict (see above).
- Copies but doesn't paste → Accessibility off; `⌘V` manually.
- History empty after copy → password fields and password managers are intentionally skipped.
