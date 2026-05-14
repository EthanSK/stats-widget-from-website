#!/usr/bin/env python3
"""Write site/version.json for the landing page.

Reads the release context from environment variables exported by
the workflow's Prepare-release-metadata step (RELEASE_VERSION,
GITHUB_REPOSITORY, LATEST_ZIP_FILENAME). Writes a JSON file with
the schema the landing page's #brand-version loader expects:

    {
      "version":      "x.y.z",
      "channel":      "stable" | "prerelease" | ...,
      "updated_at":   ISO-8601 UTC timestamp,
      "release_url":  "https://github.com/<owner>/<repo>/releases/latest",
      "appcast_url":  "https://ethansk.github.io/<slug>/appcast.xml",
      "download_url": "https://github.com/<owner>/<repo>/releases/latest/download/<latest-zip>"
    }

Usage:
    python3 scripts/write_version_json.py /path/to/site/version.json
"""

from __future__ import annotations

import datetime
import json
import os
import sys


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"write_version_json.py: missing required env var {name!r}")
    return value


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.exit("usage: write_version_json.py <output-path>")
    output_path = argv[1]

    version = required_env("RELEASE_VERSION")
    repo = required_env("GITHUB_REPOSITORY")
    latest_zip = required_env("LATEST_ZIP_FILENAME")
    channel = os.environ.get("RELEASE_CHANNEL", "stable").strip() or "stable"

    owner, _, slug = repo.partition("/")
    if not owner or not slug:
        sys.exit(f"write_version_json.py: GITHUB_REPOSITORY {repo!r} is not owner/slug")

    payload = {
        "version": version,
        "channel": "stable" if channel in ("branch", "tag", "stable") else channel,
        "updated_at": datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "release_url": f"https://github.com/{repo}/releases/latest",
        "appcast_url": f"https://ethansk.github.io/{slug}/appcast.xml",
        "download_url": f"https://github.com/{repo}/releases/latest/download/{latest_zip}",
    }

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    print(f"wrote {output_path}: {payload}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
