#!/usr/bin/env bash
# bump-and-tag.sh — one-shot release initiator for the Sparkle pipeline.
#
# Bumps MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml, regenerates
# the Xcode project via xcodegen so the Info.plists pick up the new version
# variables, commits the result, tags the commit `vX.Y.Z`, and pushes both the
# branch and the tag to origin. Pushing the tag triggers `.github/workflows/
# release.yml` (which is gated on `push: tags: v*`), which in turn builds,
# notarizes, Sparkle-signs, publishes the GitHub Release, and updates the
# gh-pages appcast — i.e. the full release path with zero Xcode/SCP work
# locally. Replaces the legacy "open Xcode, archive, manually upload"
# workflow per Ethan voice 3991 (2026-05-24).
#
# Usage:
#   ./scripts/bump-and-tag.sh --patch              # 0.21.14 -> 0.21.15
#   ./scripts/bump-and-tag.sh --minor              # 0.21.14 -> 0.22.0
#   ./scripts/bump-and-tag.sh --major              # 0.21.14 -> 1.0.0
#   ./scripts/bump-and-tag.sh --patch --dry-run    # print plan, no writes/push
#
# Notes:
#   - This script intentionally does NOT call bump-version.sh — that script
#     supports `set`/`patch`/`minor`/`major` but doesn't commit, tag, or push.
#     We re-implement the version math inline so the whole release flow lives
#     in one auditable script, and we keep the shape compatible with what
#     prepare_release_metadata.py expects (canonical tag = `v<MARKETING_VERSION>`).
#   - We do NOT touch release.yml or the metadata Python scripts; they already
#     understand `v*` tag pushes (see release.yml line 10 + prepare_release_metadata.py
#     RELEASE_TAG logic).

set -euo pipefail

# -------- Argument parsing ---------------------------------------------------
# Single required flag (--patch/--minor/--major) plus optional --dry-run.
# We use a tiny hand-rolled parser instead of getopt(s) because BSD getopt on
# macOS doesn't support long options and we don't want a brew dep.
bump_mode=""        # one of: patch | minor | major
dry_run=0           # 1 = print everything, perform NO writes / commits / push

# Sub-helper: emit usage + exit. Used by the parser on bad/missing flags.
usage() {
    cat >&2 <<'USAGE'
Usage: ./scripts/bump-and-tag.sh (--patch | --minor | --major) [--dry-run]

  --patch     Bump Z in X.Y.Z (e.g. 0.21.14 -> 0.21.15)
  --minor     Bump Y, reset Z   (e.g. 0.21.14 -> 0.22.0)
  --major     Bump X, reset Y+Z (e.g. 0.21.14 -> 1.0.0)
  --dry-run   Print intended changes + git ops, do NOT modify project.yml,
              regenerate the .xcodeproj, commit, tag, or push.
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --patch|--minor|--major)
            # Reject double-specifying a bump mode (e.g. `--patch --minor`)
            # so the caller doesn't silently get the last one.
            if [[ -n "$bump_mode" ]]; then
                echo "bump-and-tag.sh: ERROR — multiple bump flags supplied; pick one." >&2
                usage
            fi
            bump_mode="${1#--}"   # strip leading -- to get patch/minor/major
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "bump-and-tag.sh: ERROR — unknown argument '$1'" >&2
            usage
            ;;
    esac
done

# Bump mode is required — there's no "default to patch" because real releases
# should be intentional about semver bump type.
if [[ -z "$bump_mode" ]]; then
    echo "bump-and-tag.sh: ERROR — one of --patch/--minor/--major is required." >&2
    usage
fi

# -------- Resolve repo layout -----------------------------------------------
# REPO_ROOT is the parent of this script's directory; computed via BASH_SOURCE
# so the script works whether you run it from the repo root or anywhere else.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$REPO_ROOT/project.yml"

# Info.plist files xcodegen will regenerate. Listed explicitly (not globbed)
# because we want to fail loud if any are missing — a missing plist would
# silently skip version verification later.
INFO_PLISTS=(
    "$REPO_ROOT/MacosWidgetsStatsFromWebsite/Apps/MainApp/Info.plist"
    "$REPO_ROOT/MacosWidgetsStatsFromWebsite/Apps/WidgetExtension/Info.plist"
    "$REPO_ROOT/MacosWidgetsStatsFromWebsite/Apps/CLI/Info.plist"
)

if [[ ! -f "$PROJECT_YML" ]]; then
    echo "bump-and-tag.sh: ERROR — project.yml not found at $PROJECT_YML" >&2
    exit 1
fi

# Sanity-check we're in a git repo + on a checked-out branch. Bare detached
# HEAD would let us tag but not push the commit to a branch, which would
# silently break the release.yml `push: branches: main` half of the trigger.
if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "bump-and-tag.sh: ERROR — $REPO_ROOT is not a git working tree." >&2
    exit 1
fi

CURRENT_BRANCH="$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD || true)"
if [[ -z "$CURRENT_BRANCH" ]]; then
    echo "bump-and-tag.sh: ERROR — HEAD is detached; check out a branch first." >&2
    exit 1
fi

# -------- Dirty-tree guard --------------------------------------------------
# Refuse to bump if there are uncommitted changes OR untracked files. Both
# would otherwise contaminate the bump commit's `git add` step, or leave the
# user with unexpected staged content alongside the version bump. We use
# `git status --porcelain` because it captures unstaged + staged + untracked
# in a single check (whereas `git diff --quiet` only sees tracked-file diffs).
dirty_status="$(git -C "$REPO_ROOT" status --porcelain)"
if [[ -n "$dirty_status" ]]; then
    echo "bump-and-tag.sh: ERROR — working tree is dirty. Commit, stash, or remove untracked files first:" >&2
    echo "$dirty_status" >&2
    exit 1
fi

# -------- Read current versions ---------------------------------------------
# MARKETING_VERSION (X.Y.Z) and CURRENT_PROJECT_VERSION (monotonic build int)
# both live in project.yml under the `settings:` block. Use the same parsing
# pattern as the existing bump-version.sh so behaviour is consistent if anyone
# diffs the two scripts.
current_version="$(grep -E '^[[:space:]]*MARKETING_VERSION:[[:space:]]*"[^"]+"' "$PROJECT_YML" \
    | head -n1 \
    | sed -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*$/\1/')"
current_build="$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"[^"]+"' "$PROJECT_YML" \
    | head -n1 \
    | sed -E 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"([^"]+)".*$/\1/')"

if [[ -z "$current_version" || -z "$current_build" ]]; then
    echo "bump-and-tag.sh: ERROR — could not parse MARKETING_VERSION/CURRENT_PROJECT_VERSION in project.yml" >&2
    exit 1
fi

# Strict semver shape (X.Y.Z, integers only). prepare_release_metadata.py
# computes canonical_tag = f"v{version}", so anything outside X.Y.Z would
# break the workflow's tag-matching logic.
if ! [[ "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "bump-and-tag.sh: ERROR — current MARKETING_VERSION '$current_version' is not X.Y.Z." >&2
    exit 1
fi
if ! [[ "$current_build" =~ ^[0-9]+$ ]]; then
    echo "bump-and-tag.sh: ERROR — current CURRENT_PROJECT_VERSION '$current_build' is not a positive integer." >&2
    exit 1
fi

IFS='.' read -r cur_major cur_minor cur_patch <<<"$current_version"

# -------- Compute new versions ----------------------------------------------
case "$bump_mode" in
    patch)
        new_version="${cur_major}.${cur_minor}.$((cur_patch + 1))"
        ;;
    minor)
        new_version="${cur_major}.$((cur_minor + 1)).0"
        ;;
    major)
        new_version="$((cur_major + 1)).0.0"
        ;;
esac

# Build number is monotonic across all bumps — never reset, regardless of
# whether it's a patch/minor/major. Sparkle's appcast ordering uses
# CFBundleVersion (the build number), so any reset would break update detection.
new_build=$((current_build + 1))
new_tag="v${new_version}"

# -------- Tag-collision guard -----------------------------------------------
# If we somehow ended up at a version that already has a tag (manual edits,
# botched previous run, etc.), bail before mutating anything. Check both
# local refs and origin (so we don't push a tag that already exists upstream).
if git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/tags/${new_tag}" >/dev/null; then
    echo "bump-and-tag.sh: ERROR — local tag ${new_tag} already exists." >&2
    exit 1
fi
# `git ls-remote` is the cheapest way to detect a remote tag without a full
# fetch. Empty stdout = not present; any output = present.
if git -C "$REPO_ROOT" ls-remote --exit-code --tags origin "${new_tag}" >/dev/null 2>&1; then
    echo "bump-and-tag.sh: ERROR — remote tag ${new_tag} already exists on origin." >&2
    exit 1
fi

# -------- Report plan -------------------------------------------------------
echo "bump-and-tag.sh: ${current_version} (build ${current_build}) -> ${new_version} (build ${new_build})"
echo "bump-and-tag.sh: branch=${CURRENT_BRANCH} tag=${new_tag} dry_run=${dry_run}"

if [[ "$dry_run" == "1" ]]; then
    # Dry-run path: print exactly what we'd do and exit before touching disk
    # or running git. Useful for verifying parser + version math without
    # creating throwaway commits/tags.
    echo "bump-and-tag.sh: [DRY-RUN] would edit ${PROJECT_YML}:"
    echo "  MARKETING_VERSION:        \"${current_version}\" -> \"${new_version}\""
    echo "  CURRENT_PROJECT_VERSION:  \"${current_build}\" -> \"${new_build}\""
    echo "bump-and-tag.sh: [DRY-RUN] would run: xcodegen (in ${REPO_ROOT})"
    echo "bump-and-tag.sh: [DRY-RUN] would verify CFBundleShortVersionString=${new_version} in:"
    for plist in "${INFO_PLISTS[@]}"; do
        echo "  - ${plist}"
    done
    echo "bump-and-tag.sh: [DRY-RUN] would git add project.yml MacosWidgetsStatsFromWebsite.xcodeproj Info.plist(s)"
    echo "bump-and-tag.sh: [DRY-RUN] would commit: 'chore: bump to v${new_version} (build ${new_build})'"
    echo "bump-and-tag.sh: [DRY-RUN] would git tag ${new_tag}"
    echo "bump-and-tag.sh: [DRY-RUN] would git push origin ${CURRENT_BRANCH} && git push origin ${new_tag}"
    echo "bump-and-tag.sh: [DRY-RUN] release.yml would trigger on tag push: https://github.com/EthanSK/stats-widget-from-website/actions"
    exit 0
fi

# -------- Edit project.yml --------------------------------------------------
# BSD sed in-place (macOS-native) requires `-i ''`. The regex anchors on the
# beginning-of-line + key prefix to avoid clobbering similarly-named keys
# elsewhere in the YAML (there aren't any, but defence-in-depth).
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*\")[^\"]+(\")/\1${new_version}\2/" "$PROJECT_YML"
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*\")[^\"]+(\")/\1${new_build}\2/" "$PROJECT_YML"

# Verify the sed actually landed — if the regex didn't match (e.g. someone
# changed quoting in project.yml), grep will find the old value and we abort
# loudly before doing anything irreversible.
written_version="$(grep -E '^[[:space:]]*MARKETING_VERSION:[[:space:]]*"[^"]+"' "$PROJECT_YML" \
    | head -n1 | sed -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*$/\1/')"
written_build="$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"[^"]+"' "$PROJECT_YML" \
    | head -n1 | sed -E 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"([^"]+)".*$/\1/')"
if [[ "$written_version" != "$new_version" || "$written_build" != "$new_build" ]]; then
    echo "bump-and-tag.sh: ERROR — project.yml edit didn't land. Got version=${written_version} build=${written_build}." >&2
    echo "bump-and-tag.sh: Reverting project.yml via git checkout." >&2
    git -C "$REPO_ROOT" checkout -- "$PROJECT_YML"
    exit 1
fi

# -------- Regenerate Xcode project ------------------------------------------
# project.yml is the source-of-truth; xcodegen propagates the new version
# variables into the .xcodeproj's xcconfig settings. The Info.plist files
# reference $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION), so they don't
# strictly need rewrites — but xcodegen may touch them anyway (e.g. to update
# generated keys) and we want any such churn included in the bump commit.
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "bump-and-tag.sh: ERROR — xcodegen not on PATH. Install via 'brew install xcodegen'." >&2
    echo "bump-and-tag.sh: Reverting project.yml." >&2
    git -C "$REPO_ROOT" checkout -- "$PROJECT_YML"
    exit 1
fi

echo "bump-and-tag.sh: running xcodegen..."
# Capture stderr separately so a failed xcodegen surfaces a useful error
# (not just "exit 1") while still letting normal stdout through.
xcodegen_stderr="$(mktemp -t bump-and-tag-xcodegen.XXXXXX)"
if ! (cd "$REPO_ROOT" && xcodegen) 2>"$xcodegen_stderr"; then
    echo "bump-and-tag.sh: ERROR — xcodegen failed:" >&2
    cat "$xcodegen_stderr" >&2
    rm -f "$xcodegen_stderr"
    echo "bump-and-tag.sh: Reverting project.yml." >&2
    git -C "$REPO_ROOT" checkout -- "$PROJECT_YML"
    exit 1
fi
rm -f "$xcodegen_stderr"

# -------- Verify generated plists carry the new version ---------------------
# Because the plists use $(MARKETING_VERSION) etc. that get baked at build
# time (not at xcodegen time), the literal Info.plist file may still show
# "$(MARKETING_VERSION)" — that's fine and expected. We verify via PlistBuddy
# only IF the plist contains a literal version string (defensive check):
# if PlistBuddy returns a literal X.Y.Z, it must equal new_version.
for plist in "${INFO_PLISTS[@]}"; do
    if [[ ! -f "$plist" ]]; then
        echo "bump-and-tag.sh: ERROR — expected Info.plist missing: $plist" >&2
        git -C "$REPO_ROOT" checkout -- "$PROJECT_YML"
        exit 1
    fi
    # `Print :CFBundleShortVersionString` returns either the literal version
    # or the unsubstituted xcconfig variable name. Both are acceptable; only
    # a substituted-but-wrong value is an error.
    plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || echo "<absent>")"
    if [[ "$plist_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$plist_version" != "$new_version" ]]; then
        echo "bump-and-tag.sh: ERROR — $plist has CFBundleShortVersionString=$plist_version, expected $new_version." >&2
        git -C "$REPO_ROOT" checkout -- "$PROJECT_YML"
        exit 1
    fi
done

# -------- Stage + commit ----------------------------------------------------
# Stage the YAML + the generated .xcodeproj dir + the Info.plists (in case
# xcodegen touched them — usually only for sort order / Build Settings churn).
# .xcodeproj is a directory bundle of files; `git add` handles it as a tree.
git -C "$REPO_ROOT" add "$PROJECT_YML"
if [[ -d "$REPO_ROOT/MacosWidgetsStatsFromWebsite.xcodeproj" ]]; then
    git -C "$REPO_ROOT" add "$REPO_ROOT/MacosWidgetsStatsFromWebsite.xcodeproj"
fi
for plist in "${INFO_PLISTS[@]}"; do
    # Use --update-add behaviour: add if changed, skip if not. `git add` does
    # this by default; just listing the file is enough.
    git -C "$REPO_ROOT" add "$plist"
done

# If, after staging, there's nothing to commit, something's wrong (the sed
# claimed to land but the file content matches HEAD). Abort defensively.
if git -C "$REPO_ROOT" diff --cached --quiet; then
    echo "bump-and-tag.sh: ERROR — no staged changes after bump+xcodegen. Aborting." >&2
    exit 1
fi

# Commit message format is the one prepare_release_metadata.py + future log
# scrapers expect. Keep it stable.
commit_message="chore: bump to v${new_version} (build ${new_build})"
git -C "$REPO_ROOT" commit -m "$commit_message"
commit_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
echo "bump-and-tag.sh: committed ${commit_sha} (${commit_message})"

# -------- Tag ---------------------------------------------------------------
# Lightweight tag is sufficient — release.yml's tag filter (`v*`) matches
# both lightweight and annotated tags. Use lightweight for minimum ceremony.
# If we ever need GPG-signing for releases, switch to `git tag -a -s`.
git -C "$REPO_ROOT" tag "$new_tag"
echo "bump-and-tag.sh: created tag ${new_tag} at ${commit_sha}"

# -------- Push --------------------------------------------------------------
# Push the branch FIRST, then the tag. Reasoning: release.yml triggers on
# BOTH `push: branches: main` and `push: tags: v*`, but the tag push is the
# canonical trigger for a release. If we pushed the tag first and the branch
# push then failed, we'd have a dangling tag pointing at a commit not on the
# main branch — which prepare_release_metadata.py would still accept (tag
# wins) but is confusing for git archaeology.
echo "bump-and-tag.sh: pushing branch ${CURRENT_BRANCH} to origin..."
git -C "$REPO_ROOT" push origin "$CURRENT_BRANCH"

echo "bump-and-tag.sh: pushing tag ${new_tag} to origin..."
git -C "$REPO_ROOT" push origin "$new_tag"

# -------- Final pointer ------------------------------------------------------
# Single-line final echo per spec — Ethan reads this for the actions URL to
# watch the release roll out.
echo "release.yml will trigger on tag push: https://github.com/EthanSK/stats-widget-from-website/actions"
