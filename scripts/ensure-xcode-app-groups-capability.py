#!/usr/bin/env python3
"""Patch XcodeGen's stringified App Groups capability into pbxproj syntax.

XcodeGen target `attributes` currently serializes nested dictionaries as a quoted
string in TargetAttributes. Xcode's signing/capability machinery expects a real
PBX dictionary, so automatic signing can otherwise keep using a wildcard profile
that does not authorize the App Group entitlement.
"""

from pathlib import Path
import re
import sys

PROJECT_FILE = Path("MacosWidgetsStatsFromWebsite.xcodeproj/project.pbxproj")
APP_GROUP_CAPABILITY = """SystemCapabilities = {
\t\t\t\t\t\t\tcom.apple.ApplicationGroups = {
\t\t\t\t\t\t\t\tenabled = 1;
\t\t\t\t\t\t\t};
\t\t\t\t\t\t};"""

STRINGIFIED_CAPABILITY_RE = re.compile(
    r'SystemCapabilities = "\[.*com\.apple\.ApplicationGroups.*\]";'
)


def main() -> int:
    if not PROJECT_FILE.exists():
        print(f"error: {PROJECT_FILE} does not exist", file=sys.stderr)
        return 1

    text = PROJECT_FILE.read_text()
    text, replacements = STRINGIFIED_CAPABILITY_RE.subn(APP_GROUP_CAPABILITY, text)

    if replacements == 0:
        if "com.apple.ApplicationGroups = {" in text:
            print("ensure-xcode-app-groups-capability: App Groups capability already uses PBX dictionary syntax")
            return 0

        print(
            "error: did not find XcodeGen stringified App Groups SystemCapabilities entry",
            file=sys.stderr,
        )
        return 1

    PROJECT_FILE.write_text(text)
    print(f"ensure-xcode-app-groups-capability: patched {replacements} App Groups capability entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
