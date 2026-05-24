# Learnings

Per-repo institutional memory for fixes. Every entry below is a real bug we hit + how we solved it. Check this file BEFORE attempting a same-looking fix.

Maintained by the `learnings` skill — see `~/.claude/skills/learnings/skill.md`.

## Format

Each entry looks like:

```
---
**Date:** YYYY-MM-DDTHH:MM:SSZ
**Trigger:** <voice N / message snippet / null>
**Symptom:** <what was visible>
**Root cause:** <what we actually found>
**Fix:** <file:line + short prose + commit SHA>
**Guard:** <test / lint / watchdog / comment that prevents regression — or 'none'>
---
```

## Entries

(newest first)

---
**Date:** 2026-05-24T22:50:00Z
**Trigger:** Voices 4019 + 4020 (2026-05-24): "Can you increase the timeout then? So let it have longer time to load. Also, maybe set the chat GPT ones to happen every ten minutes anyway, twenty minutes. What would Cloudflare not start rate limiting me on?" + "Also, can we only show the error message if, after three consecutive failed attempts, the error notification?"
**Symptom:** ChatGPT-domain trackers were timing out at the 30s outer scrape deadline (selectorPoll deadline at ~24-25s elapsed) AND occasionally getting Cloudflare-challenged on every scrape because the 30 min default cadence sat at the edge of Cloudflare's per-IP rate-limit window. Auto-repair agent + macOS notification then fired on EVERY single transient failure, even when the next scrape recovered cleanly.
**Root cause:** (1) Cloudflare JS-challenge on chatgpt.com / *.openai.com pages can hold the metric element offscreen for 10-20s, clipping the 25s inner selector-poll deadline. Claude pages don't have this issue. (2) Hammering ChatGPT URLs every 30 min trips Cloudflare's rate heuristic; 15 min cadence stays under the threshold. (3) HookExecutor's .onFailure trigger fired immediately on first failure with no consecutive-failure gate, even though TrackerAttentionNotifier already had a `>= 3` gate for the system notification — so the two layers were inconsistent.
**Fix:** v0.21.29: added `Tracker.isChatGPTDomain(url:)`, `Tracker.scrapeTimeoutSec` (60s for ChatGPT, 30s otherwise), `Tracker.effectiveRefreshIntervalSec` (floors ChatGPT at 900s). ChromeCDPScraper armTimeout + inner selectorPoll deadline both derive from `tracker.scrapeTimeoutSec`. BackgroundScheduler.fireScrapeLifecycleHooks now suppresses .onFailure hooks when `consecutiveFailureCount < 3` AND logs the suppression. auto-repair-tracker.sh duplicates the gate defensively (in case a user-authored hook bypasses the Swift gate). Scheduler "rescheduled" log gains `configuredIntervalSec` + `domainCadenceFloor` so post-hoc you can tell whether the override fired.
**Commit:** <pending — see git log>
**Guard:** Activity-log gate: "rescheduled" log lines for ChatGPT trackers should show `intervalSec=900 domainCadenceFloor=chatgpt-15min`; "started scrape" log lines for ChatGPT trackers should show `timeoutSec=60`. Auto-repair / TrackerAttentionNotifier should both fire at the same moment (failure #3), never on failure #1.
---

---
**Date:** 2026-05-24T02:58:22Z
**Trigger:** Voice 3988 (2026-05-24): 'Again, I see selector needs something. What the fuck? Investigate the logs. ... Should we slow slow it down a bit, combine them, stagger them better? Maybe it needs to be staggered better.'
**Symptom:** Stats Widget showing random warning icons (⚠) instead of tracker values + frequent 'CDP websocket disconnected' / 'Timed out loading' scrape failures across all 4 trackers (Claude session, Claude weekly, ChatGPT session, ChatGPT codex). Pre-v0.21.14 log was a continuous storm of disconnects.
**Root cause:** Parallel scrapes against the same Chromium browser profile shared a single CDP websocket. When two trackers' scrapes fired within ~1s of each other (which BackgroundScheduler did every cycle), the first to finish would call Page.close, which dropped the shared websocket — and the second scrape's selector-poll loop then hit 'The CDP websocket disconnected' for ~30s of retries before timing out. Surfaces to the user as warning icon + stale data.
**Fix:** v0.21.14: introduced 15s per-profile scrape-start stagger via new lastScrapeStartedAt watermark in ChromeBrowserProfile + reserveScrapeStart() called from ChromeCDPScraper.scrape() BEFORE any DispatchQueue.main.async. Watermark stores PROJECTED start time inside queue.sync so 4 simultaneous reserves stagger to 0s/15s/30s/45s instead of all racing. Also v0.21.12: pin in-flight scrape tabs against orphan sweep so a sweep can't close a tab a sibling scrape is using.
**Commit:** fbd1fe1
**Guard:** Activity-log gate: zero 'CDP websocket disconnected' lines over 10 consecutive scrape cycles post-install. The [scheduler] staggering scrape log line ALSO fires whenever stagger applies, so it can be greped for to confirm the watermark code is actually executing.
---

