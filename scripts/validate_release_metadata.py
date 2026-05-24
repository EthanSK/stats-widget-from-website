#!/usr/bin/env python3
"""Validate release, Sparkle appcast, and GitHub Pages metadata.

This deliberately focuses on distribution-facing files so old rename leftovers,
placeholder Sparkle signatures, and stale download links fail before they can be
published.
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = "EthanSK/stats-widget-from-website"
SITE_URL = "https://ethansk.github.io/stats-widget-from-website/"
APP_NAME = "Stats Widget from Website"
APP_BUNDLE_NAME = "MacosWidgetsStatsFromWebsite"
LATEST_ZIP = "MacosWidgetsStatsFromWebsite-latest.zip"
LATEST_ZIP_URL = f"https://github.com/{REPO}/releases/latest/download/{LATEST_ZIP}"
# Stale tokens — if any of these strings appear in release-facing files
# the rename hasn't fully propagated. Note: the OLD bundle/app-group ID
# (com.ethansk.macos-widgets-stats-from-website) intentionally stays — it
# is an internal product-stability identifier, NOT a GitHub repo slug.
OLD_TOKENS = [
    "EthanSK/macos-widgets-stats-from-website",
    "ethansk.github.io/macos-widgets-stats-from-website",
    "macOS Widgets Stats from Website",
    "macos-" + "stats-widget",
    "Macos" + "StatsWidget",
    "macOS " + "Stats Widget",
]
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ATOM_NS = "http://www.w3.org/2005/Atom"
SPARKLE = f"{{{SPARKLE_NS}}}"
ATOM = f"{{{ATOM_NS}}}"
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
BASE64_RE = re.compile(r"^[A-Za-z0-9+/=]+$")

INFO_PLISTS = [
    Path("MacosWidgetsStatsFromWebsite/Apps/MainApp/Info.plist"),
    Path("MacosWidgetsStatsFromWebsite/Apps/WidgetExtension/Info.plist"),
    Path("MacosWidgetsStatsFromWebsite/Apps/CLI/Info.plist"),
]
RELEASE_CONFIG_FILES = [
    Path(".github/workflows/release.yml"),
    Path("README.md"),
    Path("docs/release.md"),
    Path("docs/app-store.md"),
]
SITE_FILES = [
    Path("index.html"),
    Path("404.html"),
    Path("robots.txt"),
    Path("sitemap.xml"),
    Path("styles.css"),
    Path("appcast.xml"),
]


class ValidationError(Exception):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing required file: {path}")


def assert_no_old_tokens(path: Path, text: str) -> None:
    for token in OLD_TOKENS:
        if token in text:
            fail(f"{path} contains stale rename token {token!r}")


def check_repo(root: Path) -> None:
    for relative in RELEASE_CONFIG_FILES:
        path = root / relative
        if path.exists():
            text = read_text(path)
            assert_no_old_tokens(relative, text)

    workflow = read_text(root / ".github/workflows/release.yml")
    # release.yml is tag-only as of commit ebc9198 (voice 3991, 2026-05-24) —
    # branch pushes no longer publish a release; only `vX.Y.Z` tag pushes do.
    # Required snippets match the new trigger shape: `tags:` + `'v*'` instead
    # of the old `branches: main/master`.
    required_snippets = [
        "tags:",
        "'v*'",
        "make_latest: true",
        LATEST_ZIP,
        "softprops/action-gh-release@v2",
        "scripts/validate_release_metadata.py",
        "scripts/prepare_release_metadata.py",
    ]
    for snippet in required_snippets:
        if snippet not in workflow:
            fail(f"release workflow is missing required snippet {snippet!r}")

    update_appcast = read_text(root / "scripts/update_appcast.py")
    for snippet in [REPO, SITE_URL, "PLACEHOLDER", "ZIP_SIZE", "ED_SIGNATURE"]:
        if snippet not in update_appcast:
            fail(f"update_appcast.py is missing expected validation/reference {snippet!r}")


def _read_marketing_version_and_build(project_yml: str) -> tuple[str, str]:
    """Read MARKETING_VERSION and CURRENT_PROJECT_VERSION from project.yml.

    These live in settings.base and are the single source of truth for the
    repo's marketing version + Sparkle build number. Every Info.plist
    inherits via $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION) placeholders
    written by xcodegen and substituted at build time by xcodebuild.
    """
    version_match = re.search(r"^\s*MARKETING_VERSION:\s*\"([^\"]+)\"", project_yml, re.MULTILINE)
    build_match = re.search(r"^\s*CURRENT_PROJECT_VERSION:\s*\"([^\"]+)\"", project_yml, re.MULTILINE)
    if not version_match:
        fail("project.yml is missing settings.base.MARKETING_VERSION (single source of truth)")
    if not build_match:
        fail("project.yml is missing settings.base.CURRENT_PROJECT_VERSION (Sparkle build number)")
    return version_match.group(1), build_match.group(1)


def check_versions(root: Path) -> None:
    project_yml = read_text(root / "project.yml")
    version, build = _read_marketing_version_and_build(project_yml)

    if not SEMVER_RE.match(version):
        fail(f"project.yml MARKETING_VERSION must be x.y.z, got {version!r}")
    if not build.isdigit() or int(build) <= 0:
        fail(f"project.yml CURRENT_PROJECT_VERSION must be a positive integer, got {build!r}")

    # Every Info.plist must inherit via $(MARKETING_VERSION) /
    # $(CURRENT_PROJECT_VERSION) placeholders so xcodebuild substitutes the
    # canonical values at build time. Hard-coded literal versions are not
    # allowed (they were the bug that prompted this single-source-of-truth
    # refactor — see AGENTS.md).
    for relative in INFO_PLISTS:
        with (root / relative).open("rb") as handle:
            payload = plistlib.load(handle)
        plist_version = str(payload.get("CFBundleShortVersionString", "")).strip()
        plist_build = str(payload.get("CFBundleVersion", "")).strip()
        if plist_version != "$(MARKETING_VERSION)":
            fail(
                f"{relative} CFBundleShortVersionString must be the literal "
                f"$(MARKETING_VERSION) placeholder, got {plist_version!r}. "
                "Run `xcodegen` after editing project.yml and DO NOT hand-edit "
                "Info.plist version fields."
            )
        if plist_build != "$(CURRENT_PROJECT_VERSION)":
            fail(
                f"{relative} CFBundleVersion must be the literal "
                f"$(CURRENT_PROJECT_VERSION) placeholder, got {plist_build!r}."
            )

    # Reject any leftover per-target literal CFBundleShortVersionString or
    # CFBundleVersion values in project.yml — they would shadow the
    # settings.base source of truth.
    yml_version_literals = re.findall(
        r"CFBundleShortVersionString:\s*\"(?!\$\(MARKETING_VERSION\))([^\"]+)\"",
        project_yml,
    )
    if yml_version_literals:
        fail(
            "project.yml has per-target literal CFBundleShortVersionString "
            f"values {yml_version_literals!r}; replace with $(MARKETING_VERSION)"
        )
    yml_build_literals = re.findall(
        r"CFBundleVersion:\s*\"(?!\$\(CURRENT_PROJECT_VERSION\))([^\"]+)\"",
        project_yml,
    )
    if yml_build_literals:
        fail(
            "project.yml has per-target literal CFBundleVersion values "
            f"{yml_build_literals!r}; replace with $(CURRENT_PROJECT_VERSION)"
        )

    main_plist = plistlib.load((root / INFO_PLISTS[0]).open("rb"))
    feed_url = str(main_plist.get("SUFeedURL", ""))
    public_key = str(main_plist.get("SUPublicEDKey", ""))
    if feed_url != f"{SITE_URL}appcast.xml":
        fail(f"Main app SUFeedURL is {feed_url!r}, expected {SITE_URL}appcast.xml")
    if not public_key or "PLACEHOLDER" in public_key.upper():
        fail("Main app SUPublicEDKey is missing or placeholder")


def check_site(site_dir: Path) -> None:
    for relative in SITE_FILES:
        path = site_dir / relative
        if path.exists():
            text = read_text(path)
            assert_no_old_tokens(relative, text)

    index = read_text(site_dir / "index.html")
    required = [
        APP_NAME,
        SITE_URL,
        f"https://github.com/{REPO}",
        LATEST_ZIP_URL,
        "releases/latest/download",
    ]
    for snippet in required:
        if snippet not in index:
            fail(f"site index.html is missing required snippet {snippet!r}")

    sitemap = read_text(site_dir / "sitemap.xml")
    if SITE_URL not in sitemap:
        fail("sitemap.xml does not point at the renamed GitHub Pages URL")

    robots = read_text(site_dir / "robots.txt")
    if f"{SITE_URL}sitemap.xml" not in robots:
        fail("robots.txt does not point at the renamed sitemap URL")

    not_found = read_text(site_dir / "404.html")
    if "/stats-widget-from-website/styles.css" not in not_found:
        fail("404.html stylesheet path is not renamed")


def check_signature(signature: str) -> None:
    upper = signature.upper()
    if any(token in upper for token in ["PLACEHOLDER", "CHANGEME", "TODO", "TBD", "DUMMY"]):
        fail("appcast enclosure has a placeholder Sparkle Ed25519 signature")
    if len(signature) < 40 or not BASE64_RE.match(signature):
        fail("appcast enclosure Sparkle Ed25519 signature does not look like base64 output")


def check_appcast(path: Path, require_item: bool) -> None:
    raw = read_text(path)
    assert_no_old_tokens(path, raw)

    try:
        root = ET.fromstring(raw)
    except ET.ParseError as exc:
        fail(f"appcast is not well-formed XML: {exc}")

    channel = root.find("channel")
    if channel is None:
        fail("appcast is missing <channel>")

    title = (channel.findtext("title") or "").strip()
    link = (channel.findtext("link") or "").strip()
    description = (channel.findtext("description") or "").strip()
    atom_link = channel.find(f"{ATOM}link")

    if APP_NAME not in title:
        fail("appcast channel title does not use the renamed app name")
    if link != SITE_URL:
        fail(f"appcast channel link is {link!r}, expected {SITE_URL!r}")
    if APP_NAME not in description:
        fail("appcast channel description does not use the renamed app name")
    if atom_link is None or atom_link.get("href") != f"{SITE_URL}appcast.xml":
        fail("appcast atom self-link does not point at the renamed appcast URL")

    items = channel.findall("item")
    if require_item and not items:
        fail("appcast has no release items")

    for item in items:
        title = (item.findtext("title") or "").strip()
        if APP_NAME not in title:
            fail(f"appcast item title does not use renamed app name: {title!r}")

        sparkle_version = (item.findtext(f"{SPARKLE}version") or "").strip()
        short_version = (item.findtext(f"{SPARKLE}shortVersionString") or "").strip()
        notes = (item.findtext(f"{SPARKLE}releaseNotesLink") or "").strip()
        enclosure = item.find("enclosure")
        if not sparkle_version.isdigit() or int(sparkle_version) <= 0:
            fail(f"appcast item has invalid sparkle:version {sparkle_version!r}")
        if not SEMVER_RE.match(short_version):
            fail(f"appcast item has invalid sparkle:shortVersionString {short_version!r}")
        if not notes.startswith(f"https://github.com/{REPO}/releases/tag/"):
            fail(f"appcast release notes URL is stale or wrong: {notes!r}")
        if enclosure is None:
            fail("appcast item is missing enclosure")

        url = enclosure.get("url", "")
        length = enclosure.get("length", "")
        signature = enclosure.get(f"{SPARKLE}edSignature", "")
        if not url.startswith(f"https://github.com/{REPO}/releases/download/"):
            fail(f"appcast enclosure URL is stale or wrong: {url!r}")
        if not url.endswith(".zip") or APP_BUNDLE_NAME not in url:
            fail(f"appcast enclosure URL does not point at the expected ZIP artifact: {url!r}")
        if not length.isdigit() or int(length) <= 0:
            fail(f"appcast enclosure length must be a positive byte count, got {length!r}")
        check_signature(signature)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--site-dir", type=Path, default=None)
    parser.add_argument("--appcast", type=Path, default=None)
    parser.add_argument("--check-repo", action="store_true")
    parser.add_argument("--check-version", action="store_true")
    parser.add_argument("--check-site", action="store_true")
    parser.add_argument("--check-appcast", action="store_true")
    parser.add_argument("--require-appcast-item", action="store_true")
    args = parser.parse_args()

    if not any([args.check_repo, args.check_version, args.check_site, args.check_appcast]):
        args.check_repo = True
        args.check_version = True

    try:
        repo_root = args.repo_root.resolve()
        if args.check_repo:
            check_repo(repo_root)
        if args.check_version:
            check_versions(repo_root)
        if args.check_site:
            if args.site_dir is None:
                fail("--site-dir is required with --check-site")
            check_site(args.site_dir.resolve())
        if args.check_appcast:
            appcast = args.appcast
            if appcast is None:
                if args.site_dir is None:
                    fail("--appcast or --site-dir is required with --check-appcast")
                appcast = args.site_dir / "appcast.xml"
            check_appcast(appcast.resolve(), args.require_appcast_item)
    except ValidationError as exc:
        print(f"validate_release_metadata.py: {exc}", file=sys.stderr)
        return 1

    print("validate_release_metadata.py: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
