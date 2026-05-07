# macOS Widgets Stats from Website

**See any number on any logged-in webpage at a glance — without opening another tab.**

[![Status](https://img.shields.io/badge/status-v0.12.4-orange.svg)](PLAN.md)
[![Release](https://github.com/EthanSK/macos-widgets-stats-from-website/actions/workflows/release.yml/badge.svg)](https://github.com/EthanSK/macos-widgets-stats-from-website/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2013%2B-blue.svg)](#)
[![Website](https://img.shields.io/badge/website-ethansk.github.io-7eecaf.svg)](https://ethansk.github.io/macos-widgets-stats-from-website/)
[![Latest release](https://img.shields.io/github/v/release/EthanSK/macos-widgets-stats-from-website?include_prereleases&sort=semver&label=release&color=ffe27a)](https://github.com/EthanSK/macos-widgets-stats-from-website/releases)

A native macOS WidgetKit app that surfaces scraped values from any web page you
log into — analytics dashboards, billing pages, storefront stats, your AWS bill,
your bank balance, anything that has a number or visual region on a page.
Configure it once with a click-to-pick element flow, and the widget keeps
refreshing in the background.

[Website](https://ethansk.github.io/macos-widgets-stats-from-website/) · [Direct download](https://github.com/EthanSK/macos-widgets-stats-from-website/releases/latest/download/MacosWidgetsStatsFromWebsite-latest.zip) · [Architecture (PLAN.md)](PLAN.md) · [Issues](https://github.com/EthanSK/macos-widgets-stats-from-website/issues) · [Releases](https://github.com/EthanSK/macos-widgets-stats-from-website/releases)

> **Status:** v0.12.4 implements the local app, widget extension, CLI, scraping,
> snapshot rendering, widget template catalog, selector packs, MCP server,
> first-launch flow, and polish pass. Read
> [PLAN.md](PLAN.md) for detailed architecture notes and the roadmap.

---

## Build

```bash
brew install xcodegen
xcodegen
open MacosWidgetsStatsFromWebsite.xcodeproj

# Headless Debug builds:
xcodebuild -project MacosWidgetsStatsFromWebsite.xcodeproj -scheme MacosWidgetsStatsFromWebsite -configuration Debug DEVELOPMENT_TEAM=T34G959ZG8 build
xcodebuild -project MacosWidgetsStatsFromWebsite.xcodeproj -scheme MacosWidgetsStatsFromWebsiteWidget -configuration Debug DEVELOPMENT_TEAM=T34G959ZG8 build
xcodebuild -project MacosWidgetsStatsFromWebsite.xcodeproj -scheme MacosWidgetsStatsFromWebsiteCLI -configuration Debug DEVELOPMENT_TEAM=T34G959ZG8 build
```

The project uses Ethan's Apple Developer team for local signing. For compile-only
agent checks on machines without signing assets, pass `CODE_SIGNING_ALLOWED=NO`
on the command line. The app and widget targets are sandboxed and share data
through the App Group container.

## Updates

macOS Widgets Stats from Website uses Sparkle for automatic updates. Signed releases publish a
Sparkle appcast at
`https://ethansk.github.io/macos-widgets-stats-from-website/appcast.xml`; installed apps check
that feed daily and can also check on demand from **Check for Updates...** in
the app menu. GitHub Releases also keep a stable latest-download alias at
`https://github.com/EthanSK/macos-widgets-stats-from-website/releases/latest/download/MacosWidgetsStatsFromWebsite-latest.zip`.
See [docs/release.md](docs/release.md) for release setup and validation gates.

## Features

- Text and snapshot trackers for pages opened through the app's local Chrome/Chromium CDP profile.
- Shared browser profile between setup, manual re-identify, MCP identify requests, and app-owned scraping.
- Snapshot mode that captures the selected page region through Chrome/CDP and refreshes from the app scheduler.
- Twelve WidgetKit templates for small, medium, large, and macOS 14 extra-large
  families, with separate widget configurations per widget instance.
- Clear broken-tracker status and a re-identify flow when a page layout changes.
- Embedded MCP server over stdio and a `0600` UNIX socket with Keychain-backed
  shared-token auth.
- Selector packs for importing and exporting trusted, script-free tracker
  definitions.
- First-launch wizard for opening Chrome, identifying the first element, and adding
  the first widget.
- Widget polish: animated value changes, attention states, VoiceOver labels,
  Dynamic Type support, Reduce Motion respect, keyboard shortcuts, Dock badge,
  and placeholder app icon.

## Configuration

The widget reads a JSON config from
`~/Library/Application Support/macOS Widgets Stats from Website/trackers.json`. Each tracker
has a target URL, a CSS selector or element bounding rect, a refresh interval,
and a render mode (Text or Snapshot). Widget configurations live in the same
file as named instances with a size, template, and tracker list. See
[PLAN.md §5 Configuration schema](PLAN.md#5-configuration-schema) for the full
shape and migration strategy.

## Setup walkthrough

1. Open **macOS Widgets Stats from Website.app**.
2. On first launch, paste any page URL and click **Continue**, or skip the
   wizard and open Preferences directly.
3. Pick **Text** or **Snapshot** mode and choose the first widget template.
4. Click **Open Chrome and Identify Element**. Sign in or navigate in Chrome if
   needed, hover the value or page region until it lights up, then click to
   capture and preview it.
5. Click **Save Tracker** to create the tracker and its first widget
   configuration.
6. Add the widget from macOS: right-click the desktop or Notification Centre,
   choose **Edit Widgets**, search for **macOS Widgets Stats from Website**,
   and drag the widget onto the desktop. Then click/right-click the placed
   widget, choose **Edit “macOS Widgets Stats from Website”**, and pick the
   saved configuration to show. Desktop widgets require macOS 14 or later.

Open **Preferences → Widgets** later to create, duplicate, edit, or rename widget
configurations. The desktop widget configuration picker reads from the shared
app-owned configuration store.

## Wiring up an AI agent (optional)

The app embeds an MCP server. Any external MCP client or local automation can
connect to it and manage trackers, trigger scrapes, request the visible
element-identification flow, repair stale/broken tracker state after a manual
fix, attach a generic broken-tracker webhook, and manage widget configurations.
The app itself never spawns AI binaries; agent involvement always runs in your
own agent's session. See
[PLAN.md §13 MCP Server](PLAN.md#13-mcp-server) for transport, auth, and the
complete tool catalog.

The server supports standard MCP/JSON-RPC `Content-Length` framing over stdio
when launched as an MCP subprocess, plus a local UNIX socket while the app is
running. Preferences → MCP shows the exact socket path and current launch token.
Socket clients authenticate with either an `X-Auth: <token>` header line before
the first JSON-RPC request or a `token` field in `initialize.params`. Stdio is
suitable for headless tracker/configuration operations; the socket transport is
required when an agent needs the live app to open the Chrome/CDP element picker for
`identify_element`.

Minimal stdio MCP config shape:

```json
{
  "mcpServers": {
    "macos-widgets-stats-from-website": {
      "command": "/Applications/macOS Widgets Stats from Website.app/Contents/MacOS/MacosWidgetsStatsFromWebsite",
      "args": ["--mcp-stdio"]
    }
  }
}
```

Useful setup flow for an assistant:

1. Call `get_status` and `tools/list`.
2. If a selector is already known, call `add_tracker`; otherwise call
   `identify_element` over the app socket and have the user pick the element in
   the Chrome/CDP picker.
3. Call `trigger_scrape` to verify the reading.
4. Call `update_widget_configuration` to create the widget layout.
5. If a tracker later becomes stale/broken, inspect it with `list_trackers` /
   `get_tracker`, repair it with `update_tracker` or socket-only
   `identify_element`, then `trigger_scrape` or `reset_tracker_failure_state` if
   verification must wait for the next scheduled scrape.

## Caveats

- **Browser profile reality.** The app's user-facing browser path is the
  persistent Chrome/Chromium CDP profile. This avoids embedded-browser OAuth
  dead ends and keeps setup, re-identify, MCP identify, and scraping on the same
  local browser session. See [docs/google-auth-cdp-path.md](docs/google-auth-cdp-path.md).
- **Local-only scraping.** The app signs in *as you* on this Mac. Cookies stay
  on your machine. No third-party server is involved. If a site changes its
  layout the app marks the tracker stale or broken after repeated failures and
  prompts you to re-identify the element.
- **macOS has no widget reload budget.** Apple's per-instance ~40–72/day cap
  is iOS-only ([Apple forum 711091](https://developer.apple.com/forums/thread/711091)).
  On macOS the app refreshes the widget whenever a meaningful new reading
  lands — see [PLAN.md §9.2](PLAN.md#9-widget-ui).
- **Not affiliated with OpenAI, Anthropic, or any other vendor.** This is a
  user tool that reads pages you can already see in your own browser.
- **TOS responsibility is yours.** Some sites disallow scraping in their
  terms. The app treats every site equally; you decide what to point it at.

## Contributing

Issues and PRs welcome at
[github.com/EthanSK/macos-widgets-stats-from-website](https://github.com/EthanSK/macos-widgets-stats-from-website).
Read [PLAN.md](PLAN.md) before opening a structural PR — that's the detailed
architecture document and the place where intent gets argued out before code
gets written. Bug reports and template suggestions can go straight to
[Issues](https://github.com/EthanSK/macos-widgets-stats-from-website/issues).

## Maintainer Notes

The Sparkle Ed25519 private key is stored only in Keychain, never in git. Look
for the generic password item labeled
`Sparkle Ed25519 Private Key (macos-widgets-stats-from-website)`; Sparkle's tools also have
the same key under service `https://sparkle-project.org` with account
`macos-widgets-stats-from-website`.

The release workflow needs GitHub Actions secrets for the Developer ID
certificate (`APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD`),
Apple notarization credentials (`APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`), and
`SPARKLE_ED25519_PRIVATE_KEY`. It reads the team from `APPLE_TEAM_ID` or
`DEVELOPMENT_TEAM`, with `T34G959ZG8` checked in as the fallback. Release
metadata, stable latest-download assets, appcast validation, and the Mac App
Store/TestFlight assessment are documented in [docs/release.md](docs/release.md)
and [docs/app-store.md](docs/app-store.md).

## License

[MIT](LICENSE) — copyright Ethan Sarif-Kattan, 2026.

## Acknowledgments

- **[CodexBar](https://github.com/steipete/CodexBar)**, **[MeterBar](https://meterbar.app/)**,
  **[iStat Menus](https://bjango.com/mac/istatmenus/)**,
  **[TokenTracker](https://github.com/mm7894215/TokenTracker)** — design
  patterns the widget catalog draws from. See
  [PLAN.md §9.4 Design lineage](PLAN.md#9-widget-ui).
- **[coding_agent_usage_tracker (caut)](https://github.com/Dicklesworthstone/coding_agent_usage_tracker)**
  — for the priority-ordered fallback chain pattern (CLI → web → OAuth → API
  → local logs).
- **[Producer Player](https://github.com/EthanSK/producer-player)** — for the
  setup-instruction tone, monorepo layout discipline, and the Mac App Store
  submission roadmap pattern.
- Apple's WidgetKit team for shipping a real macOS widget surface.
