<p align="center">
  <img src="macos/Resources/icon.png" width="128" alt="Claude Usage Bar icon">
</p>

# Claude Usage Bar

Have you ever found yourself refreshing the Claude usage page, wondering how close you are to hitting your rate limit? Yeah, I've been there too. So I built this.

Now it's just a glimpse away — always sitting at the top of your screen.

<p align="center">
  <img src="macos/Resources/demo.png" width="400" alt="Claude Usage Bar demo">
</p>

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-BSD--2--Clause-green)

## What it does

A tiny macOS menu bar app that shows your Claude API usage at a glance. Click it for the full picture:

- Menu bar icon with a mini dual-bar showing 5-hour and 7-day utilization
- Detailed popover with per-window usage, per-model breakdown, and reset timers
- Extra usage tracking with USD currency display
- Usage history chart — see how your usage evolves over time (1h / 6h / 1d / 7d / 30d)
- Hover over the chart to see exact values at any point
- Configurable polling interval (5m / 15m / 30m / 1h)
- Built-in update checks via Sparkle
- Just sign in — OAuth via browser, no API keys to manage
- Minimal dependencies — SwiftUI, Swift Charts, Foundation, and Sparkle for updates

## Install

### Download

1. Download `ClaudeUsageBar.zip` from the [latest release](https://github.com/Blimp-Labs/claude-usage-bar/releases/latest)
2. Extract and drag `ClaudeUsageBar.app` to `/Applications`
3. On first launch: right-click the app → **Open** (required for ad-hoc signed apps)

### Build from source

Requires Xcode 15+ / Swift 5.9+ and macOS 14 (Sonoma) or later.

```sh
git clone https://github.com/Blimp-Labs/claude-usage-bar.git
cd claude-usage-bar
make app            # build .app bundle
make install        # copy to /Applications
```

## Usage

1. Launch the app — a menu bar icon appears
2. Click the icon → **Sign in with Claude** → authorize in your browser
3. Paste the code back into the app
4. The icon updates automatically (default: every 30 minutes)
5. Release builds show **Check for Updates…** in the popover so you can pull newer versions without re-downloading manually

Click the icon anytime to see:
- 5-hour and 7-day usage with progress bars and reset timers
- Per-model breakdown (Opus / Sonnet) when available
- Extra usage credits and limits
- Usage history chart with adjustable time range and hover details

## Data storage

All data is stored locally in `~/.config/claude-usage-bar/`:

| File | Purpose |
|------|---------|
| `token` | OAuth access token (permissions: `0600`) |
| `history.json` | Usage history for the chart (30-day retention) |

History is buffered in memory and flushed to disk every 5 minutes and on app quit. No data is sent anywhere other than the Anthropic API.

## Development

```sh
make build          # release build only
make app            # build + create .app bundle
make zip            # build + bundle + zip + verify distribution artifact
make verify-release # inspect the packaged zip artifact
make install        # build + install to /Applications
make clean          # remove build artifacts
```

## Publishing updates

This repo now uses a tag-driven release flow. Pushing a `v*` tag will:

- build `ClaudeUsageBar.zip`
- verify the extracted zip contains the expected app bundle resources and updater framework
- create the GitHub Release
- reuse GitHub-generated release notes for both the GitHub Release and the Sparkle update entry
- generate a signed Sparkle `appcast.xml` from that exact zip
- deploy the appcast to GitHub Pages

Publishing a release is just:

```sh
git tag v0.0.5
git push origin v0.0.5
```

One-time repo setup:

1. Enable GitHub Pages and set the source to `GitHub Actions`.
2. Add a repository Actions secret named `SPARKLE_PRIVATE_KEY`.

Local source builds intentionally ship with Sparkle disabled unless `SU_FEED_URL` is injected during packaging. This prevents forks and local builds from auto-updating to upstream binaries.

You can export the current Sparkle private key from your local Keychain with:

```sh
macos/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account claude-usage-bar -x /tmp/claude-usage-bar.sparkle.key
gh secret set SPARKLE_PRIVATE_KEY < /tmp/claude-usage-bar.sparkle.key
```

The appcast feed URL used by release builds is:

```text
https://blimp-labs.github.io/claude-usage-bar/appcast.xml
```

### Project structure

```
macos/                           # macOS menu bar app (Swift/SwiftUI)
├── Sources/ClaudeUsageBar/
│   ├── ClaudeUsageBarApp.swift      # App entry point, menu bar setup
│   ├── UsageService.swift           # OAuth, polling, API calls
│   ├── UsageModel.swift             # API response types
│   ├── UsageHistoryModel.swift      # History data types, time ranges
│   ├── UsageHistoryService.swift    # Persistence, downsampling
│   ├── UsageChartView.swift         # Swift Charts trajectory view
│   ├── PopoverView.swift            # Main popover UI
│   ├── SettingsView.swift           # Settings window
│   ├── NotificationService.swift    # Usage threshold notifications
│   ├── MenuBarIconRenderer.swift    # Menu bar icon drawing
│   ├── PollingOptionFormatter.swift # Polling interval display labels
│   ├── AppUpdater.swift             # Sparkle update integration
│   └── Resources/
│       ├── claude-logo.png          # Pre-rendered menu bar logo (512px)
│       └── en.lproj/Localizable.strings
├── Tests/ClaudeUsageBarTests/
├── Resources/                       # App bundle resources (not SwiftPM)
│   ├── Info.plist
│   ├── Assets.xcassets/             # App icon
│   └── claude-logo.svg             # Source SVG for menu bar logo
├── scripts/
│   ├── build.sh                     # Build + bundle + codesign
│   └── generate-logo-png.swift      # Regenerate logo PNG from SVG
└── Package.swift

scripts/                         # Shared tooling
└── mock-server.py               # Local mock API for development
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing with the mock server, and submission guidelines.

## License

[BSD 2-Clause](LICENSE)
