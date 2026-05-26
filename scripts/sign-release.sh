#!/usr/bin/env bash
# sign-release.sh — post-archive deep-sign for Sparkle/Developer ID releases.
#
# Why this exists (v0.21.22, voice 4002 / MBP-CC bridge msg-65036391):
#   Under Xcode 16+ the Release archive can NOT be signed with a single
#   xcodebuild pass because the App Groups + keychain-access-groups
#   entitlements legitimately require a provisioning profile under Manual
#   signing, and Developer ID distribution is profile-free. Automatic +
#   Developer ID Application is also an Xcode conflict. The working
#   pattern is:
#     1. xcodebuild archive with CODE_SIGN_IDENTITY="-" (ad-hoc).
#     2. This script walks the .app inside-out and re-signs every nested
#        bundle with the real "Developer ID Application" identity using
#        each bundle's correct entitlements.
#     3. xcodebuild -exportArchive ... -exportOptionsPlist (uses manual
#        signingCertificate=Developer ID Application from scripts/
#        ExportOptions.plist — accepts the already-signed archive
#        without redoing the signature).
#     4. notarytool submit + xcrun stapler staple.
#
# Usage:
#   ./scripts/sign-release.sh <path/to/.app or path/to/.xcarchive> [IDENTITY]
# Defaults IDENTITY to "Developer ID Application: Ethan Sarif-Kattan (T34G959ZG8)".
# Exits non-zero on any failed signature.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <path/to/.app or path/to/.xcarchive> [IDENTITY]" >&2
    exit 1
fi

INPUT="$1"
IDENTITY="${2:-Developer ID Application: Ethan Sarif-Kattan (T34G959ZG8)}"

# Resolve to the actual .app, whether the caller passed a .app or .xcarchive.
if [[ -d "$INPUT" && "$INPUT" == *.xcarchive ]]; then
    APP_CANDIDATES=("$INPUT"/Products/Applications/*.app)
    if [[ ${#APP_CANDIDATES[@]} -ne 1 || ! -d "${APP_CANDIDATES[0]}" ]]; then
        echo "sign-release.sh: ERROR — could not find exactly one .app inside $INPUT/Products/Applications" >&2
        exit 1
    fi
    APP="${APP_CANDIDATES[0]}"
elif [[ -d "$INPUT" && "$INPUT" == *.app ]]; then
    APP="$INPUT"
else
    echo "sign-release.sh: ERROR — input must be a .app or .xcarchive directory: $INPUT" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_ENTITLEMENTS="$REPO_ROOT/MacosWidgetsStatsFromWebsite/Apps/MainApp/MacosWidgetsStatsFromWebsite.entitlements"
WIDGET_ENTITLEMENTS="$REPO_ROOT/MacosWidgetsStatsFromWebsite/Apps/WidgetExtension/MacosWidgetsStatsFromWebsiteWidget.entitlements"

# v0.21.37 — Chromium helper entitlements directory. Mirrors what
# scripts/embed-chromium.sh applies during the Xcode build phase. We HAVE to
# re-apply these here because sign-release.sh runs AFTER embed-chromium.sh
# during the CI flow (xcodebuild archive → sign-release.sh → notarize), and
# any plain `codesign --force --sign … "$helper"` call without --entitlements
# strips the previously-applied entitlements blob.
#
# v0.21.30–v0.21.36 shipped Chromium helpers with NO entitlements because
# sign-release.sh re-signed every helper bare. Under Hardened Runtime that
# means the renderer hits EXC_BREAKPOINT (SIGTRAP) on its first JIT compile
# inside V8 — surfaces to the scraper as "Target crashed method=Page.enable"
# in the CDP log. See LEARNINGS.md for the full diagnosis arc.
CHROMIUM_ENTITLEMENTS_DIR="$REPO_ROOT/scripts/cft-entitlements"
CHROMIUM_APP_ENTITLEMENTS="$CHROMIUM_ENTITLEMENTS_DIR/app.plist"
CHROMIUM_HELPER_ENTITLEMENTS="$CHROMIUM_ENTITLEMENTS_DIR/helper.plist"
CHROMIUM_HELPER_RENDERER_ENTITLEMENTS="$CHROMIUM_ENTITLEMENTS_DIR/helper-renderer.plist"
CHROMIUM_HELPER_GPU_ENTITLEMENTS="$CHROMIUM_ENTITLEMENTS_DIR/helper-gpu.plist"
CHROMIUM_HELPER_PLUGIN_ENTITLEMENTS="$CHROMIUM_ENTITLEMENTS_DIR/helper-plugin.plist"

for entitlements_file in "$MAIN_ENTITLEMENTS" "$WIDGET_ENTITLEMENTS" \
    "$CHROMIUM_APP_ENTITLEMENTS" "$CHROMIUM_HELPER_ENTITLEMENTS" \
    "$CHROMIUM_HELPER_RENDERER_ENTITLEMENTS" "$CHROMIUM_HELPER_GPU_ENTITLEMENTS" \
    "$CHROMIUM_HELPER_PLUGIN_ENTITLEMENTS"; do
    if [[ ! -f "$entitlements_file" ]]; then
        echo "sign-release.sh: ERROR — entitlements file missing: $entitlements_file" >&2
        exit 1
    fi
done

# Resolve the canonical Chromium-helper-entitlements path for a given helper
# bundle name. Pattern-matches the .app basename. Mirrors the case-block in
# scripts/embed-chromium.sh (step 2 of the embed pass) so any name additions
# upstream Chromium ships in future are handled in BOTH scripts.
chromium_helper_entitlements_for() {
    local helper_basename="$1"
    case "$helper_basename" in
        *"Helper (Renderer)"*) printf '%s' "$CHROMIUM_HELPER_RENDERER_ENTITLEMENTS" ;;
        *"Helper (GPU)"*)      printf '%s' "$CHROMIUM_HELPER_GPU_ENTITLEMENTS" ;;
        *"Helper (Plugin)"*)   printf '%s' "$CHROMIUM_HELPER_PLUGIN_ENTITLEMENTS" ;;
        # Catch-all for Helper.app / Helper (Alerts).app / future utility
        # helpers. The base helper.plist grants disable-library-validation
        # only (no JIT) — matches Chromium's upstream chrome/app/
        # helper-entitlements.plist.
        *)                     printf '%s' "$CHROMIUM_HELPER_ENTITLEMENTS" ;;
    esac
}

echo "sign-release.sh: target  = $APP"
echo "sign-release.sh: identity= $IDENTITY"

# Helper — sign a single path with the given entitlements (or none).
sign() {
    local target="$1"
    local entitlements_file="${2:-}"
    if [[ -n "$entitlements_file" ]]; then
        /usr/bin/codesign --force --options runtime --timestamp \
            --entitlements "$entitlements_file" \
            --sign "$IDENTITY" \
            "$target"
    else
        /usr/bin/codesign --force --options runtime --timestamp \
            --sign "$IDENTITY" \
            "$target"
    fi
}

# 1. Embedded Chromium — sign innermost-first. The bundled Chromium ships
#    its own Info.plist + nested helpers; we re-sign them with our team's
#    Developer ID so the outer notarize pass accepts the whole tree.
CHROMIUM_APP="$APP/Contents/Resources/Browsers/Chromium.app"
if [[ -d "$CHROMIUM_APP" ]]; then
    echo "sign-release.sh: signing embedded Chromium tree..."
    # Sign dylibs first
    while IFS= read -r -d '' dylib; do
        sign "$dylib"
    done < <(find "$CHROMIUM_APP/Contents/Frameworks" -name "*.dylib" -print0 2>/dev/null)
    # Chromium also ships a few loose helper executables directly under
    # Chromium Framework.framework/Versions/<rev>/Helpers/ (for example
    # chrome_crashpad_handler, app_mode_loader, and web_app_shortcut_copier).
    # They are not .app/.xpc bundles and not .dylibs, so the older signing
    # walk missed them even though codesign --deep verified the outer tree.
    # Apple notarization v0.21.30 rejected exactly these helpers for lacking
    # our Developer ID signature + secure timestamp; sign each executable
    # helper explicitly before sealing the framework wrapper.
    while IFS= read -r -d '' helper_tool; do
        sign "$helper_tool"
    done < <(
        find "$CHROMIUM_APP/Contents/Frameworks/Chromium Framework.framework/Versions" \
            -path "*/Helpers/*" \
            -type f \
            -perm -111 \
            -print0 2>/dev/null
    )
    # Sign nested helper bundles (helpers run as separate processes).
    #
    # v0.21.37 (root cause of "Target crashed method=Page.enable"): we MUST
    # apply each helper's correct entitlements plist here. Bare `sign "$helper"`
    # strips the entitlements that scripts/embed-chromium.sh applied during the
    # Xcode archive phase, leaving the renderer / GPU / plugin helpers with no
    # JIT or unsigned-executable-memory grant. Under Hardened Runtime that
    # means V8 SIGTRAPs (EXC_BREAKPOINT) on its very first JIT compile, the
    # CDP socket disconnects, and every scrape times out at the Page.enable
    # step. v0.21.30–v0.21.36 shipped without these grants and were broken
    # for all four trackers; readings.json showed consecutiveFailureCount
    # climbing through the day with `lastError="Timed out loading …"`.
    #
    # Entitlement assignment per Chromium helper kind (mirrors upstream
    # chrome/app/helper-*-entitlements.plist):
    #   Helper (Renderer) → allow-jit + allow-unsigned-executable-memory + disable-library-validation
    #   Helper (GPU)      → same set as Renderer
    #   Helper (Plugin)   → allow-unsigned-executable-memory + disable-library-validation
    #   Helper (Alerts)
    #     + base Helper   → disable-library-validation only
    # .xpc bundles (Crashpad, etc.) live alongside the helpers and only need
    # the catch-all helper.plist (no JIT). The same chromium_helper_entitlements_for
    # helper case-block applies for them since they're not (Renderer|GPU|Plugin).
    while IFS= read -r -d '' helper; do
        helper_entitlements="$(chromium_helper_entitlements_for "$(basename "$helper")")"
        sign "$helper" "$helper_entitlements"
    done < <(find "$CHROMIUM_APP/Contents/Frameworks/Chromium Framework.framework/Versions" -type d \( -name "*.app" -o -name "*.xpc" \) -print0 2>/dev/null)
    # Sign the Chromium Framework versioned bundle. The framework wrapper
    # itself doesn't host an executable that goes through Hardened-Runtime
    # exec-time checks (it's loaded by the outer Chromium.app), so the bare
    # sign with no entitlements is correct here — matches upstream Chromium's
    # own signing flow and what scripts/embed-chromium.sh does at step 3.
    while IFS= read -r -d '' framework; do
        sign "$framework"
    done < <(find "$CHROMIUM_APP/Contents/Frameworks" -name "*.framework" -print0 2>/dev/null)
    # Sign the outer Chromium.app with the upstream chrome/app/app-entitlements.plist
    # equivalent (disable-library-validation + allow-unsigned-executable-memory +
    # allow-jit). The browser process loads Chromium Framework dylibs and may
    # JIT its own code paths under some configs; matching upstream's grant is
    # the safe default. v0.21.30–v0.21.36 signed this bare too, which on some
    # configs prevented the browser process from loading the framework on cold
    # spawn — bundled into the same root-cause class as the renderer SIGTRAP.
    sign "$CHROMIUM_APP" "$CHROMIUM_APP_ENTITLEMENTS"
else
    echo "sign-release.sh: (no embedded Chromium.app — skipping)"
fi

# 2. Sparkle framework — XPCs first, then Autoupdate, then Updater.app, then
#    the framework wrapper.
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "sign-release.sh: signing Sparkle.framework tree..."
    SPARKLE_VERSIONS_CURRENT="$SPARKLE_FRAMEWORK/Versions/Current"
    if [[ -d "$SPARKLE_VERSIONS_CURRENT/XPCServices" ]]; then
        for xpc in "$SPARKLE_VERSIONS_CURRENT/XPCServices"/*.xpc; do
            [[ -d "$xpc" ]] && sign "$xpc"
        done
    fi
    [[ -f "$SPARKLE_VERSIONS_CURRENT/Autoupdate" ]] && sign "$SPARKLE_VERSIONS_CURRENT/Autoupdate"
    [[ -d "$SPARKLE_VERSIONS_CURRENT/Updater.app" ]] && sign "$SPARKLE_VERSIONS_CURRENT/Updater.app"
    sign "$SPARKLE_FRAMEWORK"
fi

# 3. Widget extension — uses its OWN sandbox-enabled entitlements file
#    (NOT the main app's sandbox-disabled file). Embedded inside the
#    main app's Contents/PlugIns/.
WIDGET_APPEX="$APP/Contents/PlugIns/MacosWidgetsStatsFromWebsiteWidget.appex"
if [[ -d "$WIDGET_APPEX" ]]; then
    echo "sign-release.sh: signing widget extension with widget-specific entitlements..."
    sign "$WIDGET_APPEX" "$WIDGET_ENTITLEMENTS"
fi

# 4. Embedded CLI binary (lives at Contents/MacOS/macos-widgets-stats-from-website
#    alongside the main GUI executable — see scripts/build.sh STEP 4).
CLI_BIN="$APP/Contents/MacOS/macos-widgets-stats-from-website"
if [[ -f "$CLI_BIN" ]]; then
    echo "sign-release.sh: signing embedded CLI binary..."
    sign "$CLI_BIN"
fi

# 5. Finally, the outer .app — applies the main-app entitlements (sandbox
#    disabled, App Groups, Hardened Runtime exceptions for the Chromium
#    spawn). Outer-app signing is what seals the bundle, so this MUST run
#    after every nested signature has been applied.
echo "sign-release.sh: signing outer .app..."
sign "$APP" "$MAIN_ENTITLEMENTS"

# 6. Verify the whole tree. `--deep --strict` traverses every nested
#    bundle; any signature mismatch will fail here loud-and-early before
#    we ship to notarization.
echo "sign-release.sh: verifying signatures..."
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "sign-release.sh: done."
