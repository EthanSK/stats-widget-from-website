#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build.sh — single-machine canonical build pipeline.
#
# What this script does, in order:
#   1. Runs `xcodegen` to regenerate the Xcode project from project.yml.
#   2. Builds the `MacosWidgetsStatsFromWebsite` GUI scheme (Debug config) into
#      a stable derived-data path. The GUI scheme also embeds the widget
#      extension + bundled Chromium via its post-build script. The resulting
#      .app is the canonical end-user artifact.
#   3. Builds the `MacosWidgetsStatsFromWebsiteCLI` scheme (Release config)
#      into its own derived-data path. The CLI is a Mach-O tool whose
#      `--mcp-stdio` entrypoint hosts the MCP server when launched as a
#      subprocess by an external agent (Claude Code, OpenClaw, etc.). The CLI
#      lives at `Contents/MacOS/macos-widgets-stats-from-website` inside the
#      .app bundle alongside the GUI binary so the same bundle is the unit of
#      install for both surfaces.
#   4. Copies the CLI binary into `Contents/MacOS/` of the GUI .app bundle and
#      re-signs both the CLI and the parent .app with entitlements consistent
#      with the current build mode (Debug vs. DEV_RESIGN vs. profile-backed).
#   5. Smoke-tests the embedded CLI by sending it an MCP `initialize` request
#      over stdio and confirming a clean response + exit. Failure aborts the
#      build so a broken-CLI bundle never lands in /Applications by accident.
#   6. If `--install` is passed, ditto's the assembled .app into /Applications
#      after terminating any prior copy. Default behaviour is NOT to install —
#      explicit opt-in only.
#
# Environment + flag reference:
#   - DEV_RESIGN=1 or --dev-resign
#       Enables the chronod-resign workaround for the widget extension AND
#       switches the CLI to a stripped entitlements file
#       (MacosWidgetsStatsFromWebsiteCLI.dev.entitlements). The dev file
#       removes `com.apple.security.application-groups` and
#       `keychain-access-groups`, which are profile-gated and would otherwise
#       trigger taskgated SIGKILL ("Invalid Signature") when the CLI is
#       signed with a bare Apple Development cert without an embedded
#       provisioning profile. Use this on personal/dev machines.
#   - ALLOW_PROVISIONING_UPDATES=1
#       Passes `-allowProvisioningUpdates` to xcodebuild so Xcode can fix up
#       signing settings on first run.
#   - DERIVED_DATA_PATH=<path>
#       Override the default `build/manual-test-derived` location. Useful for
#       parallel builds.
#   - --install
#       Ditto the assembled .app to `/Applications` after the build + smoke
#       test pass. Does NOT trigger by default — Mini-CC and CI both want the
#       install separated from the pipeline step.
#
# CI / Release builds DO NOT use this script. The GitHub Actions workflow
# (`.github/workflows/release.yml`) invokes `xcodebuild archive` directly with
# the real Developer ID cert and embedded provisioning profile, so the
# DEV_RESIGN path never executes there.
# ---------------------------------------------------------------------------

# Use a stable derived-data path so the post-build verify/sign step can
# locate the .app reliably and so the running binary path stays consistent
# across rebuilds (also helps TCC keep its grants attached to one path).
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/manual-test-derived}"

# Parse DEV_RESIGN early — it changes which post-build verifications apply.
# DEV_RESIGN=1 (or --dev-resign) opts into the chronod-resign workaround
# documented further down. In that mode the appex's embedded provisioning
# profile is intentionally removed, so the strict
# `require_profile_app_group_entitlement` checks are skipped (they would
# fail by design after the workaround).
DEV_RESIGN_FLAG=0
if [[ "${DEV_RESIGN:-0}" == "1" ]]; then
  DEV_RESIGN_FLAG=1
fi
INSTALL_FLAG=0
for arg in "$@"; do
  case "$arg" in
    --dev-resign)
      DEV_RESIGN_FLAG=1
      ;;
    --install)
      INSTALL_FLAG=1
      ;;
  esac
done

echo "=== STEP 1: xcodegen ==="
xcodegen

XCODEBUILD_SIGNING_FLAGS=()
if [[ "${ALLOW_PROVISIONING_UPDATES:-}" == "1" ]]; then
  XCODEBUILD_SIGNING_FLAGS+=("-allowProvisioningUpdates")
fi

echo "=== STEP 2: build GUI scheme (MacosWidgetsStatsFromWebsite, Debug) ==="
# Build Debug with the project's normal automatic signing. This uses
# Ethan's developer cert and produces a signed binary with the
# Debug.entitlements file (app-sandbox=false) embedded — which is what
# stops the macOS Sonoma+ "would like to access data from other apps"
# TCC re-prompt from firing on every rebuild.
#
# Do NOT pass CODE_SIGNING_ALLOWED=NO here. Without signing, the
# entitlements are never embedded, and TCC re-prompts every launch.
xcodebuild \
  -project MacosWidgetsStatsFromWebsite.xcodeproj \
  -scheme MacosWidgetsStatsFromWebsite \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ${XCODEBUILD_SIGNING_FLAGS[@]+"${XCODEBUILD_SIGNING_FLAGS[@]}"} \
  ENABLE_DEBUG_DYLIB=NO \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/MacosWidgetsStatsFromWebsite.app"
DEBUG_ENTITLEMENTS="MacosWidgetsStatsFromWebsite/Apps/MainApp/MacosWidgetsStatsFromWebsite.Debug.entitlements"
APP_GROUP_ID="T34G959ZG8.group.com.ethansk.macos-widgets-stats-from-website"

if [[ ! -d "$APP_PATH" ]]; then
  echo "build.sh: ERROR — expected .app bundle not found at $APP_PATH" >&2
  exit 1
fi

# Verify the build embedded the Debug entitlements (sandbox=false).
# If it didn't (e.g. a previous unsigned build is still cached, or the
# build was run with CODE_SIGNING_ALLOWED=NO outside of this script),
# fall back to ad-hoc signing with the Debug.entitlements file so the
# binary still gets a stable per-machine identity AND the sandbox-off
# entitlement, which is what TCC keys its grant to.
ENTITLEMENTS_OUT=$(codesign -d --entitlements - "$APP_PATH" 2>&1 || true)
if ! grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS_OUT"; then
  echo "build.sh: entitlements missing after xcodebuild — falling back to ad-hoc sign"
  codesign \
    --force \
    --sign - \
    --entitlements "$DEBUG_ENTITLEMENTS" \
    "$APP_PATH"
  ENTITLEMENTS_OUT=$(codesign -d --entitlements - "$APP_PATH" 2>&1 || true)
fi

# Hard gate: refuse to leave a build artifact without the sandbox=false
# entitlement embedded — without it, TCC will re-prompt on the next launch
# and the c00f30e fix is silently inert.
if ! grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS_OUT"; then
  echo "build.sh: ERROR — app-sandbox entitlement still not embedded after sign" >&2
  echo "$ENTITLEMENTS_OUT" >&2
  exit 1
fi
echo "build.sh: entitlements verified (com.apple.security.app-sandbox embedded)"

WIDGET_PATH="$APP_PATH/Contents/PlugIns/MacosWidgetsStatsFromWebsiteWidget.appex"

require_signed_app_group_entitlement() {
  local bundle_path="$1"
  local label="$2"

  local entitlements_out
  entitlements_out=$(codesign -d --entitlements :- "$bundle_path" 2>/dev/null || true)
  if ! grep -q "<string>${APP_GROUP_ID}</string>" <<<"$entitlements_out"; then
    echo "build.sh: ERROR — $label signature is missing App Group $APP_GROUP_ID" >&2
    echo "$entitlements_out" >&2
    exit 1
  fi
}

require_profile_app_group_entitlement() {
  local bundle_path="$1"
  local label="$2"
  local profile_path="$bundle_path/Contents/embedded.provisionprofile"

  if [[ ! -f "$profile_path" ]]; then
    echo "build.sh: ERROR — $label has no embedded provisioning profile; cannot validate App Group $APP_GROUP_ID" >&2
    exit 1
  fi

  local profile_entitlements
  profile_entitlements=$(security cms -D -i "$profile_path" 2>/dev/null | plutil -extract Entitlements xml1 -o - - 2>/dev/null || true)
  if ! grep -q "<string>${APP_GROUP_ID}</string>" <<<"$profile_entitlements"; then
    echo "build.sh: ERROR — $label provisioning profile is missing App Group $APP_GROUP_ID" >&2
    echo "build.sh: refresh signing after enabling the canonical App Group for the app + widget targets; do not switch to a team-prefixed group." >&2
    echo "$profile_entitlements" >&2
    exit 1
  fi
}

if [[ ! -d "$WIDGET_PATH" ]]; then
  echo "build.sh: ERROR — expected widget extension not found at $WIDGET_PATH" >&2
  exit 1
fi

if [[ "$DEV_RESIGN_FLAG" == "1" ]]; then
  echo "build.sh: DEV_RESIGN=1 — skipping strict App Group signature/profile checks (dev-resign workaround applied below)"
else
  require_signed_app_group_entitlement "$APP_PATH" "app"
  require_signed_app_group_entitlement "$WIDGET_PATH" "widget extension"
  require_profile_app_group_entitlement "$APP_PATH" "app"
  require_profile_app_group_entitlement "$WIDGET_PATH" "widget extension"
  echo "build.sh: App Group entitlements verified in signatures and provisioning profiles ($APP_GROUP_ID)"
fi

# Defensively reset any stale TCC SystemPolicyAppData grant for this bundle.
# Debug builds use unsandboxed entitlements so this prompt should never fire,
# but if a previous (sandboxed) Debug build left an auth_value=5 row in TCC.db,
# resetting it ensures the next launch starts clean.
# Failure here is non-fatal — the bundle just may not have a row yet.
tccutil reset SystemPolicyAppData com.ethansk.macos-widgets-stats-from-website >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Post-build chronod-resign workaround (DEV ONLY)
# ---------------------------------------------------------------------------
# WHY:
# On macOS, Apple-Development-signed widget extensions are gated by chronod's
# "restricted-or-unknown extension" policy. With the appex left in its default
# Apple Development signed + embedded provisioning profile state, chronod
# refuses to register it and logs:
#   chronod ... Ignoring restricted or unknown extension <bundle-id>
# The user-visible symptom is an empty "Edit Widget" configuration dropdown:
# the widget never appears in the picker, so app-intent-driven choice
# selection cannot be tested locally.
#
# The workaround is to:
#   1. Remove the appex's embedded.provisionprofile (chronod treats provisioned
#      Apple Dev appexes as restricted on personal/dev machines).
#   2. Re-sign the appex with the SAME Apple Development cert as the parent
#      app, preserving its .xcent entitlements. Earlier revisions adhoc-signed
#      the appex here, but that left it with no TeamIdentifier — at runtime
#      taskgated rejects the bundle with "Invalid Signature" SIGKILL because
#      the parent's TeamIdentifier (T34...) doesn't match the appex's empty
#      one (codesign --verify passes statically; the check is dynamic). Same
#      cert on parent + appex keeps the TeamIdentifier consistent across the
#      bundle and still satisfies chronod once the embedded profile is gone.
#   3. Re-sign the parent .app with the Apple Development cert (NOT adhoc —
#      adhoc-signing the parent triggers launchd POSIX 163 because the
#      Debug.entitlements file references a team-prefixed
#      `application-identifier`, which adhoc signatures cannot satisfy).
#
# This step is GATED behind DEV_RESIGN=1 (or --dev-resign flag) so production
# / CI builds — which use a real provisioning profile and a Developer ID cert —
# don't get clobbered. The default behaviour of `scripts/build.sh` is unchanged.
#
# Failure modes are non-fatal: if any sub-step errors, we print a warning and
# continue so the build still produces a usable artefact (just one chronod
# might not register). DEV_RESIGN_FLAG is parsed at the top of the script.
# ---------------------------------------------------------------------------
# APP_DEV_AUTHORITY is reused below by the CLI assembly step (STEP 4) to keep
# the CLI's signing identity consistent with the parent .app. Captured here
# so a single security/codesign probe covers both code paths.
APP_DEV_AUTHORITY=""

if [[ "$DEV_RESIGN_FLAG" == "1" ]]; then
  echo "=== STEP 3a: DEV_RESIGN chronod workaround on widget extension ==="
  echo "build.sh: DEV_RESIGN=1 — applying chronod-resign workaround on $WIDGET_PATH"

  # Locate the .xcent entitlements file emitted by xcodebuild for the appex.
  # Path is stable across Xcode versions: Build/Intermediates.noindex/<proj>.build/<config>/<target>.build/<bundle>.xcent
  # Note: this whole block runs with pipefail disabled so partial-pipe
  # successes (e.g. `find ... | head -n1` truncating its stdin) don't tank
  # the script — pipefail is restored at the end of the dev-resign block.
  set +o pipefail
  WIDGET_XCENT=$(find "$DERIVED_DATA_PATH/Build/Intermediates.noindex" \
    -path "*/MacosWidgetsStatsFromWebsiteWidget.build/*.xcent" \
    -type f 2>/dev/null | head -n1)

  # Locate the parent app's .xcent file too. Re-signing the parent with the
  # source $DEBUG_ENTITLEMENTS file leaves application-identifier missing and
  # keychain-access-groups holding the literal $(AppIdentifierPrefix)
  # placeholder — launchd then refuses spawn with POSIX 163. Xcode's emitted
  # .app.xcent has the team-prefixed values resolved, which launchd accepts.
  APP_XCENT=$(find "$DERIVED_DATA_PATH/Build/Intermediates.noindex" \
    -path "*/MacosWidgetsStatsFromWebsite.build/*.xcent" \
    -name "*.app.xcent" \
    -type f 2>/dev/null | head -n1)

  # Detect the Apple Development cert currently signing the parent .app so we
  # can re-sign with the same identity after touching the appex. Falls back to
  # any "Apple Development" identity in the keychain if the running build
  # didn't leave a parseable Authority line (shouldn't happen, but defensive).
  APP_DEV_AUTHORITY=$(codesign -d -vvv "$APP_PATH" 2>&1 \
    | awk -F'=' '/^Authority=Apple Development:/ {print $2}' \
    | head -n1)
  if [[ -z "$APP_DEV_AUTHORITY" ]]; then
    APP_DEV_AUTHORITY=$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Apple Development:/ {print $2}' \
      | head -n1)
  fi

  if [[ -z "$WIDGET_XCENT" ]]; then
    echo "build.sh: WARN — could not locate widget .xcent under $DERIVED_DATA_PATH/Build/Intermediates.noindex; skipping dev-resign" >&2
  elif [[ -z "$APP_XCENT" ]]; then
    echo "build.sh: WARN — could not locate parent app .xcent under $DERIVED_DATA_PATH/Build/Intermediates.noindex; skipping dev-resign" >&2
  elif [[ -z "$APP_DEV_AUTHORITY" ]]; then
    echo "build.sh: WARN — could not detect an 'Apple Development' signing identity; skipping dev-resign" >&2
  else
    echo "build.sh: dev-resign — widget xcent: $WIDGET_XCENT"
    echo "build.sh: dev-resign — parent xcent: $APP_XCENT"
    echo "build.sh: dev-resign — parent app authority: $APP_DEV_AUTHORITY"

    WIDGET_PROFILE="$WIDGET_PATH/Contents/embedded.provisionprofile"
    if [[ -f "$WIDGET_PROFILE" ]]; then
      echo "build.sh: dev-resign — removing $WIDGET_PROFILE"
      rm -f "$WIDGET_PROFILE" || \
        echo "build.sh: WARN — failed to remove embedded.provisionprofile (continuing)" >&2
    else
      echo "build.sh: dev-resign — no embedded.provisionprofile present on appex (already cleared)"
    fi

    echo "build.sh: dev-resign — re-signing appex with $APP_DEV_AUTHORITY (preserves TeamIdentifier match with parent)"
    if ! codesign --force --sign "$APP_DEV_AUTHORITY" --entitlements "$WIDGET_XCENT" "$WIDGET_PATH"; then
      echo "build.sh: WARN — appex re-sign with Apple Development cert failed (continuing)" >&2
    fi

    echo "build.sh: dev-resign — re-signing parent app with $APP_DEV_AUTHORITY (using resolved .app.xcent so application-identifier survives)"
    if ! codesign --force --sign "$APP_DEV_AUTHORITY" --entitlements "$APP_XCENT" "$APP_PATH"; then
      echo "build.sh: WARN — re-sign of parent app failed (continuing)" >&2
    fi

    echo "build.sh: dev-resign — done; chronod should now register the widget extension"
  fi

  set -o pipefail
fi

# ---------------------------------------------------------------------------
# STEP 3: build the CLI scheme (MacosWidgetsStatsFromWebsiteCLI, Release).
# ---------------------------------------------------------------------------
# The CLI scheme produces a standalone Mach-O tool whose `--mcp-stdio`
# entrypoint hosts the MCP server when an external agent (Claude Code,
# OpenClaw) launches it as a stdio subprocess. We build Release so the binary
# is optimized and Sparkle / external invocations get the same artefact as CI.
# Build into a SEPARATE derived-data path so the CLI build doesn't clobber the
# GUI build's intermediates.
echo "=== STEP 3: build CLI scheme (MacosWidgetsStatsFromWebsiteCLI, Release) ==="
CLI_DERIVED_DATA_PATH="${DERIVED_DATA_PATH%-derived}-cli-derived"
# Fallback for unusual DERIVED_DATA_PATH values that don't end in `-derived`.
if [[ "$CLI_DERIVED_DATA_PATH" == "$DERIVED_DATA_PATH" ]]; then
  CLI_DERIVED_DATA_PATH="${DERIVED_DATA_PATH}-cli"
fi

xcodebuild \
  -project MacosWidgetsStatsFromWebsite.xcodeproj \
  -scheme MacosWidgetsStatsFromWebsiteCLI \
  -configuration Release \
  -derivedDataPath "$CLI_DERIVED_DATA_PATH" \
  ${XCODEBUILD_SIGNING_FLAGS[@]+"${XCODEBUILD_SIGNING_FLAGS[@]}"} \
  build

CLI_BIN_SRC="$CLI_DERIVED_DATA_PATH/Build/Products/Release/macos-widgets-stats-from-website"
if [[ ! -x "$CLI_BIN_SRC" ]]; then
  echo "build.sh: ERROR — expected CLI binary not found at $CLI_BIN_SRC" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# STEP 4: copy the CLI binary into the GUI bundle + sign with the right
# entitlements, then re-seal the parent .app.
#
# The CLI lives at Contents/MacOS/macos-widgets-stats-from-website inside the
# GUI .app bundle (alongside the main GUI executable). MCP configs reference
# this path directly, e.g.:
#   /Applications/MacosWidgetsStatsFromWebsite.app/Contents/MacOS/macos-widgets-stats-from-website --mcp-stdio
# ---------------------------------------------------------------------------
echo "=== STEP 4: embed CLI binary in GUI bundle + sign ==="
CLI_BIN_DEST="$APP_PATH/Contents/MacOS/macos-widgets-stats-from-website"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$CLI_BIN_SRC" "$CLI_BIN_DEST"

# Pick the entitlements file used to sign the embedded CLI. In DEV_RESIGN
# mode the dev file strips the profile-gated entitlements that would
# otherwise SIGKILL the CLI on launch. In normal mode (CI / profile-backed
# Release builds) the canonical entitlements file is correct because the
# embedded provisioning profile satisfies the App Group + keychain
# entitlements.
CLI_ENTITLEMENTS_PROD="MacosWidgetsStatsFromWebsite/Apps/CLI/MacosWidgetsStatsFromWebsiteCLI.entitlements"
CLI_ENTITLEMENTS_DEV="MacosWidgetsStatsFromWebsite/Apps/CLI/MacosWidgetsStatsFromWebsiteCLI.dev.entitlements"
if [[ "$DEV_RESIGN_FLAG" == "1" ]]; then
  CLI_ENTITLEMENTS_FOR_SIGN="$CLI_ENTITLEMENTS_DEV"
  echo "build.sh: CLI signing — DEV_RESIGN=1, using stripped entitlements: $CLI_ENTITLEMENTS_FOR_SIGN"
else
  CLI_ENTITLEMENTS_FOR_SIGN="$CLI_ENTITLEMENTS_PROD"
  echo "build.sh: CLI signing — using canonical entitlements: $CLI_ENTITLEMENTS_FOR_SIGN"
fi

if [[ ! -f "$CLI_ENTITLEMENTS_FOR_SIGN" ]]; then
  echo "build.sh: ERROR — CLI entitlements file missing: $CLI_ENTITLEMENTS_FOR_SIGN" >&2
  exit 1
fi

# Pick the signing identity for the CLI: prefer the same Apple Development
# authority used by the parent app (so TeamIdentifier matches across the
# bundle). Fall back to ad-hoc only if no developer identity is in the
# keychain — that's the case in CI before the cert is imported, but the
# release.yml workflow doesn't call this script so it should be a no-op.
if [[ -z "$APP_DEV_AUTHORITY" ]]; then
  APP_DEV_AUTHORITY=$(codesign -d -vvv "$APP_PATH" 2>&1 \
    | awk -F'=' '/^Authority=Apple Development:/ {print $2}' \
    | head -n1) || true
  if [[ -z "$APP_DEV_AUTHORITY" ]]; then
    APP_DEV_AUTHORITY=$(codesign -d -vvv "$APP_PATH" 2>&1 \
      | awk -F'=' '/^Authority=Developer ID Application:/ {print $2}' \
      | head -n1) || true
  fi
fi

if [[ -n "$APP_DEV_AUTHORITY" ]]; then
  CLI_SIGN_IDENTITY="$APP_DEV_AUTHORITY"
  echo "build.sh: CLI signing — identity: $CLI_SIGN_IDENTITY (matching parent app)"
else
  CLI_SIGN_IDENTITY="-"
  echo "build.sh: CLI signing — no developer identity detected; falling back to ad-hoc"
fi

codesign --force \
  --options runtime \
  --sign "$CLI_SIGN_IDENTITY" \
  --entitlements "$CLI_ENTITLEMENTS_FOR_SIGN" \
  "$CLI_BIN_DEST"

codesign -v "$CLI_BIN_DEST" >/dev/null 2>&1 \
  || { echo "build.sh: ERROR — embedded CLI signature failed verification at $CLI_BIN_DEST" >&2; exit 1; }
echo "build.sh: embedded CLI signed + verified: $CLI_BIN_DEST"

# Re-seal the parent .app so the new file in Contents/MacOS doesn't break
# the parent's CodeResources hash. We reuse the same xcent / entitlements
# file that the GUI build originally used so we don't drift signing
# semantics here — only the file list inside CodeResources needs to be
# refreshed.
if [[ "$DEV_RESIGN_FLAG" == "1" ]]; then
  # In DEV_RESIGN mode we already re-signed the parent above with the
  # resolved .app.xcent. Use the same xcent again so application-identifier
  # / keychain-access-groups stay resolved (literal strings, not
  # $(AppIdentifierPrefix) placeholders).
  PARENT_RESIGN_ENTITLEMENTS=""
  if [[ -n "${APP_XCENT:-}" && -f "$APP_XCENT" ]]; then
    PARENT_RESIGN_ENTITLEMENTS="$APP_XCENT"
  fi
else
  PARENT_RESIGN_ENTITLEMENTS="$DEBUG_ENTITLEMENTS"
fi

if [[ -n "$PARENT_RESIGN_ENTITLEMENTS" ]]; then
  echo "build.sh: re-sealing parent .app with entitlements: $PARENT_RESIGN_ENTITLEMENTS"
  codesign --force \
    --options runtime \
    --sign "$CLI_SIGN_IDENTITY" \
    --entitlements "$PARENT_RESIGN_ENTITLEMENTS" \
    "$APP_PATH"
else
  echo "build.sh: re-sealing parent .app (no entitlements override — preserving original)"
  codesign --force \
    --options runtime \
    --sign "$CLI_SIGN_IDENTITY" \
    "$APP_PATH"
fi

codesign -v "$APP_PATH" >/dev/null 2>&1 \
  || { echo "build.sh: ERROR — parent .app signature failed verification after CLI embed" >&2; exit 1; }
echo "build.sh: parent .app re-sealed + verified: $APP_PATH"

# ---------------------------------------------------------------------------
# STEP 5: smoke-test the embedded CLI via --mcp-stdio.
#
# We send a single MCP `initialize` JSON-RPC request framed with
# `Content-Length:` and read the response back. If the CLI returns a valid
# response and exits cleanly, the bundle is good to ship. If it SIGKILLs or
# emits garbage, the build fails so a broken bundle never reaches
# /Applications.
# ---------------------------------------------------------------------------
echo "=== STEP 5: smoke-test embedded CLI ==="
SMOKE_TMP="$(mktemp -d -t macos-widgets-stats-cli-smoke.XXXXXX)"
trap 'rm -rf "$SMOKE_TMP"' EXIT
SMOKE_OUT="$SMOKE_TMP/smoke.out"
SMOKE_ERR="$SMOKE_TMP/smoke.err"

# Build the JSON-RPC initialize request. MCP framing = Content-Length + CRLF.
SMOKE_REQ_JSON='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"build.sh","version":"0.0.1"}}}'
SMOKE_REQ_LEN=${#SMOKE_REQ_JSON}

# Send the initialize request, wait up to 8s for a response, then close stdin.
# The CLI's runStdioServer() should write a response and stay running for
# more requests; we kill it after we get the response.
{
  printf 'Content-Length: %d\r\n\r\n%s' "$SMOKE_REQ_LEN" "$SMOKE_REQ_JSON"
  sleep 8
} | "$CLI_BIN_DEST" --mcp-stdio >"$SMOKE_OUT" 2>"$SMOKE_ERR" &
SMOKE_PID=$!

# Wait briefly for the response, then terminate the CLI cleanly.
sleep 4
kill -TERM "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null || true

if ! grep -q '"jsonrpc"' "$SMOKE_OUT" 2>/dev/null; then
  echo "build.sh: ERROR — embedded CLI smoke test failed: no JSON-RPC response on stdout" >&2
  echo "build.sh: --- CLI stdout (truncated) ---" >&2
  head -c 2000 "$SMOKE_OUT" >&2 || true
  echo "" >&2
  echo "build.sh: --- CLI stderr (truncated) ---" >&2
  head -c 2000 "$SMOKE_ERR" >&2 || true
  echo "" >&2
  exit 1
fi
echo "build.sh: embedded CLI smoke test passed (--mcp-stdio initialize round-trip)"

# ---------------------------------------------------------------------------
# STEP 6: optional install into /Applications.
#
# Off by default. Pass --install to opt in. The install step terminates any
# prior copy of the app (so the AppGroup container isn't locked) and ditto's
# the assembled bundle in.
# ---------------------------------------------------------------------------
if [[ "$INSTALL_FLAG" == "1" ]]; then
  echo "=== STEP 6: install to /Applications ==="
  INSTALLED_APP="/Applications/MacosWidgetsStatsFromWebsite.app"
  # Best-effort terminate any running copy so the file replace doesn't fail.
  pkill -f "$INSTALLED_APP/Contents/MacOS/MacosWidgetsStatsFromWebsite" 2>/dev/null || true
  sleep 1

  # Remove the prior install before copying. `ditto src dst` MERGES into an
  # existing destination — it doesn't replace it — so files only in the OLD
  # bundle (e.g. a stale `Contents/Resources/Browsers/Chromium.app/Contents/
  # Frameworks/Chromium Framework.framework/Versions/<old>` directory left
  # over from a previous Chromium version) survive the copy. The parent
  # .app's sealed `CodeResources` (sealed at build time, before ditto) knows
  # nothing about those leftover files, so `codesign -v` then fails with
  # `a sealed resource is missing or invalid` even though the bundle we just
  # built is itself fine. Pre-clearing the destination guarantees the
  # post-install verify is checking the same file set we just sealed.
  if [[ -d "$INSTALLED_APP" ]]; then
    rm -rf "$INSTALLED_APP"
  fi

  ditto "$APP_PATH" "$INSTALLED_APP"
  codesign -v "$INSTALLED_APP" >/dev/null 2>&1 \
    || { echo "build.sh: ERROR — installed .app failed signature verification at $INSTALLED_APP" >&2; exit 1; }
  echo "build.sh: installed to $INSTALLED_APP"
else
  echo "build.sh: --install not passed; not copying to /Applications."
  echo "build.sh:   Assembled bundle: $APP_PATH"
  echo "build.sh:   Embedded CLI:     $CLI_BIN_DEST"
fi

echo "build.sh: done."
