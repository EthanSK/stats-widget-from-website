#!/usr/bin/env python3
"""Update the Sparkle appcast used by GitHub Pages."""

from __future__ import annotations

import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ATOM_NS = "http://www.w3.org/2005/Atom"
SPARKLE = f"{{{SPARKLE_NS}}}"
REPO_DEFAULT = "EthanSK/stats-widget-from-website"
SITE_URL = "https://ethansk.github.io/stats-widget-from-website/"
APP_NAME = "Stats Widget from Website"
PLACEHOLDER_SIGNATURE_TOKENS = ("PLACEHOLDER", "CHANGEME", "TODO", "TBD", "DUMMY")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
BASE64_RE = re.compile(r"^[A-Za-z0-9+/=]+$")

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("atom", ATOM_NS)


def die(message: str) -> None:
    print(f"update_appcast.py: {message}", file=sys.stderr)
    sys.exit(1)


def require(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        die(f"missing {name}")
    return value


def validate_release_inputs(
    *,
    version: str,
    display_version: str,
    build_number: str,
    release_tag: str,
    zip_filename: str,
    zip_size: str,
    ed_signature: str,
    repo: str,
    release_notes_url: str,
) -> None:
    if repo != REPO_DEFAULT:
        die(f"REPO must be {REPO_DEFAULT}, got {repo!r}")
    old_slugs = [
        "macos-" + "stats-widget",
        "macos-widgets-stats-from-website",
    ]
    for old_slug in old_slugs:
        if old_slug in repo or old_slug in release_notes_url:
            die(f"old repository slug {old_slug!r} is not allowed in appcast metadata")
    if not SEMVER_RE.match(version):
        die(f"VERSION must be x.y.z, got {version!r}")
    if display_version != version:
        die(f"DISPLAY_VERSION must match VERSION for Sparkle releases, got {display_version!r}")
    if not build_number.isdigit() or int(build_number) <= 0:
        die(f"BUILD_NUMBER must be a positive integer, got {build_number!r}")
    if not release_tag.startswith(f"v{version}"):
        die(f"RELEASE_TAG {release_tag!r} must start with v{version}")
    if "/" in zip_filename or not zip_filename.endswith(".zip"):
        die(f"ZIP_FILENAME must be a release ZIP basename, got {zip_filename!r}")
    # v0.21.22 renamed the release ZIP from "MacosWidgetsStatsFromWebsite-*.zip"
    # to "Stats-Widget-from-Website-*.zip" (URL-safe hyphens — spaces would
    # percent-encode in the Sparkle enclosure URL and break some download
    # clients). voice 4002 / MBP-CC bridge msg-65036391.
    if "Stats-Widget-from-Website" not in zip_filename:
        die(f"ZIP_FILENAME must use the renamed app bundle name, got {zip_filename!r}")
    if not zip_size.isdigit() or int(zip_size) <= 0:
        die(f"ZIP_SIZE must be a positive byte count, got {zip_size!r}")
    upper_signature = ed_signature.upper()
    if any(token in upper_signature for token in PLACEHOLDER_SIGNATURE_TOKENS):
        die("ED_SIGNATURE must be a real Sparkle Ed25519 signature, not a placeholder")
    if len(ed_signature) < 40 or not BASE64_RE.match(ed_signature):
        die("ED_SIGNATURE does not look like Sparkle sign_update base64 output")
    expected_notes_prefix = f"https://github.com/{repo}/releases/tag/"
    if not release_notes_url.startswith(expected_notes_prefix):
        die(f"RELEASE_NOTES_URL must start with {expected_notes_prefix}")


def load_or_create(path: Path) -> tuple[ET.ElementTree, ET.Element]:
    if path.exists():
        tree = ET.parse(path)
        channel = tree.getroot().find("channel")
        if channel is None:
            die(f"{path} is missing <channel>")
        normalize_channel(channel)
        return tree, channel

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    normalize_channel(channel)
    return ET.ElementTree(rss), channel


def set_or_create_text(channel: ET.Element, tag: str, value: str) -> None:
    node = channel.find(tag)
    if node is None:
        node = ET.SubElement(channel, tag)
    node.text = value


def normalize_channel(channel: ET.Element) -> None:
    set_or_create_text(channel, "title", f"{APP_NAME} Updates")
    set_or_create_text(channel, "link", SITE_URL)
    set_or_create_text(channel, "description", f"Automatic update feed for {APP_NAME}.")
    set_or_create_text(channel, "language", "en")

    atom_link = channel.find(f"{{{ATOM_NS}}}link")
    if atom_link is None:
        atom_link = ET.SubElement(channel, f"{{{ATOM_NS}}}link")
    atom_link.set("href", f"{SITE_URL}appcast.xml")
    atom_link.set("rel", "self")
    atom_link.set("type", "application/rss+xml")


def build_item() -> ET.Element:
    version = require("VERSION")
    display_version = require("DISPLAY_VERSION")
    build_number = require("BUILD_NUMBER")
    release_tag = require("RELEASE_TAG")
    zip_filename = require("ZIP_FILENAME")
    zip_size = require("ZIP_SIZE")
    ed_signature = require("ED_SIGNATURE")
    repo = os.environ.get("REPO", REPO_DEFAULT).strip() or REPO_DEFAULT
    min_macos = os.environ.get("MIN_MACOS", "13.0")
    release_notes_url = os.environ.get(
        "RELEASE_NOTES_URL",
        f"https://github.com/{repo}/releases/tag/{release_tag}",
    )
    pub_date = os.environ.get("PUB_DATE") or datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )

    validate_release_inputs(
        version=version,
        display_version=display_version,
        build_number=build_number,
        release_tag=release_tag,
        zip_filename=zip_filename,
        zip_size=zip_size,
        ed_signature=ed_signature,
        repo=repo,
        release_notes_url=release_notes_url,
    )

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"{APP_NAME} v{display_version}"
    ET.SubElement(item, "pubDate").text = pub_date
    ET.SubElement(item, f"{SPARKLE}version").text = build_number
    ET.SubElement(item, f"{SPARKLE}shortVersionString").text = version
    ET.SubElement(item, f"{SPARKLE}minimumSystemVersion").text = min_macos
    ET.SubElement(item, f"{SPARKLE}releaseNotesLink").text = release_notes_url

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set(
        "url",
        f"https://github.com/{repo}/releases/download/{release_tag}/{zip_filename}",
    )
    enclosure.set("length", zip_size)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{SPARKLE}version", build_number)
    enclosure.set(f"{SPARKLE}shortVersionString", version)
    enclosure.set(f"{SPARKLE}edSignature", ed_signature)
    return item


def upsert_item(channel: ET.Element, item: ET.Element, version: str) -> None:
    for existing in channel.findall("item"):
        short = existing.find(f"{SPARKLE}shortVersionString")
        if short is not None and (short.text or "").strip() == version:
            index = list(channel).index(existing)
            channel.remove(existing)
            channel.insert(index, item)
            return

    for index, child in enumerate(list(channel)):
        if child.tag == "item":
            channel.insert(index, item)
            return
    channel.append(item)


def main() -> int:
    appcast_path = Path(os.environ.get("APPCAST_PATH", "appcast.xml"))
    appcast_path.parent.mkdir(parents=True, exist_ok=True)
    tree, channel = load_or_create(appcast_path)
    item = build_item()
    upsert_item(channel, item, require("VERSION"))
    ET.indent(tree, space="  ")
    tree.write(appcast_path, xml_declaration=True, encoding="utf-8")
    print(f"wrote {appcast_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
