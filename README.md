# Aura — Raycast-style launcher, clipboard manager & file search for Mac

Native Swift (SwiftUI + AppKit), Swift Package Manager, no Xcode project needed.

- **`⌃Space`** → floating launcher: fuzzy app launching, calculator, system actions, clipboard history (`clip`), Google fallback.
- **`⌘C` just works** — every copy (text, links, emails, images, colors, code) is auto-saved into history, Samsung-keyboard style.
- **Select text anywhere** → ✨ Save to Aura pill → one click pins it forever.
- **`files`** → storage & file browser: Homy-style dashboard (Library folders, Clean Up, Downloaded From) over a real background index of your Mac.

![stack](https://img.shields.io/badge/Swift-6.2-orange) ![platform](https://img.shields.io/badge/macOS-14%2B-blue)

## Launcher

Centered 680×442 blur panel, `↑↓ ⏎ esc`, recents on empty query, click-outside hides.

| Type this | Get this |
|---|---|
| `safari`, `term`… | Fuzzy apps with real icons |
| `12*34`, `50%*200` | Calculator → `⏎` copies |
| `dark mode`, `lock`… | System actions |
| `clip`, `clip foo` | Clipboard history search |
| `files`, `files pdf` | **Files window**, optionally pre-searched |
| anything else | Search Google for it |

## Clipboard

Local JSON store in `~/Library/Application Support/Aura/` (never leaves your Mac; 1Password/Bitwarden/Keychain never recorded). Images persist as PNGs. `⏎` on a clip copies back and auto-pastes (`⌘V` synthesized — wants Accessibility, else paste manually).

## `files` — storage & file search (the main event)

Sidebar (Home, Recents, Images/Videos/Music/Documents/Archives/Apps with live counts, Large Files, Screenshots, Duplicates + reclaimable size, Clean Up total, Downloaded From, real Locations), dashboard (greeting, `N files · X across your Mac`, global search, Refresh, pastel Library folder cards with icon stacks, Clean Up cards with big reclaim numbers, Downloaded From row), and sortable file lists (`↑↓ ⏎`, double-click opens, right-click Reveal/Copy Path).

How it works: background indexer walks Desktop/Documents/Downloads/Pictures/Movies/Music + `/Applications`, skipping packages, symlinks and dev cruft (`node_modules`, `.git`, `dist`…). Duplicates are confirmed with partial SHA-256 (no full reads of huge videos), download sources come from `com.apple.metadata:kMDItemWhereFroms`, unused apps from last-access time. Headless check: `./.build/release/Aura --files-scan` prints a JSON summary.

## Select-to-save bubble

Needs **Accessibility** (macOS only shares other apps' selected text with it): launch prompts once, or menu bar 📋 → `Enable select-to-save bubble…`. Without it, capture + history still work; only the bubble sleeps.

## Hotkey

**`⌃Space`** globally (Carbon, no permission needed). ⚠️ macOS steals it for Input Sources by default: `Settings → Keyboard → Shortcuts → Input Sources` → uncheck → relaunch Aura.

## Run it

```bash
git clone https://github.com/berlified/clipboard.git
cd clipboard
swift build -c release && ./.build/release/Aura &   # run this (optimized)
swift run                                           # dev only (debug builds are 2-5x slower)
```

> Run the **release** binary day-to-day: debug builds disable compiler optimizations and feel laggy. Full fresh file scan measured at ~12s on a 40k-file Mac (background, progressive); every open after that is instant off the on-disk index.

Menu bar 📋 → Files… / Pause / Quit.

## Code map

```
Package.swift               # swift-tools 6.0, macOS 14+, executable "Aura"
Sources/Aura/
  AuraApp.swift             # accessory app, ⌃Space, menu bar, bubble + files wiring
  LauncherView.swift        # the floating launcher UI
  Model.swift               # items, fuzzy search, calculator, apps scan, execution
  ClipboardManager.swift    # pasteboard capture (text/image/color/code), search, paste, JSON store
  FilesIndexer.swift        # background file index, dups, sources, search
  FilesWindow.swift         # Files dashboard + lists + window controller
  SelectionMonitor.swift    # AX selected-text polling (no key logging)
  SaveBubble.swift          # non-activating "Save to Aura" pill
```

## Troubleshooting

- `⌃Space` does nothing → Input Sources conflict (above).
- Bubble never appears → Accessibility off.
- Copies but doesn't paste → Accessibility off; `⌘V` manually.
- Files window empty at first → it's still scanning (progress shows top-right); hit Refresh.
