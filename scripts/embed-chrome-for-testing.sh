#!/usr/bin/env bash
#
# embed-chrome-for-testing.sh
#
# Xcode Run Script Build Phase entry point. Embeds the vendored Chrome for
# Testing bundle into the built product so the app can launch CFT without
# any runtime download.
#
# Reads the host arch from Xcode's PLATFORM-aware variables, copies the
# matching `vendor/chrome-for-testing/<arch>/Google Chrome for Testing.app`
# into `<built-product>.app/Contents/Resources/Browsers/`, and re-signs the
# nested CFT bundle with the outer app's signing identity so the outer
# codesign-and-notarize pass succeeds.
#
# This runs as a Build Phase (see project.yml: targets.MacosWidgetsStats…
# .preBuildScripts / postCompileScripts), placed BEFORE the "Sign On Copy"
# stage so the embedded CFT participates in the outer signature.
#
# Required Xcode env vars:
#   PROJECT_DIR                — repo root (resolved by Xcode)
#   CONFIGURATION_BUILD_DIR    — where <product>.app lives
#   FULL_PRODUCT_NAME          — "MacosWidgetsStatsFromWebsite.app"
#   ARCHS or CURRENT_ARCH      — which arch we're building for
#   EXPANDED_CODE_SIGN_IDENTITY (optional) — signing identity to re-sign nested
#
# Environment knobs:
#   SKIP_CHROME_FOR_TESTING_EMBED=1
#                              — skip embed entirely (don't error, but the
#                                resulting build won't have CFT and will
#                                hard-fail at runtime if the bundle is missing).
#                                Use only when you've already manually placed
#                                a CFT bundle into Resources/Browsers.

set -euo pipefail

if [ "${SKIP_CHROME_FOR_TESTING_EMBED:-0}" = "1" ]; then
    echo "embed-chrome-for-testing.sh: SKIP_CHROME_FOR_TESTING_EMBED=1 — skipping."
    exit 0
fi

if [ -z "${PROJECT_DIR:-}" ] || [ -z "${CONFIGURATION_BUILD_DIR:-}" ] || [ -z "${FULL_PRODUCT_NAME:-}" ]; then
    echo "embed-chrome-for-testing.sh: ERROR — missing required Xcode env vars (PROJECT_DIR, CONFIGURATION_BUILD_DIR, FULL_PRODUCT_NAME)." >&2
    exit 1
fi

# Pick which arch(es) to embed. Xcode passes:
#   - CURRENT_ARCH=arm64           (incremental Debug build, single arch)
#   - ARCHS="arm64 x86_64"         (Release archive, universal)
# A universal app needs BOTH CFT bundles available so the Apple-Silicon AND
# Intel slices can each launch a matching CFT. We satisfy that by writing
# each arch's CFT into a separate per-arch subdirectory and letting the
# Swift runtime pick the matching one via #if arch(...).
EMBED_ARCHES=""
if [ -n "${ARCHS:-}" ]; then
    EMBED_ARCHES="$ARCHS"
elif [ -n "${CURRENT_ARCH:-}" ] && [ "${CURRENT_ARCH}" != "undefined_arch" ]; then
    EMBED_ARCHES="$CURRENT_ARCH"
fi

if [ -z "$EMBED_ARCHES" ]; then
    echo "embed-chrome-for-testing.sh: ERROR — could not resolve build arch (ARCHS / CURRENT_ARCH both unset)." >&2
    exit 1
fi

# Normalize archs → vendor arches.
NORMALIZED_VENDOR_ARCHES=""
for a in $EMBED_ARCHES; do
    case "$a" in
        arm64) NORMALIZED_VENDOR_ARCHES="$NORMALIZED_VENDOR_ARCHES mac-arm64" ;;
        x86_64) NORMALIZED_VENDOR_ARCHES="$NORMALIZED_VENDOR_ARCHES mac-x64" ;;
        undefined_arch) ;;
        *)
            echo "embed-chrome-for-testing.sh: ERROR — unsupported build arch '$a'." >&2
            exit 1
            ;;
    esac
done
# Strip leading whitespace.
NORMALIZED_VENDOR_ARCHES="$(printf '%s' "$NORMALIZED_VENDOR_ARCHES" | /usr/bin/awk '{$1=$1; print}')"

if [ -z "$NORMALIZED_VENDOR_ARCHES" ]; then
    echo "embed-chrome-for-testing.sh: ERROR — no usable arches in '$EMBED_ARCHES'." >&2
    exit 1
fi

echo "embed-chrome-for-testing.sh: embedding CFT for arches: $NORMALIZED_VENDOR_ARCHES"

VENDOR_ROOT="$PROJECT_DIR/vendor/chrome-for-testing"
ENTITLEMENTS_DIR="$PROJECT_DIR/scripts/cft-entitlements"

# Fetch any missing or stale per-arch CFT bundles up front. We never
# silently fall back to host-only — if the build wants x86_64 too, we must
# vendor it (otherwise the universal slice on Intel Macs would not have a
# working bundled browser).
#
# Staleness check: VERSION marker exists AND matches every per-arch
# Info.plist's CFBundleShortVersionString. If only ONE arch is up to
# date and the marker mismatches the other, we must re-fetch (a previous
# --only-host run for a different host arch is the typical cause).
needs_refetch=0
for vendor_arch in $NORMALIZED_VENDOR_ARCHES; do
    info_plist="$VENDOR_ROOT/$vendor_arch/Google Chrome for Testing.app/Contents/Info.plist"
    exe="$VENDOR_ROOT/$vendor_arch/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
    if [ ! -x "$exe" ] || [ ! -f "$info_plist" ]; then
        needs_refetch=1
        break
    fi
    if [ -f "$VENDOR_ROOT/VERSION" ]; then
        marker_version="$(cat "$VENDOR_ROOT/VERSION")"
        bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true)"
        if [ -n "$marker_version" ] && [ -n "$bundle_version" ] && [ "$marker_version" != "$bundle_version" ]; then
            echo "embed-chrome-for-testing.sh: $vendor_arch is stale ($bundle_version on disk vs VERSION marker $marker_version)."
            needs_refetch=1
            break
        fi
    fi
done

if [ "$needs_refetch" = "1" ]; then
    # Cross-arch fetch — pull every requested arch. We can't safely use
    # --only-host because the requested set may include the non-host arch
    # for a universal build.
    fetch_args=""
    arch_count_check=0
    for _ in $NORMALIZED_VENDOR_ARCHES; do arch_count_check=$((arch_count_check + 1)); done
    if [ "$arch_count_check" = "1" ]; then
        # Single-arch build — check if it's host arch.
        only_arch="$(printf '%s\n' "$NORMALIZED_VENDOR_ARCHES" | /usr/bin/awk '{print $1}')"
        host_arch="$(/usr/bin/uname -m)"
        if { [ "$only_arch" = "mac-arm64" ] && [ "$host_arch" = "arm64" ]; } \
           || { [ "$only_arch" = "mac-x64" ] && [ "$host_arch" = "x86_64" ]; }; then
            fetch_args="--only-host"
        fi
    fi
    # --force ensures the fetch script re-downloads even if a stale bundle
    # for the host-arch is present but the non-host arch is missing/old.
    if ! /usr/bin/env bash "$PROJECT_DIR/scripts/fetch-chrome-for-testing.sh" $fetch_args --force; then
        echo "embed-chrome-for-testing.sh: ERROR — fetch-chrome-for-testing.sh failed." >&2
        exit 1
    fi
fi

PRODUCT_APP="$CONFIGURATION_BUILD_DIR/$FULL_PRODUCT_NAME"
if [ ! -d "$PRODUCT_APP" ]; then
    echo "embed-chrome-for-testing.sh: ERROR — built product not found at '$PRODUCT_APP'." >&2
    exit 1
fi

DEST_BROWSERS_DIR="$PRODUCT_APP/Contents/Resources/Browsers"
mkdir -p "$DEST_BROWSERS_DIR"

# Single-arch builds keep the legacy on-disk layout:
#   Resources/Browsers/Google Chrome for Testing.app
# Multi-arch builds use per-arch subdirs:
#   Resources/Browsers/mac-arm64/Google Chrome for Testing.app
#   Resources/Browsers/mac-x64/Google Chrome for Testing.app
# Swift's resolveBrowser() probes the per-arch path first, then falls back
# to the flat path.
arch_count=0
for _ in $NORMALIZED_VENDOR_ARCHES; do arch_count=$((arch_count + 1)); done

# Track embedded CFT bundle paths + which need re-signing in temp files.
# Paths contain spaces ("Google Chrome for Testing.app") so word-splitting
# via `for x in $VAR` would tokenize them — keep one path per line.
EMBED_LIST_FILE="$(/usr/bin/mktemp -t cft-embed-paths-XXXXXX)"
# Subset of EMBED_LIST_FILE we actually need to re-sign this build (i.e.
# bundles we just copied — already-up-to-date bundles are skipped to keep
# incremental builds fast).
RESIGN_LIST_FILE="$(/usr/bin/mktemp -t cft-resign-paths-XXXXXX)"

# embed_one_arch: copy a single vendored CFT bundle to its destination,
# skipping the work if the destination already matches the vendored
# CFBundleShortVersionString. Outputs the dest path (always) to
# EMBED_LIST_FILE and (only if we copied) to RESIGN_LIST_FILE.
embed_one_arch() {
    src_app="$1"
    dst_app="$2"

    src_version=""
    dst_version=""
    if [ -f "$src_app/Contents/Info.plist" ]; then
        src_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$src_app/Contents/Info.plist" 2>/dev/null || true)"
    fi
    if [ -x "$dst_app/Contents/MacOS/Google Chrome for Testing" ] \
        && [ -f "$dst_app/Contents/Info.plist" ]; then
        dst_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dst_app/Contents/Info.plist" 2>/dev/null || true)"
    fi

    if [ -n "$src_version" ] && [ "$src_version" = "$dst_version" ]; then
        # Already up to date — verify the existing signature uses the
        # CURRENT outer-app signing identity. A previous build that ran
        # without a signing identity (CODE_SIGNING_ALLOWED=NO or no Xcode
        # cert installed) could have left the Google-signed bundle in
        # place; that bundle has a valid non-empty Google TeamIdentifier,
        # which would fool a "just check it's not ad-hoc" probe. We
        # explicitly require the team to match RESIGN_IDENTITY's team
        # (extracted from the embedded signature) before skipping.
        outer_team=""
        if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
            outer_team="$(/usr/bin/codesign -dv "$PRODUCT_APP" 2>&1 | /usr/bin/grep -E '^TeamIdentifier=' | /usr/bin/cut -d= -f2- || true)"
        fi
        existing_team="$(/usr/bin/codesign -dv "$dst_app" 2>&1 | /usr/bin/grep -E '^TeamIdentifier=' | /usr/bin/cut -d= -f2- || true)"
        if [ -n "$existing_team" ] && [ "$existing_team" != "not set" ] \
            && { [ -z "$outer_team" ] || [ "$existing_team" = "$outer_team" ]; }; then
            echo "embed-chrome-for-testing.sh: $dst_app already at $dst_version (team $existing_team) — skipping copy + resign."
            printf '%s\n' "$dst_app" >> "$EMBED_LIST_FILE"
            return 0
        fi
        if [ -n "$existing_team" ] && [ "$existing_team" != "$outer_team" ]; then
            echo "embed-chrome-for-testing.sh: $dst_app team mismatch ('$existing_team' vs outer '$outer_team') — forcing re-sign."
        fi
    fi

    rm -rf "$dst_app"
    /usr/bin/ditto "$src_app" "$dst_app"
    printf '%s\n' "$dst_app" >> "$EMBED_LIST_FILE"
    printf '%s\n' "$dst_app" >> "$RESIGN_LIST_FILE"
}

if [ "$arch_count" = "1" ]; then
    only_arch="$(printf '%s\n' "$NORMALIZED_VENDOR_ARCHES" | /usr/bin/awk '{print $1}')"
    # Wipe any legacy per-arch dirs from a previous universal incremental build.
    rm -rf "$DEST_BROWSERS_DIR/mac-arm64" "$DEST_BROWSERS_DIR/mac-x64"
    embed_one_arch \
        "$VENDOR_ROOT/$only_arch/Google Chrome for Testing.app" \
        "$DEST_BROWSERS_DIR/Google Chrome for Testing.app"
else
    # Multi-arch: wipe the flat fallback path to avoid mismatching with the
    # per-arch dirs.
    rm -rf "$DEST_BROWSERS_DIR/Google Chrome for Testing.app"
    for vendor_arch in $NORMALIZED_VENDOR_ARCHES; do
        per_arch_dir="$DEST_BROWSERS_DIR/$vendor_arch"
        mkdir -p "$per_arch_dir"
        embed_one_arch \
            "$VENDOR_ROOT/$vendor_arch/Google Chrome for Testing.app" \
            "$per_arch_dir/Google Chrome for Testing.app"
    done
fi

# Strip quarantine on every embedded bundle.
while IFS= read -r embedded_app; do
    [ -z "$embedded_app" ] && continue
    /usr/bin/xattr -dr com.apple.quarantine "$embedded_app" 2>/dev/null || true
done < "$EMBED_LIST_FILE"

# Re-sign every embedded CFT bundle (and every nested dylib/helper inside)
# with the outer app's identity. Google ships CFT signed by Google's
# developer cert; for outer notarization to accept the embedded bundle,
# AND for dyld to actually load Chrome's bundled dylibs under Hardened
# Runtime + Library Validation, every Mach-O inside CFT must be signed by
# our team.
#
# `codesign --deep` recurses through helpers/frameworks/.dSYM, but it does
# NOT descend into the contained dylibs (e.g. libGLESv2.dylib,
# libvk_swiftshader.dylib, libEGL.dylib) — those ship adhoc/linker-signed
# from Google. Under Hardened Runtime, library validation rejects loading
# a library whose Team ID doesn't match the loader's, so we sign the
# dylibs explicitly first, bottom-up: dylibs → helpers → CFT.app, then
# repeat per embedded bundle.
RESIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [ -z "$RESIGN_IDENTITY" ] || [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
    echo "embed-chrome-for-testing.sh: no signing identity available — leaving CFT signed by Google."
elif [ ! -s "$RESIGN_LIST_FILE" ]; then
    echo "embed-chrome-for-testing.sh: every embedded CFT bundle was up to date — no re-sign needed."
else
    while IFS= read -r cft; do
        [ -z "$cft" ] && continue
        echo "embed-chrome-for-testing.sh: re-signing nested CFT bundle at $cft (identity '$RESIGN_IDENTITY') ..."

        # 1a) Sign every standalone dylib bottom-up. `find -print0 | xargs -0`
        #     keeps space-in-path safe.
        /usr/bin/find "$cft" -type f -name '*.dylib' -print0 \
            | /usr/bin/xargs -0 -n 1 /usr/bin/codesign --force --sign "$RESIGN_IDENTITY" \
                --options runtime \
                --preserve-metadata=identifier,requirements

        # 1b) Sign every STANDALONE Mach-O executable inside the CFT
        #     bundle — i.e. plain executable files that aren't part of an
        #     embedded .app/.framework bundle's principal executable.
        #     CFT ships `chrome_crashpad_handler`, `app_mode_loader`,
        #     `web_app_shortcut_copier` (and any future tools Google adds)
        #     as plain executables under the Framework's
        #     Versions/<X.Y.Z>/Helpers/ directory. Notarization scans every
        #     nested Mach-O; an ad-hoc one fails the outer notarize.
        #
        #     Detection: walk the CFT bundle recursively for executable
        #     regular files whose first 4 bytes are a Mach-O magic
        #     number, then skip the ones that are an .app's principal
        #     executable (those are handled by step 2 which signs the
        #     wrapping .app bundle). We DON'T skip everything under
        #     `*.framework/*` — that exclusion would miss exactly the
        #     `Versions/<X.Y.Z>/Helpers/<tool>` standalone executables
        #     we care about.
        standalone_list="$(/usr/bin/mktemp -t cft-standalone-XXXXXX)"
        # find prints all executable regular files. We walk the list with a
        # while-loop so paths-with-spaces don't get word-split (xargs -I
        # would hit "command line cannot be assembled, too long" on the
        # ~500+ Mach-O files inside CFT).
        candidate_list="$(/usr/bin/mktemp -t cft-cands-XXXXXX)"
        /usr/bin/find "$cft" -type f -perm -u+x ! -name '*.dylib' > "$candidate_list" 2>/dev/null || true

        while IFS= read -r p; do
            [ -z "$p" ] && continue
            # Skip the principal executable inside any .app — its wrapping
            # .app bundle is signed in step 2 (with proper helper
            # entitlements applied).
            case "$p" in
                *.app/Contents/MacOS/*) continue ;;
            esac
            if /usr/bin/file -b "$p" | /usr/bin/grep -q 'Mach-O'; then
                printf '%s\n' "$p" >> "$standalone_list"
            fi
        done < "$candidate_list"
        rm -f "$candidate_list"

        while IFS= read -r exe; do
            [ -z "$exe" ] && continue
            /usr/bin/codesign --force --sign "$RESIGN_IDENTITY" \
                --options runtime \
                --preserve-metadata=identifier,requirements \
                "$exe"
        done < "$standalone_list"
        rm -f "$standalone_list"

        # 2) Sign every helper .app with the Chrome entitlements set Google's
        #    CFT relies on. We can't `--preserve-metadata=entitlements`
        #    because the downloaded helpers are ad-hoc / linker-signed and
        #    therefore have an EMPTY entitlements blob — preserving that
        #    strips Chrome's required JIT / unsigned-executable-memory /
        #    disable-library-validation grants, breaking V8 and renderer
        #    process startup under Hardened Runtime. The plists in
        #    scripts/cft-entitlements/ mirror Chromium's canonical
        #    chrome/app/*-entitlements.plist files.
        helper_list="$(/usr/bin/mktemp -t cft-helpers-XXXXXX)"
        /usr/bin/find "$cft/Contents/Frameworks" -type d -name '*.app' 2>/dev/null > "$helper_list" || true
        while IFS= read -r helper; do
            [ -z "$helper" ] && continue
            base="$(basename "$helper")"
            entitlements_plist=""
            case "$base" in
                *"Helper (Renderer)"*)
                    entitlements_plist="$ENTITLEMENTS_DIR/helper-renderer.plist"
                    ;;
                *"Helper (GPU)"*)
                    entitlements_plist="$ENTITLEMENTS_DIR/helper-gpu.plist"
                    ;;
                *"Helper (Plugin)"*)
                    entitlements_plist="$ENTITLEMENTS_DIR/helper-plugin.plist"
                    ;;
                *)
                    # Catch-all for Helper.app, Helper (Alerts).app,
                    # utility helpers Google may add in future. The
                    # base helper.plist allows nested-library loading
                    # but does NOT grant JIT.
                    entitlements_plist="$ENTITLEMENTS_DIR/helper.plist"
                    ;;
            esac

            if [ ! -f "$entitlements_plist" ]; then
                echo "embed-chrome-for-testing.sh: ERROR — missing helper entitlements plist '$entitlements_plist'." >&2
                rm -f "$helper_list"
                exit 1
            fi

            /usr/bin/codesign --force --sign "$RESIGN_IDENTITY" \
                --options runtime \
                --entitlements "$entitlements_plist" \
                "$helper"
        done < "$helper_list"
        rm -f "$helper_list"

        # 3) Sign every framework bundle.
        fw_list="$(/usr/bin/mktemp -t cft-frameworks-XXXXXX)"
        /usr/bin/find "$cft/Contents/Frameworks" -type d -name '*.framework' 2>/dev/null > "$fw_list" || true
        while IFS= read -r fw; do
            [ -z "$fw" ] && continue
            /usr/bin/codesign --force --sign "$RESIGN_IDENTITY" \
                --options runtime \
                --preserve-metadata=identifier,requirements \
                "$fw"
        done < "$fw_list"
        rm -f "$fw_list"

        # 4) Sign the outer CFT.app itself. As with the helpers, the
        #    downloaded bundle has empty entitlements; preserve-metadata
        #    would strip the disable-library-validation grant the browser
        #    process needs to load its bundled framework. Apply the
        #    canonical app.plist entitlements (mirrors Chromium's
        #    chrome/app/app-entitlements.plist).
        /usr/bin/codesign --force --sign "$RESIGN_IDENTITY" \
            --options runtime \
            --entitlements "$ENTITLEMENTS_DIR/app.plist" \
            "$cft"
    done < "$RESIGN_LIST_FILE"
fi

# Re-sign the OUTER app over the now-embedded CFT bundle. The script runs as
# a postBuildScripts phase (i.e. after Xcode's built-in code-sign step), so
# the outer signature was computed before our new nested resource existed
# and is now stale. Without this re-sign, Gatekeeper / notarytool reject
# the outer bundle ("a sealed resource is missing or invalid").
#
# We use the entitlements file selected by the config (Debug or Release) and
# the same EXPANDED_CODE_SIGN_IDENTITY that Xcode used for the inner sign.
# Only re-sign when we actually re-embedded a CFT bundle this build —
# otherwise the outer sig still matches the unchanged Resources/Browsers
# tree, so re-signing is pointless work.
if [ -n "$RESIGN_IDENTITY" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -s "$RESIGN_LIST_FILE" ]; then
    ENTITLEMENTS_PATH=""
    if [ -n "${CODE_SIGN_ENTITLEMENTS:-}" ]; then
        # Xcode's CODE_SIGN_ENTITLEMENTS is repo-relative.
        if [ -f "$PROJECT_DIR/$CODE_SIGN_ENTITLEMENTS" ]; then
            ENTITLEMENTS_PATH="$PROJECT_DIR/$CODE_SIGN_ENTITLEMENTS"
        elif [ -f "$CODE_SIGN_ENTITLEMENTS" ]; then
            ENTITLEMENTS_PATH="$CODE_SIGN_ENTITLEMENTS"
        fi
    fi

    echo "embed-chrome-for-testing.sh: re-signing outer app with '$RESIGN_IDENTITY' (over embedded CFT) ..."
    if [ -n "$ENTITLEMENTS_PATH" ]; then
        /usr/bin/codesign --force --sign "$RESIGN_IDENTITY" \
            --options runtime \
            --entitlements "$ENTITLEMENTS_PATH" \
            "$PRODUCT_APP"
    else
        /usr/bin/codesign --force --sign "$RESIGN_IDENTITY" \
            --options runtime \
            --preserve-metadata=entitlements,requirements \
            "$PRODUCT_APP"
    fi
fi

# Final sanity check: the executable inside every embedded bundle is
# actually executable. If this fails the runtime ResolvedBrowser check
# would also fail, so surface it now.
while IFS= read -r cft; do
    [ -z "$cft" ] && continue
    embedded_exe="$cft/Contents/MacOS/Google Chrome for Testing"
    if [ ! -x "$embedded_exe" ]; then
        echo "embed-chrome-for-testing.sh: ERROR — embedded bundle has no launchable executable at '$embedded_exe'." >&2
        rm -f "$EMBED_LIST_FILE" "$RESIGN_LIST_FILE"
        exit 1
    fi
done < "$EMBED_LIST_FILE"

rm -f "$EMBED_LIST_FILE" "$RESIGN_LIST_FILE"

echo "embed-chrome-for-testing.sh: done. Embedded Chrome for Testing in $DEST_BROWSERS_DIR."
