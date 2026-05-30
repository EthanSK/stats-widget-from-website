#!/usr/bin/env bash
# auto-repair-tracker.sh — failure-hook script (v0.18.0+)
#
# Invoked by the stats-widget app's hook system whenever a tracker's
# scheduled scrape fails. Spawns a Claude Code agent in its own Terminal
# window pointed at the failing tracker and asks the agent to re-identify
# the broken element via the embedded MCP server.
#
# Required env vars (injected by HookExecutor.makeEnvironment):
#   TRACKER_ID, TRACKER_NAME, TRACKER_URL, TRACKER_SELECTOR
#   ERROR_KIND, ERROR_MESSAGE
#   CONSECUTIVE_FAILURE_COUNT
#   APP_GROUP_IDENTIFIER, MCP_SOCKET_PATH
#
# Failure mode: if Terminal.app isn't installed or AppleScript is denied
# by TCC, the script logs to /tmp/macos-widgets-stats-auto-repair.log
# and exits non-zero — HookExecutor records the failure in lastRun.detail
# so the user can see it in the Hooks panel.
#
# The agent is expected to (a) call repair_tracker / update_tracker on
# the embedded MCP server to fix the selector, then (b) send a macOS
# notification with the literal title "element reidentified by agent" so
# the user sees the action even if they weren't watching the Terminal
# window. See AUTO_REPAIR_PROMPT below for the exact instruction.

set -euo pipefail

LOG_FILE="/tmp/macos-widgets-stats-auto-repair.log"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" >>"$LOG_FILE"
}

log "auto-repair-tracker.sh fired for tracker ${TRACKER_NAME:-?} (${TRACKER_ID:-?})"
log "  url=${TRACKER_URL:-?} selector=${TRACKER_SELECTOR:-?} error=${ERROR_MESSAGE:-?}"
log "  consecutiveFailureCount=${CONSECUTIVE_FAILURE_COUNT:-?}"

# v0.21.29 defensive gate (Ethan voice 4020): the primary gate lives in
# BackgroundScheduler.fireScrapeLifecycleHooks() which now suppresses
# .onFailure hooks until consecutiveFailureCount >= 3. This script
# duplicates the check because (a) trackers.json might carry a user-
# authored failure hook that invokes the auto-repair script directly,
# bypassing the Swift-side gate, and (b) belt-and-braces is cheap.
#
# If CONSECUTIVE_FAILURE_COUNT is unset (older host app that doesn't
# inject the env var yet), assume 3 so we DON'T silently suppress on
# upgrade paths.
FAILURE_COUNT="${CONSECUTIVE_FAILURE_COUNT:-3}"
if ! [[ "$FAILURE_COUNT" =~ ^[0-9]+$ ]]; then
    log "  WARN: CONSECUTIVE_FAILURE_COUNT=\"$FAILURE_COUNT\" not numeric; treating as 3 to avoid suppressing."
    FAILURE_COUNT=3
fi
if (( FAILURE_COUNT < 3 )); then
    log "  suppressing auto-repair (consecutiveFailureCount=$FAILURE_COUNT < 3, voice 4020)"
    exit 0
fi

# v0.21.73 defensive kind gate (Ethan voice 4417): the auto-repair agent
# RE-IDENTIFIES the scraped element. That only makes sense when the
# element genuinely couldn't be found — NOT when the page was lagging,
# mid-Cloudflare-challenge, blank/not-loaded, behind a login wall, or
# timed out. The primary gate lives in
# BackgroundScheduler.fireScrapeLifecycleHooks(), which strips the
# built-in auto-repair hook unless the failure classifies as a genuine
# selectorNotFound. This script duplicates the check defensively because
# (a) a user-authored hook could invoke this script directly, bypassing
# the Swift gate, and (b) belt-and-braces is cheap.
#
# We classify off ERROR_MESSAGE using the SAME fingerprints as
# TrackerFailureKind.classify(errorMessage:) in TrackerResult.swift.
# Anything that smells like a challenge / login / timeout is treated as a
# transient/non-selector failure → suppress. Only a real "selector did
# not match" / "selector is invalid" / "selected element has no…" string
# is eligible to re-identify. If ERROR_MESSAGE is empty (older host that
# doesn't inject it), we proceed (fail-open) so we don't silently break
# repair on upgrade paths — the Swift-side gate is the real default.
ERR_LOWER="$(printf '%s' "${ERROR_MESSAGE:-}" | tr '[:upper:]' '[:lower:]')"
if [[ -n "$ERR_LOWER" ]]; then
    # Transient / non-selector kinds that must NOT trigger re-identify.
    if [[ "$ERR_LOWER" == *"cloudflare"* \
        || "$ERR_LOWER" == *"verification"* \
        || "$ERR_LOWER" == *"just a moment"* \
        || "$ERR_LOWER" == *"turnstile"* \
        || "$ERR_LOWER" == *"__cf_chl"* \
        || "$ERR_LOWER" == *"login"* \
        || "$ERR_LOWER" == *"sign in"* \
        || "$ERR_LOWER" == *"password"* \
        || "$ERR_LOWER" == *"timed out"* \
        || "$ERR_LOWER" == *"timeout"* ]]; then
        log "  suppressing auto-repair (failure kind is transient/non-selector, voice 4417): ${ERROR_MESSAGE:-?}"
        exit 0
    fi
    # Genuine selectorNotFound fingerprints — proceed only if one matches.
    if ! [[ "$ERR_LOWER" == *"selector did not match"* \
        || "$ERR_LOWER" == *"selector is invalid"* \
        || "$ERR_LOWER" == *"selected element has no"* ]]; then
        log "  suppressing auto-repair (failure not a genuine selectorNotFound, voice 4417): ${ERROR_MESSAGE:-?}"
        exit 0
    fi
fi

# Locate Claude Code on PATH or in well-known install spots. We don't
# hard-fail when it's missing; the agent might be installed in a
# location the user wants us to discover.
#
# IMPORTANT — launchd PATH context (Ethan voice 4025, 2026-05-24):
# The hook is invoked from HookExecutor which inherits the stats-widget
# host app's PATH, which inherits launchd's minimal /usr/bin:/bin:/usr/sbin:/sbin.
# This is why `command -v claude` returned empty on Ethan's machine even
# though `which claude` works in his interactive shell — the alias lives
# in .zshrc, the symlink at ~/.local/bin/claude isn't on launchd's PATH.
#
# The modern Anthropic Claude Code installer (`curl ... | bash`) installs
# the binary at `~/.local/share/claude/versions/<ver>` and symlinks
# `~/.local/bin/claude` → that. The legacy `~/.claude/local/bin/claude`
# path was renamed years ago — most users no longer have it.
#
# Candidates ordered most-likely-first for the 2026 install layout. We
# also peek into `~/.vscode/extensions/anthropic.claude-code-*` because
# the VSCode extension bundles its own claude binary that some users
# have but no shell symlink to.
CLAUDE_BIN=""
for candidate in \
    "$(command -v claude 2>/dev/null || true)" \
    "$HOME/.local/bin/claude" \
    "$HOME/.local/share/claude/bin/claude" \
    "$HOME/.claude/local/bin/claude" \
    "/opt/homebrew/bin/claude" \
    "/usr/local/bin/claude"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        CLAUDE_BIN="$candidate"
        break
    fi
done

# Fallback: scan ~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude
# for a bundled binary. Use globbing rather than hardcoding version
# numbers so a future VSCode extension update doesn't strand us.
if [[ -z "$CLAUDE_BIN" ]]; then
    for vscode_claude in "$HOME"/.vscode/extensions/anthropic.claude-code-*-darwin-*/resources/native-binary/claude; do
        if [[ -x "$vscode_claude" ]]; then
            CLAUDE_BIN="$vscode_claude"
            break
        fi
    done
fi

# Log every candidate we checked so future "Claude CLI not installed"
# notifications are debuggable from /tmp/macos-widgets-stats-auto-repair.log
# alone (voice 4015 forensic requirement — every error notification
# must have enough log context to reconstruct the cause without asking
# the user for a screenshot).
# Capture command-v result to a variable first because bash's `${var:-default}`
# parameter expansion only takes variable names, not direct command substitution.
PATH_CLAUDE="$(command -v claude 2>/dev/null || true)"
log "  claude-binary lookup result:"
log "    command -v claude          → ${PATH_CLAUDE:-not-on-PATH}"
log "    ~/.local/bin/claude        → $([[ -x "$HOME/.local/bin/claude" ]] && echo present || echo missing)"
log "    ~/.claude/local/bin/claude → $([[ -x "$HOME/.claude/local/bin/claude" ]] && echo present || echo missing)"
log "    /opt/homebrew/bin/claude   → $([[ -x "/opt/homebrew/bin/claude" ]] && echo present || echo missing)"
log "    /usr/local/bin/claude      → $([[ -x "/usr/local/bin/claude" ]] && echo present || echo missing)"
log "  resolved CLAUDE_BIN: ${CLAUDE_BIN:-EMPTY (no claude binary found)}"

if [[ -z "$CLAUDE_BIN" ]]; then
    log "WARN: claude binary not found on PATH or in standard locations."
    log "      Falling back to a notification telling the user to repair manually."
    osascript <<EOF >/dev/null 2>&1 || true
display notification "Could not auto-repair: \`claude\` CLI not installed." with title "${TRACKER_NAME:-Tracker} scrape failed" sound name "Funk"
EOF
    exit 2
fi

log "  using claude binary: $CLAUDE_BIN"

# Build the agent prompt. Keep it short, action-oriented, and let the
# agent decide which MCP tools to use. We intentionally do NOT pre-spec
# selector ideas — the agent should inspect the live DOM.
read -r -d '' AUTO_REPAIR_PROMPT <<PROMPT || true
You are repairing a broken tracker in the stats-widget app.

Tracker context:
- Name: ${TRACKER_NAME}
- ID: ${TRACKER_ID}
- URL: ${TRACKER_URL}
- Current (failing) selector: ${TRACKER_SELECTOR}
- Error: ${ERROR_MESSAGE:-unknown}
- Consecutive failure count: ${CONSECUTIVE_FAILURE_COUNT:-?}

Goal: re-identify the correct element on the page and patch the tracker.

Steps:
1. Use the stats-widget MCP server (mcp__stats-widget__* tools) to read the tracker. The socket lives at ${MCP_SOCKET_PATH}. If that MCP isn't connected, also try Chrome DevTools MCP or any HTML-fetching tool to inspect ${TRACKER_URL}.
2. Determine why the existing selector failed. Common causes: the page renamed a class, an A/B test moved the value into a new container, the user signed out and the page now renders a login screen instead of the metric.
3. Pick a new CSS selector that targets the same metric. Prefer stable structural selectors over auto-generated class names.
4. Call mcp__stats-widget__update_tracker (or repair_tracker) with the tracker id ${TRACKER_ID} and the new selector. Verify by calling trigger_scrape and confirming the returned status is 'ok'.
5. After confirming the fix, send a macOS notification with the EXACT title and body below so the user knows the repair landed:
   osascript -e 'display notification "element reidentified by agent" with title "${TRACKER_NAME}" sound name "Glass"'

If you genuinely cannot determine the right selector (page requires interactive sign-in, the metric was removed entirely, etc.), send a different notification explaining what blocked you, and DO NOT change the selector to a wrong one.
PROMPT

# Stage the prompt to a temp file because it's too big to embed inline
# in the AppleScript do-script call.
PROMPT_FILE="$(mktemp -t stats-widget-auto-repair-prompt.XXXXXX)"
printf '%s' "$AUTO_REPAIR_PROMPT" >"$PROMPT_FILE"
log "  prompt staged at $PROMPT_FILE ($(wc -c <"$PROMPT_FILE") bytes)"

# Build the command that the new Terminal window will run. We change
# directory to the user's home so claude finds its global settings
# (~/.claude/...) before consuming the prompt. The prompt is piped
# through cat so AppleScript escaping stays minimal.
TERMINAL_CMD="cd \"$HOME\" && cat \"$PROMPT_FILE\" | \"$CLAUDE_BIN\" 2>&1; echo; echo '[auto-repair finished — Terminal will stay open so you can review the agent output. Close manually when done.]'; exec bash"

log "  launching Terminal.app with auto-repair agent…"

# Trying Terminal.app first. If the user prefers iTerm or another
# emulator they can swap out the script after first launch (it's
# installed to Application Support and is editable).
osascript \
    -e 'on run argv' \
    -e 'tell application "Terminal"' \
    -e 'activate' \
    -e 'do script (item 1 of argv)' \
    -e 'end tell' \
    -e 'end run' \
    "$TERMINAL_CMD" >>"$LOG_FILE" 2>&1

log "  Terminal launched. Auto-repair script returning."
exit 0
