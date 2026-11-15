# Emergency memory relief

The optional root relay listens for macOS's LOW_SWAP exhaustion notification.
Ordinary swap use and warning/critical memory pressure do not pause refreshes.
On exhaustion the host cancels admission of background scrapes and closes its
tracked background Chromium children. Saved readings remain intact. Existing
visible Identify/login windows are preserved. Old queued jobs and interrupted
results cannot reopen a browser or turn saved readings into scrape failures.

The relay permits refreshes again after 120 continuously observed seconds of
normal memory pressure. The normal due-scrape watchdog picks up overdue readings;
there is no immediate whole-app restart or eager browser respawn.

## Install on a Mac

Build the relay with the local macOS SDK, outside the source tree:

```sh
clang -Wall -Wextra -Werror -O2 helpers/memory-pressure-relay.c -o /absolute/scratch.noindex/memory-pressure-relay
shasum -a 256 /absolute/scratch.noindex/memory-pressure-relay
sudo /bin/bash scripts/install-memory-relief.sh /absolute/scratch.noindex/memory-pressure-relay SHA256_FROM_ABOVE
```

The installer checks the exact binary hash and signature, performs a real
root-only kernel registration probe, and then installs one root-owned relay in
`/Library/PrivilegedHelperTools` plus its `/Library/LaunchDaemons` plist. The relay
does not read profiles, credentials or app data and cannot execute commands or
kill processes. It only publishes a system-wide Darwin notification latch for
Stats Widget. The app itself closes its own background children.

Remove it with `sudo /bin/bash scripts/install-memory-relief.sh --uninstall`.
The uninstaller clears the pause latch before unloading the service.

## Verification and limits

Run the policy test by compiling `helpers/memory-pressure-relay-tests.c` with
`-Wall -Wextra -Werror -Wno-unused-function` and running the resulting binary.
Run `EmergencyMemoryReliefTests` in the existing HookTests test target for real
Darwin notification delivery, startup latching and cancelled-generation checks.
Tests use unique notification names and do not exhaust the Mac's memory.

Apple documents LOW_SWAP in [its kernel notification documentation](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md#low-swap-notifications-macos-only).
The filter and flag are a private macOS ABI; the registration probe must pass
after an OS update. A listener cannot guarantee that macOS will pause Stats Widget
before another app. If the host itself is suspended before receiving the event,
it cannot close its children until the host is resumed. No automatic resumption
of unrelated apps or circumvention of macOS's suspension policy is attempted.
