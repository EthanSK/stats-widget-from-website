#!/bin/bash
# Optional machine-local setup. Run once as root after building/reviewing the
# tiny relay. Nothing invokes this installer automatically on app launch.
set -euo pipefail
label=com.ethansk.stats-widget.memory-pressure-relay
binary="/Library/PrivilegedHelperTools/$label"
plist="/Library/LaunchDaemons/$label.plist"
if [[ $EUID != 0 ]]; then
    echo "Run this installer as root." >&2
    exit 77
fi
if [[ ${1:-} == --uninstall && $# == 1 ]]; then
    if [[ -x "$binary" && ! -L "$binary" ]]; then "$binary" --clear; fi
    /bin/launchctl bootout "system/$label" 2>/dev/null || true
    /bin/rm -f "$plist" "$binary"
    echo "Memory relief relay removed."
    exit 0
fi
if [[ $# != 2 ]]; then
    echo "Usage: $0 /absolute/path/to/memory-pressure-relay expected-sha256" >&2
    exit 64
fi
source_binary=$1
expected_hash=$2
[[ "$source_binary" == /* && -f "$source_binary" && ! -L "$source_binary" ]]
[[ "$expected_hash" =~ ^[a-f0-9]{64}$ ]]
[[ ! -L "$binary" && ! -L "$plist" ]]
actual_hash=$(/usr/bin/shasum -a 256 "$source_binary" | /usr/bin/awk '{print $1}')
[[ "$actual_hash" == "$expected_hash" ]]
if [[ -e "$binary" ]]; then
    # Preserve a different existing installation rather than replacing a live
    # root service without its own rollback path. Uninstall explicitly first.
    [[ $(/usr/bin/shasum -a 256 "$binary" | /usr/bin/awk '{print $1}') == "$expected_hash" ]]
fi
if [[ ! -d /Library/PrivilegedHelperTools ]]; then
    /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
fi
stage=$(/usr/bin/mktemp "/Library/PrivilegedHelperTools/$label.XXXXXX")
plist_stage=$(/usr/bin/mktemp "/Library/LaunchDaemons/$label.XXXXXX")
trap '/bin/rm -f "$stage" "$plist_stage"' EXIT
/usr/bin/install -o root -g wheel -m 755 "$source_binary" "$stage"
[[ $(/usr/bin/shasum -a 256 "$stage" | /usr/bin/awk '{print $1}') == "$expected_hash" ]]
/usr/bin/codesign --verify --strict "$stage"
# This real kernel registration must pass BEFORE replacing an existing service.
"$stage" --probe
cat > "$plist_stage" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.ethansk.stats-widget.memory-pressure-relay</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/com.ethansk.stats-widget.memory-pressure-relay</string></array>
<key>UserName</key><string>root</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>ThrottleInterval</key><integer>30</integer>
<key>StandardErrorPath</key><string>/var/log/stats-widget-memory-relief.log</string>
</dict></plist>
PLIST
/usr/sbin/chown root:wheel "$plist_stage"
/bin/chmod 644 "$plist_stage"
/usr/bin/plutil -lint "$plist_stage"
/bin/launchctl bootout "system/$label" 2>/dev/null || true
/bin/mv -f "$stage" "$binary"
/bin/mv -f "$plist_stage" "$plist"
/bin/launchctl bootstrap system "$plist"
/bin/sleep 1
/bin/launchctl print "system/$label" | /usr/bin/awk '
    /state = running/ { running = 1 }
    /pid =/ { pid = $3 }
    END { exit !(running && pid > 0) }
'
echo "Memory relief relay installed; LOW_SWAP registration verified."
