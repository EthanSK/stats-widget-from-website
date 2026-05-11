#!/usr/bin/env bash
#
# fetch-chrome-for-testing.sh
#
# Downloads Google Chrome for Testing (CFT) into vendor/chrome-for-testing/
# so the Xcode build can BUNDLE it inside the .app — no runtime download.
#
# Why we bundle CFT instead of lazy-downloading at first launch:
#   - Sandboxed Release builds couldn't reliably exec /usr/bin/ditto from
#     within the app's sandbox container, and even when extraction succeeded
#     the executable bit / quarantine xattrs caused the downloaded bundle
#     to fail `FileManager.isExecutableFile` (which is what produced the
#     "browser bundle did not contain a launchable executable" error on
#     0.12.15). Bundling CFT at build time avoids the entire failure surface.
#
# Layout (relative to repo root):
#   vendor/chrome-for-testing/
#     VERSION                         # plain text: the CFT version we pinned
#     mac-arm64/Google Chrome for Testing.app
#     mac-x64/Google Chrome for Testing.app
#
# Idempotency:
#   - If vendor/chrome-for-testing/VERSION matches the desired version AND
#     every requested per-arch .app bundle exists with a launchable
#     executable inside, this script is a no-op (exit 0).
#   - Use --force to wipe and re-download.
#
# Arch selection:
#   - By default, both arm64 and x64 are downloaded so a single repo can
#     produce builds for Apple Silicon AND Intel Macs. The Xcode build phase
#     picks ONE arch (matching the build target) to copy into the app's
#     Resources, so the shipped .app is still single-arch-sized at runtime.
#   - --only-host downloads ONLY the build host's arch (useful for local
#     dev builds where the developer is only testing on their own machine).
#
# Pinning:
#   - By default the script reads the latest Stable from
#     googlechromelabs.github.io/chrome-for-testing. Override via
#     CFT_VERSION=148.0.7778.97 in the environment to pin to a specific
#     version (recommended for CI to avoid surprise CFT bumps between PRs).
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
VENDOR_ROOT="$REPO_ROOT/vendor/chrome-for-testing"
MANIFEST_URL="https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"

FORCE=0
ONLY_HOST=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --only-host) ONLY_HOST=1 ;;
        -h|--help)
            sed -n '2,44p' "$0"
            exit 0
            ;;
        *)
            echo "fetch-chrome-for-testing.sh: unknown flag '$arg'" >&2
            exit 1
            ;;
    esac
done

if [ "$ONLY_HOST" = "1" ]; then
    HOST_ARCH="$(uname -m)"
    case "$HOST_ARCH" in
        arm64) ARCHES="mac-arm64" ;;
        x86_64) ARCHES="mac-x64" ;;
        *) echo "fetch-chrome-for-testing.sh: unsupported host arch '$HOST_ARCH'" >&2; exit 1 ;;
    esac
else
    ARCHES="mac-arm64 mac-x64"
fi

# Resolve target version + per-arch URLs.
if [ -n "${CFT_VERSION:-}" ]; then
    TARGET_VERSION="$CFT_VERSION"
    URL_MAC_ARM64="https://storage.googleapis.com/chrome-for-testing-public/${TARGET_VERSION}/mac-arm64/chrome-mac-arm64.zip"
    URL_MAC_X64="https://storage.googleapis.com/chrome-for-testing-public/${TARGET_VERSION}/mac-x64/chrome-mac-x64.zip"
else
    echo "fetch-chrome-for-testing.sh: resolving latest Stable CFT version..."
    manifest_tmp="$(/usr/bin/mktemp -t cft-manifest-XXXXXX)"
    if ! /usr/bin/curl -fsSL "$MANIFEST_URL" -o "$manifest_tmp"; then
        rm -f "$manifest_tmp"
        echo "fetch-chrome-for-testing.sh: ERROR — failed to fetch CFT manifest from $MANIFEST_URL" >&2
        exit 1
    fi
    # Parse once via python and emit shell-assignable lines.
    PARSED="$(MANIFEST_PATH="$manifest_tmp" /usr/bin/python3 - <<'PYEOF'
import json, os
with open(os.environ["MANIFEST_PATH"], "r", encoding="utf-8") as fh:
    data = json.load(fh)
stable = data["channels"]["Stable"]
print("VERSION=" + stable["version"])
for entry in stable["downloads"]["chrome"]:
    p = entry["platform"]
    if p == "mac-arm64":
        print("URL_MAC_ARM64=" + entry["url"])
    elif p == "mac-x64":
        print("URL_MAC_X64=" + entry["url"])
PYEOF
)"
    rm -f "$manifest_tmp"
    TARGET_VERSION="$(printf '%s\n' "$PARSED" | /usr/bin/grep '^VERSION=' | /usr/bin/cut -d= -f2-)"
    URL_MAC_ARM64="$(printf '%s\n' "$PARSED" | /usr/bin/grep '^URL_MAC_ARM64=' | /usr/bin/cut -d= -f2-)"
    URL_MAC_X64="$(printf '%s\n' "$PARSED" | /usr/bin/grep '^URL_MAC_X64=' | /usr/bin/cut -d= -f2-)"
fi

if [ -z "$TARGET_VERSION" ]; then
    echo "fetch-chrome-for-testing.sh: ERROR — could not resolve CFT version" >&2
    exit 1
fi

echo "fetch-chrome-for-testing.sh: target version $TARGET_VERSION"
echo "fetch-chrome-for-testing.sh: vendor root $VENDOR_ROOT"
echo "fetch-chrome-for-testing.sh: arches: $ARCHES"

# Helper: map an arch token to its download URL.
url_for_arch() {
    case "$1" in
        mac-arm64) printf '%s\n' "$URL_MAC_ARM64" ;;
        mac-x64) printf '%s\n' "$URL_MAC_X64" ;;
        *) echo "" ;;
    esac
}

# Idempotency check.
needs_fetch=0
if [ "$FORCE" = "1" ]; then
    needs_fetch=1
elif [ -f "$VENDOR_ROOT/VERSION" ] && [ "$(cat "$VENDOR_ROOT/VERSION")" = "$TARGET_VERSION" ]; then
    for arch in $ARCHES; do
        exe="$VENDOR_ROOT/$arch/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        if [ ! -x "$exe" ]; then
            needs_fetch=1
            break
        fi
    done
else
    needs_fetch=1
fi

if [ "$needs_fetch" = "0" ]; then
    echo "fetch-chrome-for-testing.sh: vendored CFT $TARGET_VERSION is already present and launchable — no-op."
    exit 0
fi

mkdir -p "$VENDOR_ROOT"

for arch in $ARCHES; do
    url="$(url_for_arch "$arch")"
    if [ -z "$url" ]; then
        echo "fetch-chrome-for-testing.sh: ERROR — no download URL for arch $arch" >&2
        exit 1
    fi

    arch_root="$VENDOR_ROOT/$arch"
    app_dir="$arch_root/Google Chrome for Testing.app"
    exe_path="$app_dir/Contents/MacOS/Google Chrome for Testing"

    if [ "$FORCE" != "1" ] && [ -x "$exe_path" ] \
        && [ -f "$VENDOR_ROOT/VERSION" ] \
        && [ "$(cat "$VENDOR_ROOT/VERSION")" = "$TARGET_VERSION" ]; then
        echo "fetch-chrome-for-testing.sh: $arch already at $TARGET_VERSION — skipping."
        continue
    fi

    echo "fetch-chrome-for-testing.sh: downloading $arch from $url ..."
    tmp_dir="$(/usr/bin/mktemp -d -t cft-fetch-XXXXXX)"

    zip_path="$tmp_dir/chrome.zip"
    extract_dir="$tmp_dir/extract"
    mkdir -p "$extract_dir"

    if ! /usr/bin/curl -fL --retry 3 --retry-delay 2 -o "$zip_path" "$url"; then
        echo "fetch-chrome-for-testing.sh: ERROR — curl failed for $arch" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    echo "fetch-chrome-for-testing.sh: extracting $arch ..."
    if ! /usr/bin/ditto -x -k "$zip_path" "$extract_dir"; then
        echo "fetch-chrome-for-testing.sh: ERROR — ditto extract failed for $arch" >&2
        rm -rf "$tmp_dir"
        exit 2
    fi

    # The CFT zip extracts into chrome-mac-<arch>/Google Chrome for Testing.app .
    found_app="$(/usr/bin/find "$extract_dir" -maxdepth 4 -type d -name 'Google Chrome for Testing.app' -print 2>/dev/null | /usr/bin/head -n1 || true)"
    if [ -z "$found_app" ]; then
        echo "fetch-chrome-for-testing.sh: ERROR — extracted archive did not contain Google Chrome for Testing.app ($arch)" >&2
        rm -rf "$tmp_dir"
        exit 2
    fi

    rm -rf "$arch_root"
    mkdir -p "$arch_root"
    /usr/bin/ditto "$found_app" "$app_dir"

    # Strip quarantine xattr; nested-bundle re-sign would otherwise re-evaluate
    # the Google-signed bundle through Gatekeeper on every launch.
    /usr/bin/xattr -dr com.apple.quarantine "$app_dir" 2>/dev/null || true

    if [ ! -x "$exe_path" ]; then
        echo "fetch-chrome-for-testing.sh: ERROR — extracted bundle has no launchable executable at $exe_path" >&2
        rm -rf "$tmp_dir"
        exit 2
    fi

    rm -rf "$tmp_dir"
    echo "fetch-chrome-for-testing.sh: $arch ready at $app_dir"
done

printf '%s\n' "$TARGET_VERSION" > "$VENDOR_ROOT/VERSION"

echo "fetch-chrome-for-testing.sh: done. CFT $TARGET_VERSION vendored under $VENDOR_ROOT."
