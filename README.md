<p align="center">
  <img src="Resources/icon.png" width="128" alt="Claude Usage Bar icon">
</p>

# Claude Usage Bar

Have you ever found yourself refreshing the Claude usage page, wondering how close you are to hitting your rate limit? Yeah, I've been there too. So I built this.

Now it's just a glimpse away — always sitting at the top of your screen.

<p align="center">
  <img src="Resources/demo.png" width="400" alt="Claude Usage Bar demo">
</p>

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-BSD--2--Clause-green)

## What it does

A tiny macOS menu bar app that shows your Claude API usage at a glance. Click it for the full picture:

- Menu bar icon with a mini dual-bar showing 5-hour and 7-day utilization
- Detailed popover with per-window usage and reset timers
- Usage history chart — see how your usage evolves over time (1h / 6h / 1d / 7d / 30d)
- Hover over the chart to see exact values at any point
- Just sign in — OAuth via browser, no API keys to manage
- Zero dependencies — pure SwiftUI, Swift Charts, and Foundation

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
4. The icon updates every 60 seconds with your current utilization

Click the icon anytime to see:
- 5-hour and 7-day usage with progress bars and reset timers
- Usage history chart with adjustable time range and hover details

## Data storage

Usage history is stored locally in `~/.config/claude-usage-bar/`:

| File | Purpose |
|------|---------|
| `history.json` | Usage history for the chart (30-day retention) |

The OAuth access token is stored in the macOS Keychain instead of a plaintext file. Existing installs using `~/.config/claude-usage-bar/token` are migrated on next launch and the legacy file is removed.

History is buffered in memory and flushed to disk every 5 minutes and on app quit. No data is sent anywhere other than the Anthropic API.

## Security notes

- The app only talks to Anthropic OAuth and usage endpoints.
- It uses PKCE for browser-based OAuth sign-in.
- The current OAuth scope remains `user:profile user:inference` to preserve compatibility with Anthropic's existing usage integration until a narrower documented scope is confirmed.

## Development

```sh
make build          # release build only
make app            # build + create .app bundle
make zip            # build + bundle + zip for distribution
make install        # build + install to /Applications
make clean          # remove build artifacts
```

### Project structure

```
Sources/ClaudeUsageBar/
├── ClaudeUsageBarApp.swift      # App entry point, menu bar setup
├── UsageService.swift           # OAuth, polling, API calls
├── UsageModel.swift             # API response types
├── UsageHistoryModel.swift      # History data types, time ranges
├── UsageHistoryService.swift    # Persistence, downsampling
├── UsageChartView.swift         # Swift Charts trajectory view
├── PopoverView.swift            # Main popover UI
└── MenuBarIconRenderer.swift    # Menu bar icon drawing
```

## License

[BSD 2-Clause](LICENSE)
