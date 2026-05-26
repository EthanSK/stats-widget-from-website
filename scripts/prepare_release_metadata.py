#!/usr/bin/env python3
"""Prepare version/build metadata for signed GitHub releases.

The checked-in Info.plists carry the human app version and a small base build
number. For branch/manual GitHub Actions releases, this script can patch the
working tree's Info.plists to a monotonic Sparkle-compatible build number while
leaving the marketing version stable.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# ASSET_PREFIX is the on-disk ZIP basename prefix — uses URL-safe hyphens
# so the Sparkle enclosure URL doesn't percent-encode (spaces would). The
# user-facing .app wrapper is "Stats Widget from Website.app" with spaces
# (set in .github/workflows/release.yml's $APP_NAME), but the ZIP that
# wraps it deliberately uses hyphens for transport. v0.21.22, voice 4002 /
# MBP-CC bridge msg-65036391.
ASSET_PREFIX = "Stats-Widget-from-Website"
REPO = "EthanSK/stats-widget-from-website"
DISPLAY_NAME = "Stats Widget from Website"
INFO_PLISTS = [
    Path("MacosWidgetsStatsFromWebsite/Apps/MainApp/Info.plist"),
    Path("MacosWidgetsStatsFromWebsite/Apps/WidgetExtension/Info.plist"),
    Path("MacosWidgetsStatsFromWebsite/Apps/CLI/Info.plist"),
]
TAG_RE = re.compile(r"^v(?P<version>\d+\.\d+\.\d+)(?:-build\.(?P<build>\d+))?$")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"prepare_release_metadata.py: {message}", file=sys.stderr)
    sys.exit(1)


def read_plist(relative_path: Path) -> dict:
    path = ROOT / relative_path
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except FileNotFoundError:
        fail(f"missing plist: {relative_path}")


def write_plist(relative_path: Path, payload: dict) -> None:
    path = ROOT / relative_path
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)


def git_tag_exists(tag: str) -> bool:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}"],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def release_values_for_ref(version: str, base_build: int) -> dict[str, str]:
    ref_type = os.environ.get("GITHUB_REF_TYPE", "branch")
    ref_name = os.environ.get("GITHUB_REF_NAME", "local")
    run_number_raw = os.environ.get("GITHUB_RUN_NUMBER", "0")
    sha = os.environ.get("GITHUB_SHA", "local")

    if not run_number_raw.isdigit():
        fail(f"GITHUB_RUN_NUMBER must be numeric, got {run_number_raw!r}")
    run_number = int(run_number_raw)

    canonical_tag = f"v{version}"
    release_tag = canonical_tag
    build_number = base_build
    release_title = f"{DISPLAY_NAME} v{version}"
    release_channel = "branch"

    if ref_type == "tag":
        match = TAG_RE.match(ref_name)
        if not match:
            fail(
                f"tag {ref_name!r} is not supported; use v{version} or "
                f"v{version}-build.<number>"
            )
        if match.group("version") != version:
            fail(f"tag {ref_name!r} does not match CFBundleShortVersionString {version!r}")
        release_tag = ref_name
        # v0.21.43 (Ethan voice 4212, 2026-05-26) — distinguish canonical
        # `v<X.Y.Z>` tags from build-suffix `v<X.Y.Z>-build.<N>` tags so
        # the release.yml workflow can gate the appcast update on the
        # canonical path only. Build-suffix releases still produce a
        # GitHub Release (test artifact + downloadable .zip), but they
        # do NOT publish to appcast.xml because their CFBundleVersion
        # encoding interleaves with canonical releases in a way that
        # confuses Sparkle's update-comparison logic. See the comment
        # block on the `else` branch below for the historical incident
        # this prevents from recurring.
        release_channel = "tag-build" if match.group("build") else "tag"
        if match.group("build"):
            # v0.21.43 (Ethan voice 4212, 2026-05-26) — sparkle:version
            # drift fix. Build-suffix tags (e.g. v0.21.41-build.90) used
            # to compute CFBundleVersion as `base_build * 100000 + build`,
            # which produced mega-numbers (129700090) that interleaved
            # badly with tag-driven releases' small monotonic numbers
            # (e.g. 1296 for v0.21.40 → 1298 for v0.21.42), causing the
            # next clean tag release to LOSE the Sparkle numeric
            # comparison against an installed build-suffix release.
            # Paired with the workflow-level gate that prevents
            # build-suffix releases from publishing to appcast.xml at
            # all (see release.yml "Update gh-pages appcast" step),
            # CFBundleVersion now stays as `base_build` regardless of
            # the `-build.<N>` suffix. Two build-suffix releases for
            # the same marketing version will therefore share a
            # CFBundleVersion — that's fine because they don't reach
            # the appcast, and users who manually install a build-suffix
            # release will see the next tag release as a same-build
            # update (which Sparkle will offer ONLY if the marketing
            # version changes, which it always does between releases
            # because bump-and-tag.sh increments both).
            release_title = f"{DISPLAY_NAME} v{version} (build {match.group('build')})"
    else:
        # Producer Player-style branch releases: use the canonical version tag
        # once, then deterministic build tags once that tag exists. This keeps
        # the per-release artifact uniquely tagged for download URLs while
        # CFBundleVersion stays as the source-of-truth base_build (the
        # mega-number `base_build * 100000 + run_number` encoding was
        # dropped in v0.21.43 — see the tag-path comment above for the
        # full rationale).
        if git_tag_exists(canonical_tag):
            release_tag = f"{canonical_tag}-build.{run_number}"
            release_title = f"{DISPLAY_NAME} v{version} (build {run_number})"

    zip_filename = f"{ASSET_PREFIX}-{release_tag}.zip"
    latest_zip_filename = f"{ASSET_PREFIX}-latest.zip"
    release_notes_url = f"https://github.com/{REPO}/releases/tag/{release_tag}"

    return {
        "RELEASE_VERSION": version,
        "RELEASE_DISPLAY_VERSION": version,
        "RELEASE_BASE_BUILD_NUMBER": str(base_build),
        "RELEASE_BUILD_NUMBER": str(build_number),
        "RELEASE_TAG": release_tag,
        "RELEASE_TITLE": release_title,
        "RELEASE_CHANNEL": release_channel,
        "RELEASE_COMMIT_SHA": sha,
        "RELEASE_REPO": REPO,
        "RELEASE_NOTES_URL": release_notes_url,
        "ASSET_ZIP_FILENAME": zip_filename,
        "LATEST_ZIP_FILENAME": latest_zip_filename,
        "LATEST_ZIP_URL": f"https://github.com/{REPO}/releases/latest/download/{latest_zip_filename}",
        "VERSIONED_ZIP_URL": f"https://github.com/{REPO}/releases/download/{release_tag}/{zip_filename}",
    }


def patch_info_plists(version: str, build_number: str) -> None:
    for relative_path in INFO_PLISTS:
        payload = read_plist(relative_path)
        payload["CFBundleShortVersionString"] = version
        payload["CFBundleVersion"] = build_number
        write_plist(relative_path, payload)


def write_key_values(path: str | None, values: dict[str, str]) -> None:
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in values.items():
            if "\n" in value:
                fail(f"refusing to write multiline value for {key}")
            handle.write(f"{key}={value}\n")


def _read_yaml_settings() -> tuple[str, str]:
    """Read MARKETING_VERSION and CURRENT_PROJECT_VERSION from project.yml.

    Single source of truth lives in settings.base — Info.plists carry the
    literal $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION) placeholders
    that xcodebuild substitutes at build time. See AGENTS.md.
    """
    project_yml = (ROOT / "project.yml").read_text(encoding="utf-8")
    version_match = re.search(r"^\s*MARKETING_VERSION:\s*\"([^\"]+)\"", project_yml, re.MULTILINE)
    build_match = re.search(r"^\s*CURRENT_PROJECT_VERSION:\s*\"([^\"]+)\"", project_yml, re.MULTILINE)
    if not version_match:
        fail("project.yml is missing settings.base.MARKETING_VERSION")
    if not build_match:
        fail("project.yml is missing settings.base.CURRENT_PROJECT_VERSION")
    return version_match.group(1), build_match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply-plists", action="store_true", help="patch Info.plists to RELEASE_BUILD_NUMBER")
    parser.add_argument("--github-env", default=os.environ.get("GITHUB_ENV"), help="append release env vars to this file")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"), help="append release outputs to this file")
    args = parser.parse_args()

    version, base_build_raw = _read_yaml_settings()

    if not SEMVER_RE.match(version):
        fail(f"MARKETING_VERSION must be x.y.z, got {version!r}")
    if not base_build_raw.isdigit():
        fail(f"CURRENT_PROJECT_VERSION must be numeric, got {base_build_raw!r}")

    base_build = int(base_build_raw)
    values = release_values_for_ref(version, base_build)

    if args.apply_plists:
        patch_info_plists(version, values["RELEASE_BUILD_NUMBER"])

    write_key_values(args.github_env, values)
    write_key_values(args.github_output, values)

    for key in sorted(values):
        print(f"{key}={values[key]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
