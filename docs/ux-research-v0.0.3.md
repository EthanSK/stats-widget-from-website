# macOS Widgets Stats from Website — UX & WidgetKit Research

> Research scope: Apple WidgetKit best practices, third-party widget-app survey, and a recommended catalog of 8–15 built-in widget templates for `EthanSK/macos-widgets-stats-from-website`. Produced 2026-04-28. Research only — no code changes.

---

## 1. Apple WidgetKit best practices

### 1.1 Widget sizes (verified)

macOS WidgetKit uses the same point-based `WidgetFamily` cases as iOS. Apple doesn't publish macOS-specific point values; macOS Sonoma+ renders the same SwiftUI canvas onto the desktop. Verified working dimensions (the brief's values are correct):

| Family | Points (W × H) | Use |
|---|---|---|
| `.systemSmall` | 155 × 155 | Single glanceable primary value. |
| `.systemMedium` | 329 × 155 | Headline + secondary, or 2-column. |
| `.systemLarge` | 329 × 345 | Multi-row dashboard. |
| `.systemExtraLarge` | 690 × 318 | macOS / iPad only. Dashboard-grade. |

Some Xcode templates / iPhone reference devices show ±2–3pt (158 / 338 / 354) — design to the smaller numbers as **minimum drawable area** plus default `.containerBackground`. Sources: [WidgetFamily](https://developer.apple.com/documentation/widgetkit/widgetfamily), [Supporting additional widget sizes](https://developer.apple.com/documentation/widgetkit/supporting-additional-widget-sizes), [simonbs/ios-widget-sizes](https://github.com/simonbs/ios-widget-sizes), [forum 671621](https://developer.apple.com/forums/thread/671621).

### 1.2 Padding / margins (HIG, WWDC20 *Design Great Widgets*)

- **16pt** standard edge margin for text-heavy widgets; **11pt** for graphics-dominated layouts.
- iOS 17 / macOS 14+ apply default `.contentMargins` automatically — opt out with `.contentMarginsDisabled()` only for full-bleed (e.g. Snapshot Hero).
- 4–8pt internal gap between stacked label / value / footer rows.

### 1.3 Typography for glance legibility

- **Hero number:** SF Pro Rounded, `.semibold`/`.bold`, 36–60pt; use `.minimumScaleFactor(0.5)` for long values like "$12,345.67".
- **Title:** SF Pro `.caption2` (11pt) – `.footnote` (13pt), uppercased + `.tracking(0.5)` for the "BUDGET REMAINING" aesthetic.
- Prefer `Font.TextStyle` (`.largeTitle`, `.title2`, `.caption`) over fixed sizes — Dynamic Type free.
- Never below 11pt (HIG minimum).

Sources: [Apple HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography), [Median.co](https://median.co/blog/apples-ui-dos-and-donts-typography).

### 1.4 Color / contrast & dark / light

- **WCAG AA:** 4.5:1 body text, 3:1 large text (hero numbers qualify).
- Semantic colors throughout: `Color(.label / .secondaryLabel / .systemBackground)`.
- Mark hero number + sparkline `.widgetAccentable()` so they pick up the user's chosen tint.
- Snapshot mode: subtle inner border + matte so a white page region doesn't blow out a dark wallpaper.

### 1.5 Accessibility (summary; full list in §7)

VoiceOver labels per stat block, Dynamic Type via text styles + scale factor, Reduce Motion check before sparkline anim, color-blind-safe by pairing color with directional glyphs. Source: [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).

### 1.6 Refresh / timeline guidance

This is where macOS differs sharply from iOS — see Section 6 for the full reality check. Headline guidance from Apple:

- **iOS:** ~40–70 timeline reloads / day for frequently-viewed widgets; "72 manual refreshes per day" on iOS confirmed by Apple Frameworks Engineer in [forum thread 711091](https://developer.apple.com/forums/thread/711091).
- **macOS:** **No timeline reload limit.** Same Apple engineer: *"On Mac, Widgets do not [have a budget]. On iOS the limit is 72 manual refreshes per day."*
- **Minimum spacing:** ≥5 minutes between timeline entries (per [Aymen Farrah / Medium](https://medium.com/@aymen_farrah/keeping-an-ios-widget-up-to-date-in-flutter-bcc01f6d114f) and the Apple forum thread on iOS 14 widgets).
- Use `TimelineReloadPolicy.atEnd` for "refresh as soon as we run out of entries" — appropriate when the helper process pushes new readings.
- Use `.never` and call `WidgetCenter.shared.reloadTimelines(ofKind:)` from the app/CLI when a fresh reading lands.

Sources cited inline above plus [Apple — Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date), [Swift Senpai — Refreshing a widget](https://swiftsenpai.com/development/refreshing-widget/).

---

## 2. Survey of similar widget apps

### 2.1 macOS native widgets (Apple system apps)

- **Weather** — uses one layout that scales across all three sizes. Small = current temp + condition glyph; medium = current + 5-hour timeline; large = current + 5-hour + 5-day. Pattern: **same data hierarchy, more rows added per size.**
- **Stocks** — two distinct widget *kinds*: a **watchlist** widget (medium / large = 4 / 8 tickers in a list) and a **single-ticker** widget (small = current price + sparkline). Pattern: **separate widgets for "many low-detail" vs "one high-detail".**
- **Calendar** — small = next event; medium = today's agenda; large = month grid + agenda. Pattern: **density-by-size**.
- **Battery** — small = single ring; medium = up to 3 connected devices' rings side by side. Pattern: **mini-ring multiple-up grid for medium.**

Source: [Apple Support — Add and customize widgets on Mac](https://support.apple.com/guide/mac-help/add-and-customize-widgets-mchl52be5da5/mac), WWDC20 *Design Great Widgets*.

### 2.2 Third-party widget builders

- **Widgy** ([App Store](https://apps.apple.com/us/app/widgy-widgets-home-lock-watch/id1524540481)) — a generic widget canvas. Explicitly **rejects templates** ("Forget templates"). Insight: full customization is a power-user mode; we want curated templates *plus* a free-form mode later.
- **Scriptable** (iOS, beta on macOS) — JS-driven widgets. Common templates from community: countdown, schedule, crypto price, time-progress (day/week/month/year). All single-purpose. Insight: **single-purpose templates with a clear "what is this for" name** dominate. ([awesome-scriptable](https://github.com/dersvenhesse/awesome-scriptable))
- **iStat Menus 7** — menu-bar focused but the design language for tiny stats (sparklines, gauges, per-metric color, dual-line label+bar) is the gold standard for "many tiny numbers in a small canvas." Insight: pair every number with a tiny color-coded indicator / spark. ([Bjango — iStat Menus](https://bjango.com/mac/istatmenus/))
- **Stats (exelban/stats)** — open source. Per-metric customization, but desktop widgets ship as fixed templates: CPU, RAM, Disk, Network, Battery — each is a small/medium widget with a sparkline, current value, and threshold color. ([github.com/exelban/stats](https://github.com/exelban/stats))

### 2.3 LLM-usage trackers (most relevant cohort)

This is the closest analog to `macos-widgets-stats-from-website` because the data shape is identical: a small set of numbers, scraped/polled from external services, refreshed several times an hour, displayed glanceably.

- **CodexBar** ([github.com/steipete/CodexBar](https://github.com/steipete/CodexBar)) — menu-bar app, supports 15+ providers. **Two-bar meter pattern**: top bar = 5h session window, bottom bar = weekly window. "Merge Icons Mode" combines up to 3 providers into one menu-bar icon with a switcher. Insight: **stack two metrics vertically, hairline second metric, dim/badge for error states.**
- **MeterBar** ([meterbar.app](https://meterbar.app/)) — tiered UI: menu-bar icon → notification-center widget (medium / large) → full dashboard. **Traffic-light status** (green/yellow/red). Insight: **progressive disclosure across surfaces; color-coded health is enough for the 90% glance case.**
- **TokenTracker** ([github.com/mm7894215/TokenTracker](https://github.com/mm7894215/TokenTracker)) — explicitly ships **4 desktop widgets**: Usage, Activity Heatmap, Top Models, Usage Limits. This is the strongest signal that **a curated set of 4–10 templates is the right product shape**, not infinite customization.
- **ccseva** ([github.com/Iamshankhadeep/ccseva](https://github.com/Iamshankhadeep/ccseva)) — gradient + glassmorphism aesthetic, percentage indicator with color thresholds, 7-day chart. Insight: **historical sparkline matters for "is this trending up or down" glance.**
- **Provider-specific usage trackers** — all converge on the same pattern: percentage + reset-time + small sparkline.

**Takeaway:** the consensus design vocabulary in this cohort is: **percentage / value + tiny sparkline + color-coded health + reset/refresh timestamp.** Our catalog should bake this into multiple templates explicitly.

---

## 3. Proposed widget catalog (12 configs)

Each entry: name, size, mode, tracker count, layout, accent / background, ideal user.

### Small (4 configs — must each fit ~155×155pt)

#### 3.1 Single Big Number
- **Size:** small  •  **Mode:** Text  •  **Trackers:** 1
- **Layout:** title (caption2, top-left, 11pt, secondary color) + hero number (centered, 48–56pt rounded semibold) + footer (tiny "updated 4m ago" + reset glyph, 10pt secondary).
- **Accent:** widgetAccentable hero number; background = system widget background.
- **Use case:** "I just want my Codex weekly spend, that's it."

#### 3.2 Number + Sparkline
- **Size:** small  •  **Mode:** Text  •  **Trackers:** 1 (with history)
- **Layout:** title top, hero number mid-left (40pt), sparkline bottom-right (60×30pt) showing last 24 reads. Gradient line, no axis labels.
- **Accent:** sparkline in accent; number neutral.
- **Use case:** "Is my OpenAI spend trending up today?"

#### 3.3 Gauge Ring
- **Size:** small  •  **Mode:** Text  •  **Trackers:** 1 (with min/max)
- **Layout:** circular `Gauge` (Apple's `.accessoryCircular`-style ring), 90×90pt centered, current value in the center, label below in 11pt, threshold tinting (green < 70% / amber 70–90% / red > 90%).
- **Accent:** gauge tint = threshold color.
- **Use case:** "Show me how close I am to the weekly usage cap."

#### 3.4 Live Snapshot Tile
- **Size:** small  •  **Mode:** Snapshot  •  **Trackers:** 1
- **Layout:** edge-to-edge cropped image of the page region, with a 4pt-radius rounded rect, optional 12pt overlay strip at bottom showing the tracker name + timestamp. `.contentMarginsDisabled()` to allow full-bleed.
- **Accent:** none (image-driven).
- **Use case:** "I want to see the *actual* dashboard chart, not a re-rendered number."

### Medium (4 configs — ~329×155pt)

#### 3.5 Headline + Sparkline (Hero Stat)
- **Size:** medium  •  **Mode:** Text  •  **Trackers:** 1 (with history)
- **Layout:** left half = title + hero number (60pt+); right half = larger sparkline (140×100pt) with subtle area fill + min/max labels.
- **Accent:** sparkline tint, optional gradient fill to baseline.
- **Use case:** "Codex spend, big and prominent, with the trend right next to it."

#### 3.6 Dual Stat Compare
- **Size:** medium  •  **Mode:** Text  •  **Trackers:** 2
- **Layout:** vertical divider down the middle; each side gets title + value (32pt) + delta arrow + tiny sparkline.
- **Accent:** each side's sparkline tinted with its own accent (set per tracker).
- **Use case:** "I want two service spends side-by-side."

#### 3.7 Dashboard 3-Up
- **Size:** medium  •  **Mode:** Text  •  **Trackers:** 3
- **Layout:** three equal columns. Each column: 11pt title (top), 24pt value (mid), tiny 8pt delta + reset-time (bottom). Subtle 1pt vertical separators between columns.
- **Accent:** per-tracker chip color in the title row.
- **Use case:** "I track three monthly subscriptions and want them all visible."

#### 3.8 Snapshot + Stat
- **Size:** medium  •  **Mode:** Mixed (Snapshot + Text)
- **Layout:** left half (~155×155) = cropped page screenshot tile; right half = title + hero number (40pt) + footer.
- **Accent:** hero number widgetAccentable.
- **Use case:** "Show me the OpenAI usage chart cropped on the left, and my current monthly total on the right."

### Large (3 configs — ~329×345pt)

#### 3.9 Stats List (Watchlist Style)
- **Size:** large  •  **Mode:** Text  •  **Trackers:** 4–6
- **Layout:** vertical list of rows (~50pt tall each, 6 rows fit). Each row: leading 16pt color chip, title (15pt), trailing right-aligned value (20pt mono digits) + tiny sparkline (40×16pt) + delta arrow.
- **Accent:** per-row chip; values neutral.
- **Use case:** "All my LLM spend lines in one Stocks-watchlist-style block."

#### 3.10 Hero + Detail (Single-Tracker Large)
- **Size:** large  •  **Mode:** Text  •  **Trackers:** 1 (rich)
- **Layout:** top third = title + hero number (72pt rounded bold); middle third = full-width sparkline (320×100pt) with min/max/avg axis labels; bottom third = 4-up secondary stats grid (today / week / month / cap).
- **Accent:** sparkline tint, axis lines secondary color.
- **Use case:** "Codex weekly spend, ALL the context — for someone who watches one number obsessively."

#### 3.11 Live Snapshot Hero
- **Size:** large  •  **Mode:** Snapshot  •  **Trackers:** 1
- **Layout:** edge-to-edge full snapshot of the chosen page region (full bleed, `.contentMarginsDisabled()`); top-left chip overlay: title + timestamp (compact, 10pt, glass background blur).
- **Accent:** none.
- **Use case:** "I want my OpenAI dashboard chart on the desktop as if it were a screenshot."

### Extra-Large (1 config — macOS bonus)

#### 3.12 Mega Dashboard Grid
- **Size:** extraLarge (macOS only)  •  **Mode:** Mixed  •  **Trackers:** 6–8
- **Layout:** 4×2 grid of stat tiles. Each tile = title + value (28pt) + tiny sparkline. Optional one tile slot replaceable with a snapshot.
- **Accent:** per-tile chip.
- **Use case:** "Power user dashboard — every number I care about, all in one widget."

---

## 4. Layout sketches (ASCII)

### Small (3.1–3.4)
```
3.1 Single Big Number       3.2 Number + Sparkline      3.3 Gauge Ring             3.4 Live Snapshot Tile
┌──────────────────┐        ┌──────────────────┐        ┌──────────────────┐       ┌──────────────────┐
│ CODEX WEEKLY     │        │ OPENAI MTD       │        │     ◜───◝        │       │█ snapshot of ███│
│                  │        │                  │        │    ╱  62%  ╲     │       │█ cropped page ██│
│    $42.30        │        │  $231            │        │    ╲       ╱     │       │█ region (full ██│
│                  │        │       ╱╲╱╲ ╱╲    │        │     ◟───◞        │       │█  bleed) ████████│
│ updated 4m · Mon │        │ 24h trend  ↑3%   │        │ CLAUDE WEEKLY    │       │ codex · 12:04   │
└──────────────────┘        └──────────────────┘        └──────────────────┘       └──────────────────┘
title 11pt + hero 56pt      hero 40pt + spark 60×30     ring 90×90 thresh-tint    full-bleed PNG + chip
```

### Medium (3.5–3.8)
```
3.5 Headline + Sparkline                            3.6 Dual Stat Compare
┌─────────────────────────────────────────────┐     ┌──────────────────────┬──────────────────────┐
│ CODEX WEEKLY                                │     │ CODEX WEEKLY         │ CLAUDE WEEKLY        │
│  $42.30        ╱╲   ╱╲                      │     │  $42.30              │  $18.10              │
│                ╱╲╱╲╱  ╲╱─                   │     │  ↑ $5.20  ╱╲╱╲       │  ↓ $1.30  ╱─╲╱─      │
│  ↑ $5.20 today              min:38 max:46  │     │ resets Mon           │ resets Sun           │
└─────────────────────────────────────────────┘     └──────────────────────┴──────────────────────┘

3.7 Dashboard 3-Up                                   3.8 Snapshot + Stat
┌──────────┬───────────┬────────────────────┐       ┌──────────────────┬─────────────────────────┐
│ ● CODEX  │ ● CLAUDE  │ ● OPENAI           │       │█ cropped █████████│ OPENAI MTD              │
│ $42.30   │ $18.10    │ $231.00            │       │█ snapshot ████████│  $231.00                │
│ ↑ $5.20  │ ↓ $1.30   │ ↑ $14.40           │       │█ tile ████████████│  ↑ $14.40 this week     │
│ Mon      │ Sun       │ MTD                │       │██████████████████│                         │
└──────────┴───────────┴────────────────────┘       └──────────────────┴─────────────────────────┘
```

### Large (3.9–3.11)
```
3.9 Stats List                                       3.10 Hero + Detail               3.11 Live Snapshot Hero
┌───────────────────────────────────────────┐       ┌──────────────────────────┐    ┌──────────────────────────┐
│ ● Codex Weekly    $42.30  ╱╲╱  ↑12%      │       │ CODEX WEEKLY             │    │█ full-bleed snapshot █████│
│ ● Service B       $18.10  ╲╱─  ↓7%       │       │   $42.30                 │    │█ of chosen cropped page ██│
│ ● OpenAI MTD     $231.00  ╱─╱  ↑6%       │       │   ↑ $5.20 vs yesterday   │    │█ region (no margins) █████│
│ ● Cursor Mon      $20.00  ────  →         │       │  ╱╲╱╲╱╲       ╱─╲        │    │██████████████████████████│
│ ● AWS Daily        $3.40  ╱╱╲  ↑18%      │       │       ╲╱╲╱╲╱╲╱   ╲╱──    │    │██████████████████████████│
│ ● Bank Balance £4,120.20  ╲╱╲  ↓£230     │       │ ┌────┬────┬────┬────┐    │    │ ⌐ openai · 12:04 [glass] │
│ updated 2m · auto-refresh 5m              │       │ │TDY │WK  │MO  │CAP │    │    └──────────────────────────┘
└───────────────────────────────────────────┘       │ │$5.2│$42 │$168│$200│    │
                                                    │ └────┴────┴────┴────┘    │
                                                    └──────────────────────────┘
```

### Extra-Large (3.12)
```
┌──────────────────────────────────────────────────────────────────────────┐
│ ● Service A $42.30 ╱╲╱ │ ● Service B $18.10 ╲╱─ │ ● OpenAI    $231     │
│ ● Cursor    $20.00 ─── │ ● AWS       $3.40 ╱╱╲ │ ● Bank     £4120     │
│ ● Stripe MRR $2.4k ╱── │ [SNAPSHOT TILE — chart]│ ● Cloudflare $7.10   │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Configuration UX recommendations

### 5.1 Two surfaces, both supported

Apple's standard widget configuration model is **right-click → Edit Widget** which surfaces an Intent-driven config sheet inline. This is the *system* answer and we should support it for every widget — Apple's HIG strongly assumes users discover widget config that way.

But the gallery of templates is too rich for a one-line "pick a widget" picker. Recommended:

**Surface 1 — Built-in template gallery in the main app's Preferences.**
1. User opens **macOS Widgets Stats from Website.app → Widgets** tab.
2. Gallery shows the 12 templates above as visual cards (use real screenshots / live previews where possible). Filter chips: `Small / Medium / Large / XL`, `Text / Snapshot / Mixed`, `1 tracker / 2–3 / 4+`.
3. Clicking a card opens a config detail: "This template needs N trackers. Map them:" with dropdowns populated from the user's existing tracker library.
4. **Save** writes the composition to `metrics.json` under a `widgetCompositions` key (template id + tracker bindings + per-tracker accent overrides).
5. The app then prompts: "Drag this widget to your desktop or Notification Center → Edit Widget → pick this composition by name."

**Surface 2 — Native Edit Widget (right-click on the placed widget).**
1. The widget extension exposes an `IntentConfiguration` with one parameter: `Composition` (an `AppEntityQuery` resolving to the user's saved compositions from `metrics.json`).
2. User right-clicks → Edit Widget → picks a composition from the dropdown. Done.
3. *Optional power feature:* expose individual tracker slots as separate intent parameters so a user can swap one tracker without going back to the main app.

This split — **rich gallery in app, simple binding in Edit Widget** — mirrors how Stocks works (you build a watchlist in the Stocks app, then point the widget at it via Edit Widget).

### 5.2 Default compositions

Ship 3 pre-built compositions out of the box, mapped to popular trackers if the user has them: "Codex Big Number" (3.1), "LLM Compare" (3.6), "All My Spend" (3.9). First-run experience pre-populates the gallery so a brand-new user has something to drag immediately.

---

## 6. Refresh budget reality check

### 6.1 The headline answer

**On macOS, WidgetKit imposes no daily timeline-reload budget.** This is the load-bearing finding. iOS limits frequently-viewed widgets to ~40–72 manual refreshes per day; macOS does not. Confirmed by Apple Frameworks Engineer in the [public dev forum thread 711091](https://developer.apple.com/forums/thread/711091).

Practical consequences:

- A `TimelineReloadPolicy.atEnd` with 5-minute entries on macOS is fine — that's 288 reloads/day and it'll be honored. (On iOS the same policy would be throttled around reload 50.)
- We still respect the 5-minute minimum spacing between timeline entries — that's a separate, conservative HIG recommendation, not a hard cap.

### 6.2 Per-tracker vs shared

The reload budget (where one exists, i.e., iOS) is **per widget instance**, not per tracker inside the widget. WidgetKit doesn't know what "trackers" are — it sees one timeline provider per widget kind, and each placed widget gets its own quota of reloads. So:

- A multi-tracker widget (e.g., Dashboard 3-Up with 3 trackers) consumes one shared timeline budget covering all three trackers.
- Two separate single-tracker widgets each get their own independent budget.

This matters less on macOS (no budget) but matters on iOS for any future iOS port — and informs the answer "should we encourage one big widget or many small widgets?" On macOS: doesn't matter. On iOS (future): one big widget is more efficient.

### 6.3 Snapshot / scrape decoupling

This is the architecture insight that makes the project work. The user's brief notes Snapshot mode wants ~2s polling. That **cannot** happen via widget reload — even on macOS, Apple wouldn't let you and rendering at 2s is wasteful.

The right model (and what `PLAN.md` already proposes):

1. **CLI scraper (background helper)** polls each tracker on its configured interval (could be 30s, 2s, whatever) and writes readings into the shared App Group container.
2. **Widget extension** reads the App Group on each timeline tick — tick frequency is independent of scrape frequency.
3. The widget's only job is **visual refresh**. WidgetKit's reload budget governs *visual* refresh frequency, not data freshness.
4. When a fresh reading lands and is meaningfully different, the CLI calls `WidgetCenter.shared.reloadTimelines(ofKind:)` to force the widget to redraw. On macOS this is unbounded.

So even with 2-second snapshot polling, the widget visibly updates only when a new reading actually changes, and macOS happily accepts forced reloads at high frequency.

Sources: [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date), [forum thread 711091](https://developer.apple.com/forums/thread/711091), [Swift Senpai](https://swiftsenpai.com/development/refreshing-widget/), [Aymen Farrah — Medium](https://medium.com/@aymen_farrah/keeping-an-ios-widget-up-to-date-in-flutter-bcc01f6d114f).

---

## 7. Accessibility recommendations (scraped-number specific)

- **VoiceOver:** `"<tracker name>, <current value>, <delta>, updated <relative time>"`, with `.accessibilityElement(children: .combine)` per stat block.
- **Dynamic Type:** use text styles or `.minimumScaleFactor(0.5)` so xxxLarge stays legible.
- **Color-blind:** pair threshold colors with glyphs (↑ ↓ →). Use `Color(.systemGreen / .systemOrange / .systemRed)`.
- **Dark mode:** semantic colors throughout; for snapshots apply a matte border + slight desaturation in dark scheme to avoid blow-out.
- **Reduce Motion / Transparency:** check the env values; skip sparkline animation, fall back to `.regularMaterial` when transparency reduced.
- **Localization:** `Text(value, format: .currency(code: ...))`, never hard-code "$" / "£".

---

## 8. Open questions

1. **Sparkline data depth:** how long a rolling window does `readings.json` retain? Small sparkline ~24 points, large ~100.
2. **Snapshot resolution / Retina:** target 2× the widget rect; confirm against actual scrape pipeline.
3. **App Store precedent for scraped data:** CodexBar / MeterBar — are they in MAS or Homebrew-only? Affects what we promote in MAS metadata vs. gate behind the CLI.
4. **Tracker accent ownership:** color set per tracker in `metrics.json`, or per slot in composition? Affects Dashboard 3-Up + Stats List chips.
5. **App Sandbox for snapshot PNGs:** widget reads PNGs from App Group container — should be entitlement-free, but worth a review edge-case check.
6. **Interactive widgets:** macOS 14 / iOS 17 `Button`/`Toggle` via App Intents; "Refresh now" slot reserved for v0.2.
7. **Composition naming:** human-friendly vs slug-style — affects Edit Widget dropdown UX.

---

## Sources (consolidated)

- [Apple — WidgetKit](https://developer.apple.com/documentation/widgetkit) and [WidgetFamily](https://developer.apple.com/documentation/widgetkit/widgetfamily)
- [Apple — Supporting additional widget sizes](https://developer.apple.com/documentation/widgetkit/supporting-additional-widget-sizes)
- [Apple — Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Apple — HIG: Widgets](https://developer.apple.com/design/human-interface-guidelines/components/system-experiences/widgets/)
- [Apple — HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Apple — HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple Developer Forum — macOS reload budget thread 711091](https://developer.apple.com/forums/thread/711091)
- [Apple Developer Forum — widget dimensions thread 671621](https://developer.apple.com/forums/thread/671621)
- [WWDC20 — Design Great Widgets](https://developer.apple.com/videos/play/wwdc2020/10103/)
- [WWDC23 — Bring widgets to new places](https://developer.apple.com/videos/play/wwdc2023/10027/)
- [Swift Senpai — Refreshing a widget](https://swiftsenpai.com/development/refreshing-widget/)
- [Aymen Farrah — Keeping an iOS Widget Up To Date in Flutter](https://medium.com/@aymen_farrah/keeping-an-ios-widget-up-to-date-in-flutter-bcc01f6d114f)
- [simonbs/ios-widget-sizes](https://github.com/simonbs/ios-widget-sizes)
- [Designcode — WidgetFamily sizes](https://designcode.io/swiftui-handbook-widgetfamily-sizes/)
- [CodexBar (steipete)](https://github.com/steipete/CodexBar)
- [MeterBar](https://meterbar.app/)
- [TokenTracker (mm7894215)](https://github.com/mm7894215/TokenTracker)
- [ccseva (Iamshankhadeep)](https://github.com/Iamshankhadeep/ccseva)
- [Stats — exelban](https://github.com/exelban/stats)
- [iStat Menus — Bjango](https://bjango.com/mac/istatmenus/)
- [Widgy — App Store](https://apps.apple.com/us/app/widgy-widgets-home-lock-watch/id1524540481)
- [awesome-scriptable](https://github.com/dersvenhesse/awesome-scriptable)
- [Apple Support — Add and customize widgets on Mac](https://support.apple.com/guide/mac-help/add-and-customize-widgets-mchl52be5da5/mac)
- [Median.co — Apple typography guidelines](https://median.co/blog/apples-ui-dos-and-donts-typography)
