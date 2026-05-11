#!/usr/bin/env bash
#
# embed-chromium.sh
#
# Xcode Run Script Build Phase entry point. Embeds the vendored upstream
# Chromium bundle into the built product so the app can launch Chromium
# without any runtime download.
#
# Reads the host arch from Xcode's PLATFORM-aware variables, copies the
# matching `vendor/chromium/<arch>/Chromium.app` into
# `<built-product>.app/Contents/Resources/Browsers/`, and re-signs the
# nested Chromium bundle with the outer app's signing identity so the
# outer codesign-and-notarize pass succeeds.
#
# Runs as a postBuildScripts phase (see project.yml: targets.MacosWidgetsStats…
# .postBuildScripts), AFTER Xcode's built-in code-sign step. We then re-sign
# the outer app over the now-embedded Chromium tree so Gatekeeper /
# notarytool don't reject the bundle for "a sealed resource is missing or
# invalid".
#
# Required Xcode env vars:
#   PROJECT_DIR                — repo root (resolved by Xcode)
#   CONFIGURATION_BUILD_DIR    — where <product>.app lives
#   FULL_PRODUCT_NAME          — "MacosWidgetsStatsFromWebsite.app"
#   ARCHS or CURRENT_ARCH      — which arch we're building for
#   EXPANDED_CODE_SIGN_IDENTITY (optional) — signing identity to re-sign nested
#
# Environment knobs:
#   SKIP_CHROMIUM_EMBED=1
#                              — skip embed entirely (don't error, but the
#                                resulting build won't have Chromium and will
#                                hard-fail at runtime if the bundle is missing).
#                                Use only when you've already manually placed
#                                a Chromium bundle into Resources/Browsers.
#   SKIP_CHROMIUM_FETCH=1
#                              — don't contact the snapshot bucket; require
#                                the requested vendor/chromium/<arch> bundles
#                                and VERSION marker to already exist locally.

set -euo pipefail

if [ "${SKIP_CHROMIUM_EMBED:-0}" = "1" ]; then
    echo "embed-chromium.sh: SKIP_CHROMIUM_EMBED=1 — skipping."
    exit 0
fi

if [ -z "${PROJECT_DIR:-}" ] || [ -z "${CONFIGURATION_BUILD_DIR:-}" ] || [ -z "${FULL_PRODUCT_NAME:-}" ]; then
    echo "embed-chromium.sh: ERROR — missing required Xcode env vars (PROJECT_DIR, CONFIGURATION_BUILD_DIR, FULL_PRODUCT_NAME)." >&2
    exit 1
fi

# Pick which arch(es) to embed. Xcode passes:
#   - CURRENT_ARCH=arm64           (incremental Debug build, single arch)
#   - ARCHS="arm64 x86_64"         (Release archive, universal)
# A universal app needs BOTH Chromium bundles available so the Apple-Silicon
# AND Intel slices can each launch a matching Chromium. We satisfy that by
# writing each arch's Chromium into a separate per-arch subdirectory and
# letting the Swift runtime pick the matching one via #if arch(...).
EMBED_ARCHES=""
if [ -n "${ARCHS:-}" ]; then
    EMBED_ARCHES="$ARCHS"
elif [ -n "${CURRENT_ARCH:-}" ] && [ "${CURRENT_ARCH}" != "undefined_arch" ]; then
    EMBED_ARCHES="$CURRENT_ARCH"
fi

if [ -z "$EMBED_ARCHES" ]; then
    echo "embed-chromium.sh: ERROR — could not resolve build arch (ARCHS / CURRENT_ARCH both unset)." >&2
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
            echo "embed-chromium.sh: ERROR — unsupported build arch '$a'." >&2
            exit 1
            ;;
    esac
done
# Strip leading whitespace.
NORMALIZED_VENDOR_ARCHES="$(printf '%s' "$NORMALIZED_VENDOR_ARCHES" | /usr/bin/awk '{$1=$1; print}')"

if [ -z "$NORMALIZED_VENDOR_ARCHES" ]; then
    echo "embed-chromium.sh: ERROR — no usable arches in '$EMBED_ARCHES'." >&2
    exit 1
fi

echo "embed-chromium.sh: embedding Chromium for arches: $NORMALIZED_VENDOR_ARCHES"

VENDOR_ROOT="$PROJECT_DIR/vendor/chromium"
# We reuse the CFT entitlements directory — upstream Chromium needs the
# same set of Hardened-Runtime exceptions (disable-library-validation +
# allow-unsigned-executable-memory + allow-jit for V8) so the canonical
# Chromium chrome/app/*-entitlements.plist values are correct for both.
ENTITLEMENTS_DIR="$PROJECT_DIR/scripts/cft-entitlements"
EMBEDDED_REVISION_MARKER_RELATIVE_PATH="Contents/Resources/macos-widgets-chromium-revision.txt"

revision_for_vendor_arch() {
    local vendor_arch="$1"
    if [ ! -f "$VENDOR_ROOT/VERSION" ]; then
        printf '\n'
        return 0
    fi
    /usr/bin/awk -F= -v arch="$vendor_arch" '$1 == arch { print $2; exit }' "$VENDOR_ROOT/VERSION"
}

# Fetch missing or stale per-arch Chromium bundles up front. Passing the
# requested vendor arch list keeps single-arch builds from downloading the
# other platform, while still letting fetch-chromium.sh do the authoritative
# LAST_CHANGE / CHROMIUM_REVISION staleness check.
if [ "${SKIP_CHROMIUM_FETCH:-0}" != "1" ]; then
    fetch_args=""
    for vendor_arch in $NORMALIZED_VENDOR_ARCHES; do
        fetch_args="$fetch_args --arch $vendor_arch"
    done
    if ! /usr/bin/env bash "$PROJECT_DIR/scripts/fetch-chromium.sh" $fetch_args; then
        echo "embed-chromium.sh: ERROR — fetch-chromium.sh failed." >&2
        exit 1
    fi
else
    echo "embed-chromium.sh: SKIP_CHROMIUM_FETCH=1 — using existing vendor/chromium contents."
fi

# Validate the requested vendor bundles and revision marker after the fetch
# step (or immediately when SKIP_CHROMIUM_FETCH=1). The embed copy compares
# this marker against the previously embedded marker so a new snapshot with
# the same CFBundleShortVersionString still refreshes correctly.
if [ ! -f "$VENDOR_ROOT/VERSION" ]; then
    echo "embed-chromium.sh: ERROR — missing $VENDOR_ROOT/VERSION; run scripts/fetch-chromium.sh." >&2
    exit 1
fi
for vendor_arch in $NORMALIZED_VENDOR_ARCHES; do
    info_plist="$VENDOR_ROOT/$vendor_arch/Chromium.app/Contents/Info.plist"
    exe="$VENDOR_ROOT/$vendor_arch/Chromium.app/Contents/MacOS/Chromium"
    vendor_revision="$(revision_for_vendor_arch "$vendor_arch")"
    if [ ! -x "$exe" ] || [ ! -f "$info_plist" ]; then
        echo "embed-chromium.sh: ERROR — missing launchable vendored Chromium for $vendor_arch under $VENDOR_ROOT." >&2
        exit 1
    fi
    if [ -z "$vendor_revision" ]; then
        echo "embed-chromium.sh: ERROR — VERSION marker has no revision line for $vendor_arch." >&2
        exit 1
    fi
done

PRODUCT_APP="$CONFIGURATION_BUILD_DIR/$FULL_PRODUCT_NAME"
if [ ! -d "$PRODUCT_APP" ]; then
    echo "embed-chromium.sh: ERROR — built product not found at '$PRODUCT_APP'." >&2
    exit 1
fi

DEST_BROWSERS_DIR="$PRODUCT_APP/Contents/Resources/Browsers"
mkdir -p "$DEST_BROWSERS_DIR"
outer_resign_needed=0

remove_if_exists() {
    local path_to_remove="$1"
    if [ -e "$path_to_remove" ] || [ -L "$path_to_remove" ]; then
        rm -rf "$path_to_remove"
        outer_resign_needed=1
    fi
}

# Clean up legacy bundles from prior CFT-based builds (0.13.0) that may have
# survived in the same DerivedData. Without this, an incremental build over a
# CFT-era artifact ships BOTH Chromium.app AND the old "Google Chrome for
# Testing.app", inflating the .app to ~700 MB.
remove_if_exists "$DEST_BROWSERS_DIR/Google Chrome for Testing.app"
remove_if_exists "$DEST_BROWSERS_DIR/mac-arm64/Google Chrome for Testing.app"
remove_if_exists "$DEST_BROWSERS_DIR/mac-x64/Google Chrome for Testing.app"

# Single-arch builds keep a flat on-disk layout:
#   Resources/Browsers/Chromium.app
# Multi-arch builds use per-arch subdirs:
#   Resources/Browsers/mac-arm64/Chromium.app
#   Resources/Browsers/mac-x64/Chromium.app
# Swift's bundledBrowserCandidates() probes the per-arch path first, then
# falls back to the flat path.
arch_count=0
for _ in $NORMALIZED_VENDOR_ARCHES; do arch_count=$((arch_count + 1)); done

# Track embedded bundle paths + which need re-signing in temp files. Paths
# contain spaces inside framework helpers ("Chromium Helper (Renderer).app")
# so word-splitting via `for x in $VAR` would tokenize them — keep one path
# per line.
RESIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
SIGNING_DISABLED=0
if [ -z "$RESIGN_IDENTITY" ] || [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
    SIGNING_DISABLED=1
fi
EMBED_LIST_FILE="$(/usr/bin/mktemp -t chromium-embed-paths-XXXXXX)"
RESIGN_LIST_FILE="$(/usr/bin/mktemp -t chromium-resign-paths-XXXXXX)"

cleanup_temp_files() {
    rm -f "$EMBED_LIST_FILE" "$RESIGN_LIST_FILE"
}
trap cleanup_temp_files EXIT

# embed_one_arch: copy a single vendored Chromium.app to its destination,
# skipping the work if the destination already matches the vendored revision
# marker + CFBundleShortVersionString AND the existing signature uses the
# current outer-app team. Outputs the dest path (always) to EMBED_LIST_FILE and
# (only if we copied) to RESIGN_LIST_FILE.
embed_one_arch() {
    local vendor_arch="$1"
    local src_app="$2"
    local dst_app="$3"

    local src_version=""
    local dst_version=""
    local src_revision
    local dst_revision=""
    src_revision="$(revision_for_vendor_arch "$vendor_arch")"
    if [ -f "$src_app/Contents/Info.plist" ]; then
        src_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$src_app/Contents/Info.plist" 2>/dev/null || true)"
    fi
    if [ -x "$dst_app/Contents/MacOS/Chromium" ] \
        && [ -f "$dst_app/Contents/Info.plist" ]; then
        dst_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dst_app/Contents/Info.plist" 2>/dev/null || true)"
        if [ -f "$dst_app/$EMBEDDED_REVISION_MARKER_RELATIVE_PATH" ]; then
            dst_revision="$(/bin/cat "$dst_app/$EMBEDDED_REVISION_MARKER_RELATIVE_PATH" 2>/dev/null || true)"
        fi
    fi

    if [ -n "$src_version" ] && [ "$src_version" = "$dst_version" ] \
        && [ -n "$src_revision" ] && [ "$src_revision" = "$dst_revision" ]; then
        local outer_team=""
        local existing_team=""
        if [ -n "$RESIGN_IDENTITY" ]; then
            outer_team="$(/usr/bin/codesign -dv "$PRODUCT_APP" 2>&1 | /usr/bin/grep -E '^TeamIdentifier=' | /usr/bin/cut -d= -f2- || true)"
        fi
        existing_team="$(/usr/bin/codesign -dv "$dst_app" 2>&1 | /usr/bin/grep -E '^TeamIdentifier=' | /usr/bin/cut -d= -f2- || true)"
        if [ "$SIGNING_DISABLED" = "1" ]; then
            echo "embed-chromium.sh: $dst_app already at $dst_version revision $dst_revision (signing disabled) — skipping copy."
            printf '%s\n' "$dst_app" >> "$EMBED_LIST_FILE"
            return 0
        fi
        if { [ -n "$existing_team" ] && [ "$existing_team" != "not set" ] \
                && { [ -z "$outer_team" ] || [ "$existing_team" = "$outer_team" ]; }; } \
            || { [ "$RESIGN_IDENTITY" = "-" ] && [ "$existing_team" = "not set" ]; }; then
            echo "embed-chromium.sh: $dst_app already at $dst_version revision $dst_revision (team $existing_team) — skipping copy + resign."
            printf '%s\n' "$dst_app" >> "$EMBED_LIST_FILE"
            return 0
        fi
        if [ -n "$existing_team" ] && [ "$existing_team" != "$outer_team" ]; then
            echo "embed-chromium.sh: $dst_app team mismatch ('$existing_team' vs outer '$outer_team') — forcing re-sign."
        fi
    fi

    remove_if_exists "$dst_app"
    /usr/bin/ditto "$src_app" "$dst_app"
    mkdir -p "$dst_app/Contents/Resources"
    printf '%s\n' "$src_revision" > "$dst_app/$EMBEDDED_REVISION_MARKER_RELATIVE_PATH"
    outer_resign_needed=1
    printf '%s\n' "$dst_app" >> "$EMBED_LIST_FILE"
    printf '%s\n' "$dst_app" >> "$RESIGN_LIST_FILE"
}

if [ "$arch_count" = "1" ]; then
    only_arch="$(printf '%s\n' "$NORMALIZED_VENDOR_ARCHES" | /usr/bin/awk '{print $1}')"
    # Wipe any legacy per-arch dirs from a previous universal incremental build.
    remove_if_exists "$DEST_BROWSERS_DIR/mac-arm64"
    remove_if_exists "$DEST_BROWSERS_DIR/mac-x64"
    embed_one_arch \
        "$only_arch" \
        "$VENDOR_ROOT/$only_arch/Chromium.app" \
        "$DEST_BROWSERS_DIR/Chromium.app"
else
    # Multi-arch: wipe the flat fallback path to avoid mismatching with the
    # per-arch dirs.
    remove_if_exists "$DEST_BROWSERS_DIR/Chromium.app"
    for vendor_arch in $NORMALIZED_VENDOR_ARCHES; do
        per_arch_dir="$DEST_BROWSERS_DIR/$vendor_arch"
        mkdir -p "$per_arch_dir"
        embed_one_arch \
            "$vendor_arch" \
            "$VENDOR_ROOT/$vendor_arch/Chromium.app" \
            "$per_arch_dir/Chromium.app"
    done
fi

# Strip quarantine on every embedded bundle.
while IFS= read -r embedded_app; do
    [ -z "$embedded_app" ] && continue
    /usr/bin/xattr -dr com.apple.quarantine "$embedded_app" 2>/dev/null || true
done < "$EMBED_LIST_FILE"

# Re-sign every embedded Chromium bundle (and every nested dylib/helper
# inside) with the outer app's identity. Upstream Chromium ships ad-hoc /
# linker-signed; for outer notarization to accept the embedded bundle, AND
# for dyld to actually load Chrome's bundled dylibs under Hardened Runtime +
# Library Validation, every Mach-O inside must be signed by our team.
if [ "$SIGNING_DISABLED" = "1" ]; then
    echo "embed-chromium.sh: no signing identity available — leaving Chromium ad-hoc signed."
elif [ ! -s "$RESIGN_LIST_FILE" ]; then
    echo "embed-chromium.sh: every embedded Chromium bundle was up to date — no re-sign needed."
else
    while IFS= read -r chromium; do
        [ -z "$chromium" ] && continue
        echo "embed-chromium.sh: re-signing nested Chromium bundle at $chromium (identity '$RESIGN_IDENTITY') ..."

        # 1a) Sign every standalone dylib bottom-up.
        /usr/bin/find "$chromium" -type f -name '*.dylib' -print0 \
            | while IFS= read -r -d '' dylib; do
                /usr/bin/codesign --force --sign "$RESIGN_IDENTITY" \
                    --options runtime \
                    --preserve-metadata=identifier,requirements \
                    "$dylib"
            done

        # 1b) Sign every STANDALONE Mach-O executable inside the Chromium
        #     bundle (chrome_crashpad_handler, etc.) — i.e. plain executable
        #     files that aren't part of an embedded .app/.framework bundle's
        #     principal executable. Notarization scans every nested Mach-O;
        #     an ad-hoc one fails the outer notarize.
        standalone_list="$(/usr/bin/mktemp -t chromium-standalone-XXXXXX)"
        candidate_list="$(/usr/bin/mktemp -t chromium-cands-XXXXXX)"
        /usr/bin/find "$chromium" -type f -perm -u+x ! -name '*.dylib' > "$candidate_list" 2>/dev/null || true

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

        # 2) Sign every helper .app with the Chromium entitlements set. We
        #    can't `--preserve-metadata=entitlements` because the snapshot
        #    helpers are ad-hoc / linker-signed and therefore have an EMPTY
        #    entitlements blob — preserving that strips Chromium's required
        #    JIT / unsigned-executable-memory / disable-library-validation
        #    grants, breaking V8 and renderer process startup under Hardened
        #    Runtime. The plists in scripts/cft-entitlements/ mirror
        #    Chromium's canonical chrome/app/*-entitlements.plist files
        #    (these are upstream Chromium plists; the directory was named
        #    `cft-entitlements/` historically when we shipped CFT but the
        #    entitlements themselves are identical for upstream Chromium).
        helper_list="$(/usr/bin/mktemp -t chromium-helpers-XXXXXX)"
        /usr/bin/find "$chromium/Contents/Frameworks" -type d -name '*.app' 2>/dev/null > "$helper_list" || true
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
                    # Catch-all for Helper.app, Helper (Alerts).app, and any
                    # other utility helpers Chromium adds in future. The base
                    # helper.plist allows nested-library loading but does NOT
                    # grant JIT.
                    entitlements_plist="$ENTITLEMENTS_DIR/helper.plist"
                    ;;
            esac

            if [ ! -f "$entitlements_plist" ]; then
                echo "embed-chromium.sh: ERROR — missing helper entitlements plist '$entitlements_plist'." >&2
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
        fw_list="$(/usr/bin/mktemp -t chromium-frameworks-XXXXXX)"
        /usr/bin/find "$chromium/Contents/Frameworks" -type d -name '*.framework' 2>/dev/null > "$fw_list" || true
        while IFS= read -r fw; do
            [ -z "$fw" ] && continue
            /usr/bin/codesign --force --sign "$RESIGN_IDENTITY" \
                --options runtime \
                --preserve-metadata=identifier,requirements \
                "$fw"
        done < "$fw_list"
        rm -f "$fw_list"

        # 4) Sign the outer Chromium.app itself. As with the helpers, the
        #    downloaded bundle has empty entitlements; preserve-metadata
        #    would strip the disable-library-validation grant the browser
        #    process needs to load its bundled framework. Apply the
        #    canonical app.plist entitlements (mirrors Chromium's
        #    chrome/app/app-entitlements.plist).
        if [ ! -f "$ENTITLEMENTS_DIR/app.plist" ]; then
            echo "embed-chromium.sh: ERROR — missing app entitlements plist '$ENTITLEMENTS_DIR/app.plist'." >&2
            exit 1
        fi
        /usr/bin/codesign --force --sign "$RESIGN_IDENTITY" \
            --options runtime \
            --entitlements "$ENTITLEMENTS_DIR/app.plist" \
            "$chromium"
    done < "$RESIGN_LIST_FILE"
fi

# Re-sign the OUTER app over any Chromium-tree mutation. The script runs as a
# postBuildScripts phase (after Xcode's built-in code-sign step), so adding,
# replacing, or deleting browser resources after that point makes the outer
# signature stale. Without this re-sign, Gatekeeper / notarytool reject the
# outer bundle ("a sealed resource is missing or invalid").
if [ "$SIGNING_DISABLED" != "1" ] \
    && { [ "$outer_resign_needed" = "1" ] || [ -s "$RESIGN_LIST_FILE" ]; }; then
    ENTITLEMENTS_PATH=""
    if [ -n "${CODE_SIGN_ENTITLEMENTS:-}" ]; then
        if [ -f "$PROJECT_DIR/$CODE_SIGN_ENTITLEMENTS" ]; then
            ENTITLEMENTS_PATH="$PROJECT_DIR/$CODE_SIGN_ENTITLEMENTS"
        elif [ -f "$CODE_SIGN_ENTITLEMENTS" ]; then
            ENTITLEMENTS_PATH="$CODE_SIGN_ENTITLEMENTS"
        fi
    fi

    echo "embed-chromium.sh: re-signing outer app with '$RESIGN_IDENTITY' (over embedded Chromium) ..."
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
while IFS= read -r chromium; do
    [ -z "$chromium" ] && continue
    embedded_exe="$chromium/Contents/MacOS/Chromium"
    if [ ! -x "$embedded_exe" ]; then
        echo "embed-chromium.sh: ERROR — embedded bundle has no launchable executable at '$embedded_exe'." >&2
        rm -f "$EMBED_LIST_FILE" "$RESIGN_LIST_FILE"
        exit 1
    fi
done < "$EMBED_LIST_FILE"

rm -f "$EMBED_LIST_FILE" "$RESIGN_LIST_FILE"

echo "embed-chromium.sh: done. Embedded Chromium in $DEST_BROWSERS_DIR."
