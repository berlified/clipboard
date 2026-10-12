# LiveDocs — launcher, clipboard manager & file search for Mac

LiveDocs lives in your menu bar and stays out of the way until you need it.

- **`Ctrl + Space`** → floating launcher: fuzzy app launching, calculator, system actions, clipboard history, Google fallback.
- **Copy anything (`⌘C`)** → it's auto-saved into searchable clipboard history (text, links, images, colors, code).
- **Select text in any app** → a **Save to LiveDocs** pill appears → one click pins it forever.
- **Type `files`** → storage & file browser: what your disk holds, what's eating space, duplicates, forgotten downloads, quick search.

Requires **macOS 14 or later** (Apple Silicon or Intel). Free. Your data never leaves your Mac.

## Download & install

1. Download **`LiveDocs-0.1.0.dmg`** from the [latest release](https://github.com/berlified/clipboard/releases).
2. Open the DMG and drag **LiveDocs** into **Applications**.
3. Launch it from Applications or Spotlight.

> **"Apple couldn't verify this app"?** Normal for young indie apps (we're not in the paid Developer program yet, so there's no notarization stamp).
> **Fix:** right-click (or Control-click) LiveDocs → **Open** → **Open** in the dialog. You only do this once; macOS remembers.

## First run (2 minutes)

1. Press **`Ctrl + Space`** — the launcher appears centered on screen.
2. If nothing happens: open **System Settings → Keyboard → Shortcuts → Input Sources** and uncheck *Select the previous input source* (macOS steals `Ctrl + Space` by default), then relaunch LiveDocs.
3. For the **select-to-save bubble**, grant Accessibility when asked (or menu bar icon → *Enable select-to-save bubble…* → **System Settings → Privacy & Security → Accessibility → LiveDocs ON**).
4. Optional: **System Settings → General → Login Items** → **+** → LiveDocs, so it's always there.

## Using it

| Do this | Get this |
|---|---|
| `Ctrl + Space`, type `safari` | Launch apps fuzzy-style |
| `Ctrl + Space`, type `12*34` | Calculator, `Enter` copies |
| `Ctrl + Space`, type `clip` | Search everything you ever copied, `Enter` pastes it back |
| `Ctrl + Space`, type `files` | Open the Files window (`files invoice` opens it already searching) |
| `⌘C` anywhere | Auto-saved to history |
| Select text anywhere | **Save to LiveDocs** pill → click to pin it |
| In Files: type, `↑↓ ⏎`, `Space` | Search, navigate, open, **Quick Look** preview |

**Files window highlights:** Library folders with live sizes, *Clean Up* cards showing reclaimable space (duplicates confirmed by hash, forgotten downloads, old screenshots, unused apps), *Downloaded From* grouped by real source, per-kind analytics, and a storage bar whose headline matches System Settings exactly.

**Privacy:** everything (clipboard history, file index) lives in `~/Library/Application Support/` on your Mac. Password managers are never recorded. No account, no network calls, no telemetry.

## Troubleshooting

| Problem | Fix |
|---|---|
| `Ctrl + Space` does nothing | Free the shortcut (see step 2 above) |
| "Unidentified developer" dialog | Right-click → Open (see install note) |
| Bubble never appears | Accessibility permission off |
| Pastes the copy but doesn't auto-paste | Accessibility off — `⌘V` manually |
| Files window shows "Scanning…" | First index takes ~10s on big Macs; it fills in live |

## Uninstall

Quit from the menu bar icon → delete LiveDocs from Applications → optionally delete `~/Library/Application Support/Aura/` (history + index).

## For developers

```bash
git clone https://github.com/berlified/clipboard.git
cd clipboard
./scripts/package.sh 0.1.0   # release build + LiveDocs.app + DMG in dist/
swift run                    # dev run (debug builds are much slower — daily-drive release)
```

- Native Swift (SwiftUI + AppKit), Swift Package Manager, macOS 14+, zero dependencies.
- `./.build/release/Aura --files-scan` prints the file index as JSON (headless check).
- Architecture: accessory app (`LSUIElement`), Carbon global hotkey, `NSPasteboard` polling, Accessibility selected-text monitor, background `FileManager` indexer with SHA-256 duplicate confirmation.
- Sources: `AuraApp` (shell) · `LauncherView` + `Model` (launcher) · `ClipboardManager` (capture/history) · `FilesIndexer` + `FilesWindow` (storage browser) · `SelectionMonitor` + `SaveBubble` (select-to-save).
