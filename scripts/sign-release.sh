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

for entitlements_file in "$MAIN_ENTITLEMENTS" "$WIDGET_ENTITLEMENTS"; do
    if [[ ! -f "$entitlements_file" ]]; then
        echo "sign-release.sh: ERROR — entitlements file missing: $entitlements_file" >&2
        exit 1
    fi
done

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
    # Sign nested helper bundles (helpers run as separate processes)
    while IFS= read -r -d '' helper; do
        sign "$helper"
    done < <(find "$CHROMIUM_APP/Contents/Frameworks/Chromium Framework.framework/Versions" -type d \( -name "*.app" -o -name "*.xpc" \) -print0 2>/dev/null)
    # Sign the Chromium Framework versioned bundle
    while IFS= read -r -d '' framework; do
        sign "$framework"
    done < <(find "$CHROMIUM_APP/Contents/Frameworks" -name "*.framework" -print0 2>/dev/null)
    # Sign Chromium.app itself
    sign "$CHROMIUM_APP"
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
