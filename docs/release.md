# Release and Sparkle setup

This repo is wired for signed, notarized GitHub Releases plus a Sparkle appcast on the `gh-pages` branch.

The release flow mirrors the pattern used by [Producer Player](https://github.com/EthanSK/producer-player) and [OBScene](https://github.com/EthanSK/OBScene): every push to `main` automatically builds, notarizes, publishes a GitHub Release, regenerates the Sparkle appcast, and rewrites `version.json` on `gh-pages` so the landing page's version badge stays current with zero manual intervention.

## What the workflow publishes

The `Release` workflow runs on:

- pushes to `main` or `master` (auto-release on every commit)
- tags matching `v*` (manual canonical tag releases)
- manual `workflow_dispatch` (re-runs from the Actions tab)

For branch/manual runs, the workflow reads the checked-in app version from `MacosWidgetsStatsFromWebsite/Apps/MainApp/Info.plist`.

- If `v<version>` does not already exist, it publishes that canonical tag.
- If `v<version>` already exists, it publishes `v<version>-build.<github-run-number>` and patches the CI build's `CFBundleVersion` to a larger numeric Sparkle build number.

That means repeated main-branch releases stay monotonic for Sparkle without forcing a marketing-version bump on every commit.

Each release attaches:

- a versioned ZIP: `Stats-Widget-from-Website-<release-tag>.zip`
- a stable latest alias: `Stats-Widget-from-Website-latest.zip`

The on-disk ZIP basename uses URL-safe hyphens; the .app wrapper inside is
named `Stats Widget from Website.app` (with spaces) — the internal executable
inside `Contents/MacOS/` stays `MacosWidgetsStatsFromWebsite` for backward
compatibility with the LaunchAgent + sibling-resolver code paths. Renamed in
v0.21.22 (voice 4002 / MBP-CC bridge msg-65036391).

The stable user-facing URL is:

```text
https://github.com/EthanSK/stats-widget-from-website/releases/latest/download/Stats-Widget-from-Website-latest.zip
```

Sparkle appcast URL:

```text
https://ethansk.github.io/stats-widget-from-website/appcast.xml
```

## Required GitHub Actions secrets

Add these in GitHub → repo → Settings → Secrets and variables → Actions:

| Secret | Required | Purpose |
| --- | --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | yes | Base64-encoded Developer ID Application `.p12` certificate export. |
| `APPLE_CERTIFICATE_PASSWORD` | yes | Password for the exported `.p12`. |
| `APPLE_ID` | yes | Apple ID email used by `xcrun notarytool`. |
| `APPLE_APP_SPECIFIC_PASSWORD` | yes | App-specific password for notarization. |
| `SPARKLE_ED25519_PRIVATE_KEY` | yes | Sparkle Ed25519 private key used by `sign_update`. |
| `APPLE_TEAM_ID` | recommended | 10-character Apple Developer Team ID for signing/notarization. |
| `DEVELOPMENT_TEAM` | optional fallback | Alternate team-id secret name supported by the workflow. |

The checked-in fallback team ID is `T34G959ZG8`, but `APPLE_TEAM_ID` is safer because it keeps account-specific release configuration in GitHub settings.

## One-time local/key setup

Sparkle public key already in the app:

```text
SUPublicEDKey = 9PG32PH1UFbECc644qjE4OQtpiILuiPCOUuXvgND2tA=
```

Keep the corresponding private key out of git. The maintainer note uses the Keychain item:

```text
Sparkle Ed25519 Private Key (macos-widgets-stats-from-website)
```

To export the Developer ID certificate as base64 for GitHub Actions:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

## Validation gates

The workflow runs `scripts/validate_release_metadata.py` before building and after appcast generation. It fails if:

- release config points at the old repo slug
- the GitHub Release is not marked `make_latest: true`
- the stable latest ZIP alias is missing
- Sparkle signatures are placeholders
- appcast enclosure lengths are zero/missing
- appcast/site URLs point at the old GitHub Pages or GitHub repo paths
- app/widget/CLI Info.plist versions drift from `project.yml`

You can run the static gate locally:

```bash
python3 scripts/validate_release_metadata.py --check-repo --check-version
```

## Safe release procedure

1. Ensure the working tree is clean.
2. Bump `CFBundleShortVersionString` and `CFBundleVersion` together in `project.yml` and generated Info.plists.
3. Run:

   ```bash
   xcodegen generate
   python3 scripts/validate_release_metadata.py --check-repo --check-version
   git diff --check
   ```

4. Push to `main`/`master`, or push a matching tag such as `v0.13.0`.
5. Confirm the release contains both ZIP assets and that `gh-pages/appcast.xml` was updated by the workflow.

Do not hand-edit the Sparkle appcast with placeholder signatures. Let the workflow generate it from the signed ZIP so the signature and byte length match the shipped asset.
