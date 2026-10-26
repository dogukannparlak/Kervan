**English** · [Türkçe](README.tr.md)

# Kervan

A native macOS download manager in the spirit of IDM, built on [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [aria2](https://aria2.github.io/).
It does not reimplement downloading: it queues, supervises and presents the best existing tools.

**Status: v0.5.** Menu bar app, background service, CLI and a Chromium extension (Brave/Chrome/Edge).

- "Download this video" button over videos, with a quality picker (resolution and approximate size)
- Queue with pause / resume / cancel / retry, survives app and terminal restarts
- Clipboard watcher, drag and drop, macOS notifications
- Per-type folders, subtitles, MP3 extraction, automatic yt-dlp updates (signature-verified when `gpg` is installed)
- Downloaded files get the macOS quarantine flag, like browser downloads

> The user interface and most documentation are currently in Turkish. See [README.tr.md](README.tr.md) for the full command and extension guide.

## Requirements

- macOS 15 or later, Swift 6 toolchain (Xcode 16+)
- `yt-dlp`, `ffmpeg`, `aria2`, `deno` (installed by `scripts/install-deps.sh`, uses Homebrew)

## Quick start

```bash
scripts/install-deps.sh                 # yt-dlp, ffmpeg, aria2, deno
swift build -c release
.build/release/kervan service install   # installs and starts kervand as a LaunchAgent
.build/release/kervan app install       # ~/Applications/Kervan.app (menu bar + window)
.build/release/kervan extension install # Native Messaging bridge for Brave/Chrome/Edge
alias kervan=$PWD/.build/release/kervan

kervan add <url> -w        # queue a download and watch it
kervan list                # current queue (--all includes finished)
kervan formats <url>       # quality options with approximate sizes
kervan doctor              # tools, service and update status
```

Browser extension: open `brave://extensions` (or `chrome://extensions`), enable Developer mode,
choose **Load unpacked**, and select the `extension/` folder. The extension ID is pinned by the
`key` field in `manifest.json`, so the native messaging bridge works without further setup.

## Architecture

`kervand` (LaunchAgent) is the single owner of the queue; the app, CLI and extension talk to it over a
local Unix socket. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (Turkish).

| Module | Role |
|---|---|
| `EngineCore` | process runner, URL classification, yt-dlp and aria2 adapters |
| `QueueKit` | queue, state machine, persistence |
| `KervanIPC` | socket protocol, settings, paths |
| `kervand` | background service |
| `kervan` | CLI |
| `KervanApp` | SwiftUI menu bar app |
| `kervan-native-host` | browser extension bridge |

## Tests

```bash
swift test
node --test extension/test/*.test.mjs
```

## Scope and responsibility

DRM-protected services are out of scope. Kervan is a tool: you are responsible for having the right
to download the content you fetch. yt-dlp, ffmpeg, aria2 and deno are separate projects with their own licenses.

## License

[MIT](LICENSE)
