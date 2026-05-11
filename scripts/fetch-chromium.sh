#!/usr/bin/env bash
#
# fetch-chromium.sh
#
# Downloads upstream Chromium snapshots from Google's chromium-browser-snapshots
# bucket into vendor/chromium/ so the Xcode build can BUNDLE Chromium inside
# the .app — no runtime download.
#
# Why we bundle upstream Chromium inside the .app:
#   - The 0.13.x lazy-download path (download → extract to <App-Sandbox-
#     Container>/Data/Library/Application Support → strip quarantine → exec)
#     is fundamentally broken in App Sandbox. Even with the binary at 0755 +
#     a valid Mach-O header, macOS auto-re-attaches `com.apple.quarantine`
#     when the sandboxed app touches the file, and the sandbox itself denies
#     execve from container-relative paths regardless of POSIX perms. The
#     only path that reliably works under sandbox is bundling Chromium inside
#     the .app — sandboxed apps CAN exec binaries from their own bundle.
#   - This is what v0.13.0 did for Chrome for Testing (CFT). It worked.
#     But CFT injects a `navigator.webdriver` flag + a HeadlessChrome-derived
#     User-Agent that Google's risk engine blocks at sign-in, defeating
#     Google-OAuth dashboards. Upstream Chromium does NOT inject those
#     automation markers and CAN sign into Google — so we bundle upstream
#     Chromium instead of CFT.
#
# Layout (relative to repo root):
#   vendor/chromium/
#     VERSION                   # plain text, one per-arch revision per line:
#                               #   mac-arm64=<revision>
#                               #   mac-x64=<revision>
#     mac-arm64/Chromium.app
#     mac-x64/Chromium.app
#
# Source: https://commondatastorage.googleapis.com/chromium-browser-snapshots/
#   - <platform>/LAST_CHANGE          — latest revision number for the platform
#   - <platform>/<revision>/chrome-mac.zip
#                                     — the zipped Chromium.app (~150 MB)
#
# Idempotency:
#   - If vendor/chromium/VERSION matches the desired version AND every
#     requested per-arch Chromium.app exists with a launchable inner
#     executable, this script is a no-op.
#   - Use --force to wipe and re-download.
#
# Arch selection:
#   - By default, both arm64 and x64 are downloaded so a single repo can
#     produce builds for Apple Silicon AND Intel Macs. The Xcode embed
#     phase picks ONE arch (matching the build target) to copy into the
#     app's Resources, so the shipped .app is still single-arch-sized at
#     runtime.
#   - --only-host downloads ONLY the build host's arch (useful for local
#     dev builds where the developer is only testing on their own machine).
#   - --arch mac-arm64 / --arch mac-x64 downloads only the requested vendor
#     arch. May be passed more than once.
#
# Pinning:
#   - By default the script reads the LAST_CHANGE marker for each platform
#     and uses whatever revision the upstream snapshot bucket currently
#     publishes. Override via CHROMIUM_REVISION=1628585 in the environment
#     to pin to a specific revision (recommended for CI to avoid surprise
#     revision bumps between PRs).
#
# Exit codes:
#   0   success (or no-op)
#   1   network / parse failure
#   2   extraction / staging failure
#
# Compatibility: this script is written for /usr/bin/env bash 3.2 (macOS
# default) — no associative arrays, no [[ =~ ]] regex captures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_ROOT="$REPO_ROOT/vendor/chromium"
BUCKET_BASE="https://commondatastorage.googleapis.com/chromium-browser-snapshots"

FORCE=0
ONLY_HOST=0
ARCHES=""

append_arch() {
    local arch="$1"
    case "$arch" in
        mac-arm64|mac-x64) ;;
        *)
            echo "fetch-chromium.sh: unsupported arch '$arch' (expected mac-arm64 or mac-x64)" >&2
            exit 1
            ;;
    esac

    local existing
    for existing in $ARCHES; do
        if [ "$existing" = "$arch" ]; then
            return 0
        fi
    done
    ARCHES="${ARCHES:+$ARCHES }$arch"
}

while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
        --force) FORCE=1 ;;
        --only-host) ONLY_HOST=1 ;;
        --arch)
            shift
            if [ "$#" -eq 0 ]; then
                echo "fetch-chromium.sh: --arch requires mac-arm64 or mac-x64" >&2
                exit 1
            fi
            append_arch "$1"
            ;;
        --arch=*)
            append_arch "${arg#--arch=}"
            ;;
        -h|--help)
            sed -n '2,64p' "$0"
            exit 0
            ;;
        *)
            echo "fetch-chromium.sh: unknown flag '$arg'" >&2
            exit 1
            ;;
    esac
    shift
done

if [ "$ONLY_HOST" = "1" ]; then
    if [ -n "$ARCHES" ]; then
        echo "fetch-chromium.sh: --only-host cannot be combined with --arch" >&2
        exit 1
    fi
    HOST_ARCH="$(uname -m)"
    case "$HOST_ARCH" in
        arm64) ARCHES="mac-arm64" ;;
        x86_64) ARCHES="mac-x64" ;;
        *) echo "fetch-chromium.sh: unsupported host arch '$HOST_ARCH'" >&2; exit 1 ;;
    esac
elif [ -z "$ARCHES" ]; then
    ARCHES="mac-arm64 mac-x64"
fi

# Map vendor arch token → bucket platform name.
bucket_platform_for_arch() {
    case "$1" in
        mac-arm64) printf '%s\n' "Mac_Arm" ;;
        mac-x64) printf '%s\n' "Mac" ;;
        *) printf '\n' ;;
    esac
}

# Resolve revision (per-arch since LAST_CHANGE is platform-specific).
resolve_revision_for_platform() {
    local platform="$1"
    if [ -n "${CHROMIUM_REVISION:-}" ]; then
        printf '%s\n' "$CHROMIUM_REVISION"
        return 0
    fi
    local last_change_url="$BUCKET_BASE/$platform/LAST_CHANGE"
    local revision
    revision="$(/usr/bin/curl -fsSL --retry 3 --retry-delay 2 "$last_change_url" 2>/dev/null || true)"
    if [ -z "$revision" ]; then
        echo "fetch-chromium.sh: ERROR — could not fetch LAST_CHANGE from $last_change_url" >&2
        return 1
    fi
    printf '%s\n' "$revision"
}

# Read CFBundleShortVersionString from a Chromium.app bundle, if present.
chromium_app_version() {
    local app_dir="$1"
    local info_plist="$app_dir/Contents/Info.plist"
    if [ ! -f "$info_plist" ]; then
        printf '\n'
        return 0
    fi
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true
}

is_unsigned_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

echo "fetch-chromium.sh: vendor root $VENDOR_ROOT"
echo "fetch-chromium.sh: arches: $ARCHES"

mkdir -p "$VENDOR_ROOT"

# Resolve per-arch revisions up front so the final VERSION marker can record
# them all (used for staleness detection during incremental builds).
declare_revision() {
    eval "REVISION_${1}=\"\$2\""
}
get_revision() {
    eval "printf '%s\n' \"\${REVISION_${1}:-}\""
}

for arch in $ARCHES; do
    platform="$(bucket_platform_for_arch "$arch")"
    if [ -z "$platform" ]; then
        echo "fetch-chromium.sh: ERROR — unsupported vendor arch '$arch'" >&2
        exit 1
    fi
    revision="$(resolve_revision_for_platform "$platform")" || exit 1
    revision="$(printf '%s\n' "$revision" | /usr/bin/tr -d '[:space:]')"
    if ! is_unsigned_int "$revision"; then
        echo "fetch-chromium.sh: ERROR — invalid Chromium revision '$revision' for $arch ($platform)" >&2
        exit 1
    fi
    # Replace dashes in arch so the env var name is valid.
    arch_id="$(printf '%s\n' "$arch" | /usr/bin/tr '-' '_')"
    declare_revision "$arch_id" "$revision"
    echo "fetch-chromium.sh: $arch ($platform) → revision $revision"
done

# Idempotency check. We treat the on-disk VERSION marker as the source of
# truth, and require every requested arch's executable to be present AND
# every requested arch's marker line to match the just-resolved revision.
needs_fetch=0
if [ "$FORCE" = "1" ]; then
    needs_fetch=1
elif [ ! -f "$VENDOR_ROOT/VERSION" ]; then
    needs_fetch=1
else
    # Require the requested arches to match what's on disk (line-by-line).
    for arch in $ARCHES; do
        arch_id="$(printf '%s\n' "$arch" | /usr/bin/tr '-' '_')"
        rev="$(get_revision "$arch_id")"
        if ! /usr/bin/grep -Fqx "$arch=$rev" "$VENDOR_ROOT/VERSION"; then
            needs_fetch=1
            break
        fi
        exe="$VENDOR_ROOT/$arch/Chromium.app/Contents/MacOS/Chromium"
        if [ ! -x "$exe" ]; then
            needs_fetch=1
            break
        fi
    done
fi

if [ "$needs_fetch" = "0" ]; then
    echo "fetch-chromium.sh: vendored Chromium is already present and launchable — no-op."
    exit 0
fi

# Fetch + extract every requested arch. Per-arch tmp dir so a failure
# halfway through doesn't leave the vendor root half-baked.
for arch in $ARCHES; do
    arch_id="$(printf '%s\n' "$arch" | /usr/bin/tr '-' '_')"
    revision="$(get_revision "$arch_id")"
    platform="$(bucket_platform_for_arch "$arch")"

    arch_root="$VENDOR_ROOT/$arch"
    app_dir="$arch_root/Chromium.app"
    exe_path="$app_dir/Contents/MacOS/Chromium"

    # Skip per-arch only if no force, the marker line already names the
    # requested revision (i.e. another arch wanted a re-fetch but this one
    # is current), and the executable is present.
    if [ "$FORCE" != "1" ] && [ -x "$exe_path" ] \
        && [ -f "$VENDOR_ROOT/VERSION" ] \
        && /usr/bin/grep -Fqx "$arch=$revision" "$VENDOR_ROOT/VERSION"; then
        echo "fetch-chromium.sh: $arch already at revision $revision — skipping."
        continue
    fi

    url="$BUCKET_BASE/$platform/$revision/chrome-mac.zip"

    echo "fetch-chromium.sh: downloading $arch from $url ..."
    tmp_dir="$(/usr/bin/mktemp -d -t chromium-fetch-XXXXXX)"
    zip_path="$tmp_dir/chromium.zip"
    extract_dir="$tmp_dir/extract"
    mkdir -p "$extract_dir"

    if ! /usr/bin/curl -fL --retry 3 --retry-delay 2 -o "$zip_path" "$url"; then
        echo "fetch-chromium.sh: ERROR — curl failed for $arch ($url)" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    echo "fetch-chromium.sh: extracting $arch ..."
    if ! /usr/bin/ditto -x -k "$zip_path" "$extract_dir"; then
        echo "fetch-chromium.sh: ERROR — ditto extract failed for $arch" >&2
        rm -rf "$tmp_dir"
        exit 2
    fi

    # The Chromium snapshot zip extracts into chrome-mac/Chromium.app/ .
    # macOS /usr/bin/find is BSD find and has no -maxdepth, so keep this
    # as a plain traversal of the small extracted archive tree.
    found_app="$(/usr/bin/find "$extract_dir" -type d -name 'Chromium.app' -print 2>/dev/null | /usr/bin/head -n 1 || true)"
    if [ -z "$found_app" ]; then
        echo "fetch-chromium.sh: ERROR — extracted archive did not contain Chromium.app ($arch)" >&2
        rm -rf "$tmp_dir"
        exit 2
    fi

    replacement_root="$(/usr/bin/mktemp -d "$VENDOR_ROOT/.${arch}.replacement.XXXXXX")"
    replacement_app="$replacement_root/Chromium.app"
    replacement_exe="$replacement_app/Contents/MacOS/Chromium"
    if ! /usr/bin/ditto "$found_app" "$replacement_app"; then
        echo "fetch-chromium.sh: ERROR — failed to stage extracted Chromium.app for $arch" >&2
        rm -rf "$replacement_root" "$tmp_dir"
        exit 2
    fi

    # Strip quarantine xattr; the embed phase later re-signs the bundle
    # with the outer team identity and the lingering quarantine bit can
    # mask exec failures during build-host smoke tests.
    /usr/bin/xattr -dr com.apple.quarantine "$replacement_app" 2>/dev/null || true

    if [ ! -x "$replacement_exe" ]; then
        echo "fetch-chromium.sh: ERROR — extracted bundle has no launchable executable at $replacement_exe" >&2
        rm -rf "$replacement_root" "$tmp_dir"
        exit 2
    fi

    backup_root=""
    if [ -e "$arch_root" ] || [ -L "$arch_root" ]; then
        backup_root="$(/usr/bin/mktemp -d "$VENDOR_ROOT/.${arch}.previous.XXXXXX")"
        rm -rf "$backup_root"
        if ! mv "$arch_root" "$backup_root"; then
            echo "fetch-chromium.sh: ERROR — could not move existing $arch bundle aside" >&2
            rm -rf "$replacement_root" "$tmp_dir"
            exit 2
        fi
    fi

    if ! mv "$replacement_root" "$arch_root"; then
        echo "fetch-chromium.sh: ERROR — could not move staged $arch bundle into place" >&2
        if [ -n "$backup_root" ] && [ -e "$backup_root" ] && [ ! -e "$arch_root" ]; then
            mv "$backup_root" "$arch_root" 2>/dev/null || true
        fi
        rm -rf "$replacement_root" "$tmp_dir"
        exit 2
    fi
    if [ -n "$backup_root" ]; then
        rm -rf "$backup_root"
    fi

    bundle_version="$(chromium_app_version "$app_dir")"
    if [ -n "$bundle_version" ]; then
        echo "fetch-chromium.sh: $arch ready at $app_dir (Chromium $bundle_version, revision $revision)"
    else
        echo "fetch-chromium.sh: $arch ready at $app_dir (revision $revision)"
    fi
    rm -rf "$tmp_dir"
done

# Write the per-arch revision marker. Format:
#   mac-arm64=1628585
#   mac-x64=1628600
# This lets multi-arch builds detect partial refreshes (e.g. someone re-ran
# --only-host for a different host arch).
marker_tmp="$VENDOR_ROOT/VERSION.tmp"
: > "$marker_tmp"
for arch in $ARCHES; do
    arch_id="$(printf '%s\n' "$arch" | /usr/bin/tr '-' '_')"
    rev="$(get_revision "$arch_id")"
    printf '%s=%s\n' "$arch" "$rev" >> "$marker_tmp"
done
# Preserve any non-requested arch lines from the previous marker (e.g. an
# --only-host rerun shouldn't wipe the other arch's recorded revision if
# the other arch's tree is still present).
if [ -f "$VENDOR_ROOT/VERSION" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        arch_key="${line%%=*}"
        already_present=0
        for arch in $ARCHES; do
            if [ "$arch" = "$arch_key" ]; then
                already_present=1
                break
            fi
        done
        if [ "$already_present" = "0" ]; then
            other_app="$VENDOR_ROOT/$arch_key/Chromium.app/Contents/MacOS/Chromium"
            if [ -x "$other_app" ]; then
                printf '%s\n' "$line" >> "$marker_tmp"
            fi
        fi
    done < "$VENDOR_ROOT/VERSION"
fi
mv "$marker_tmp" "$VENDOR_ROOT/VERSION"

echo "fetch-chromium.sh: done. Chromium vendored under $VENDOR_ROOT."
echo "fetch-chromium.sh: VERSION marker:"
/usr/bin/sed 's/^/    /' "$VENDOR_ROOT/VERSION"
