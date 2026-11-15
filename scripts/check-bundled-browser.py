#!/usr/bin/env python3
"""Verify the signed browser renders JavaScript using an isolated profile."""
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve()
browser = app / "Contents/Resources/Browsers/Chromium.app"
info = plistlib.loads((browser / "Contents/Info.plist").read_bytes())
pin = (Path(__file__).resolve().parent.parent / "CHROMIUM_REVISION").read_text().strip()
revision = re.search(r"@\{#(\d+)\}", info.get("SCMRevision", ""))
if not revision or revision.group(1) != pin:
    raise SystemExit(f"Bundled Chromium does not match tested revision {pin}")

# Derive the static launch switches from the app's owning Swift method. The
# app disables macOS framework probes that can hang a stock headless launch;
# a separate hand-maintained flag list would drift from real scrape behavior.
source = (Path(__file__).resolve().parent.parent / "MacosWidgetsStatsFromWebsite/Shared/Scraping/ChromeBrowserProfile.swift").read_text()
source = source.split("private func buildChromeLaunchArguments(", 1)[1].split("return arguments", 1)[0]
static_flags = re.findall(r'^\s*"(--[^"\\]*)"\s*,?\s*$', source, re.MULTILINE)
assert "--headless=new" in static_flags and any(flag.startswith("--disable-features=") for flag in static_flags)

with tempfile.TemporaryDirectory(prefix="stats-browser-smoke.noindex.") as directory:
    command = [str(browser / "Contents/MacOS/Chromium"), *static_flags,
               "--remote-debugging-port=0", "--user-data-dir=" + directory, "about:blank"]
    with tempfile.TemporaryFile(mode="w+") as log:
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=log, start_new_session=True)
        try:
            helper = Path(__file__).with_name("check-bundled-browser-cdp.mjs")
            result = subprocess.run(["node", str(helper), directory], capture_output=True, text=True, timeout=40)
            if result.returncode != 0:
                log.seek(0)
                raise SystemExit("Bundled Chromium renderer failed: " + result.stderr[-2000:] + log.read()[-2000:])
        except subprocess.TimeoutExpired:
            log.seek(0)
            raise SystemExit("Bundled Chromium renderer timed out: " + log.read()[-3000:])
        finally:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
print(f"Bundled Chromium {info['CFBundleShortVersionString']} (revision {pin}) rendered JavaScript successfully")
