#!/usr/bin/env bash
set -euo pipefail

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
for arg in "$@"; do
  if [[ "$arg" == "--dev-resign" ]]; then
    DEV_RESIGN_FLAG=1
  fi
done

xcodegen

XCODEBUILD_SIGNING_FLAGS=()
if [[ "${ALLOW_PROVISIONING_UPDATES:-}" == "1" ]]; then
  XCODEBUILD_SIGNING_FLAGS+=("-allowProvisioningUpdates")
fi

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
  "${XCODEBUILD_SIGNING_FLAGS[@]}" \
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
if [[ "$DEV_RESIGN_FLAG" == "1" ]]; then
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
