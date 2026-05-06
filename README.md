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

## Unreleased

### Service status indicator

When a Claude service incident is detected, the Claude logo in the menubar is tinted to signal severity. The indicator is **off by default** — enable it in Settings → Service Status.

When enabled, the app polls `https://status.claude.com` (Statuspage.io public API, `/api/v2/summary.json`) and filters to three components: **Claude API**, **claude.ai**, and **Claude Code**. A single severity is computed as the maximum across those components:

| Logo | Meaning |
|------|---------|
| Unchanged | All monitored components operational |
| Yellow tint | One or more components under maintenance |
| Orange tint | Degraded performance or partial outage on any component |
| Red tint | Major outage on any component |

**Settings** (Settings → Service Status):

- **Show Claude service status** — master toggle (default off)
- **Show non-operational statuses** — surface non-operational severities in the menubar
- **Poll interval** — 1 / 5 / 15 / 30 min (default 5 min)

Polling pauses on system sleep and resumes on wake. On network error the logo tint is removed and the popover shows "Status unavailable"; polling backs off exponentially (up to 30 min) until the next successful response.

Clicking the Service Status section in the popover opens `https://status.claude.com` in your default browser.

**Privacy:** the status endpoint is a public read-only API. No authentication headers are sent and no personal data leaves the device.

> **Known follow-up (QA-flagged):** the menubar icon tooltip (`NSStatusItem.button.toolTip`) is not yet wired to the status text; the per-component status is visible in the popover instead.

### Reset-time divider & appearance settings

A vertical divider on the usage progress bars shows when your usage bucket resets. The divider position indicates where in the reset window you are, and its color signals your usage intensity:

- **Neutral** (gray) — normal state, plenty of time remaining
- **Warning** (orange) — less than 33% of the reset window remaining
- **Critical** (dark orange) — high usage (≥80%) in any time window
- **In limit** (red) — both high usage AND late in the window (highest alert)

The divider appears on both the 5-hour and 7-day usage bars in the popover.

**Appearance settings** (in the app's Settings window):

- **Show reset time divider** — toggle to hide the divider from the menu bar icon and popover
- **Colored status** — toggle between semantic colors (above) and a neutral gray for all states; disabled when the divider is hidden

## Install

### Download

1. Download `ClaudeUsageBar.dmg` from the [latest release](https://github.com/Blimp-Labs/claude-usage-bar/releases/latest)
2. Open the disk image and drag `ClaudeUsageBar.app` into `Applications`
3. Launch the app from `/Applications`
4. macOS may require right-click → **Open** on first launch

### Build from source

Requires Xcode 15+ / Swift 5.9+ and macOS 14 (Sonoma) or later.

```sh
git clone https://github.com/Blimp-Labs/claude-usage-bar.git
cd claude-usage-bar
make app            # build .app bundle
make dmg            # build drag-to-Applications disk image
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
make dmg            # build + bundle + DMG + verify distribution artifact
make release-artifacts  # build once, then create and verify both ZIP and DMG
make verify-release # inspect the packaged ZIP and DMG artifacts
make install        # build + install to /Applications
make clean          # remove build artifacts
```

## Publishing updates

This repo now uses a tag-driven release flow. Pushing a `v*` tag will:

- build the `.app` bundle once
- produce `ClaudeUsageBar.zip` for Sparkle and `ClaudeUsageBar.dmg` for manual installs
- verify the packaged artifacts contain the expected app bundle resources and updater framework
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

Manual installs should prefer the DMG. The ZIP remains the source of truth for Sparkle updates and appcast generation.

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
│   ├── MenuBarIconRenderer.swift    # Menu bar icon drawing + status logo tint
│   ├── StatusPageClient.swift       # Statuspage.io v2 API client
│   ├── StatusPageModels.swift       # Decodable models for status API responses
│   ├── ClaudeServiceStatus.swift    # Severity enum + rollup + component filter
│   ├── StatusMonitor.swift          # Polling, backoff, sleep/wake lifecycle
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
