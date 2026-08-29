# Town Dock

Town Dock is a native macOS menu-bar utility for managing Town development
worktrees, their local service graphs, and orphaned processes/storage.

## What it shows

- Every worktree registered by the canonical Town repository
- Git branch, dirty/untracked state, and ahead/behind status
- Per-instance frontend, Convex, dashboard, harness, Drizzle, and Electric ports
- Town's own stack-health probes and recommendations
- Shared PostgreSQL, Temporal, MinIO, and Jaeger infrastructure
- Processes or local state left behind by deleted worktrees

## Controls

- Open frontend/service URLs in Google Chrome
- Reveal a worktree in Finder or open it in Terminal
- Start, stop, restart, or force-kill a worktree's verified service graph
- Preview a complete deletion manifest before permanently removing a worktree
- Keep local branch deletion as a separate, explicit checkbox

Town Dock never displays raw Town backend arguments or the full
`.local-convex-services.md`, because both may contain credentials.

## Build

```bash
./scripts/package-app.sh
open "dist/Town Dock.app"
```

Local packages are ad-hoc signed. Click the Stack icon in the menu bar for the
compact view, or choose **Open Town Dock** for the full dashboard. Set
`TOWN_REPOSITORY_PATH` before launching if Town moves from `~/Developer/town`.

Parser, control, registry, and nuke tests live under `Tests/`. This Mac's
Command Line Tools installation can compile them but does not include the
`XCTest` module; `swift test` will run when a full XCTest-capable Xcode
toolchain is selected.

The app is intentionally not App-Sandboxed: it needs to inspect and signal
same-user processes, read Git worktree metadata, and manage local Docker
resources. Destructive operations remain confirmation-gated and are restricted
to targets whose Town/worktree ownership can be proven.

## Versions and automatic updates

The source of truth for the public version is [`VERSION`](VERSION). Release
builds use that value for `CFBundleShortVersionString` and a monotonically
increasing build number for `CFBundleVersion`.

Town Dock embeds Sparkle 2.9.6. A distribution build includes a **Check for
Updates…** command and automatically checks the signed update feed once per
day. Updates can be downloaded and installed automatically after the user
grants Sparkle permission. Local builds leave the command disabled because
they intentionally have no feed URL.

The Sparkle public key is committed in `Resources/Info.plist`. Its private key
is stored in this Mac's login Keychain under the account
`com.tony.towndock`; never commit an exported copy.

### One-time release setup

1. Join the Apple Developer Program and install a **Developer ID Application**
   certificate in Keychain Access.
2. Create an App Store Connect API key with notarization access.
3. Push this repository to GitHub.
4. Add these GitHub Actions secrets:

   - `DEVELOPER_ID_CERTIFICATE_P12`: base64-encoded Developer ID `.p12`
   - `DEVELOPER_ID_CERTIFICATE_PASSWORD`: the `.p12` export password
   - `BUILD_KEYCHAIN_PASSWORD`: a random temporary-keychain password
   - `APPLE_NOTARY_PRIVATE_KEY`: contents of the App Store Connect `.p8` key
   - `APPLE_NOTARY_KEY_ID`: App Store Connect key ID
   - `APPLE_NOTARY_ISSUER_ID`: App Store Connect issuer ID
   - `SPARKLE_PRIVATE_KEY`: exported Sparkle private key

Export the Sparkle private key only long enough to add the secret:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.tony.towndock \
  -x /private/tmp/town-dock-sparkle-key
gh secret set SPARKLE_PRIVATE_KEY < /private/tmp/town-dock-sparkle-key
rm /private/tmp/town-dock-sparkle-key
```

The remaining GitHub secrets can likewise be added with `gh secret set`.

### Publish a release

1. Update `VERSION` and commit the change.
2. Tag that commit with the identical version prefixed by `v`.
3. Push the commit and tag.

```bash
git tag v0.2.0
git push origin main v0.2.0
```

`.github/workflows/release.yml` then builds a universal Apple Silicon/Intel
application, signs every Sparkle helper, notarizes and staples the app,
generates an EdDSA-signed `appcast.xml`, and publishes both the ZIP and feed as
GitHub Release assets. Installed copies read the feed from the latest GitHub
release, so no update server is required.

For a manual release, first save notarization credentials with `notarytool`,
then provide the identity and GitHub URLs:

```bash
xcrun notarytool store-credentials TownDock

TOWN_DOCK_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TOWN_DOCK_FEED_URL="https://github.com/OWNER/REPO/releases/latest/download/appcast.xml" \
TOWN_DOCK_DOWNLOAD_URL_PREFIX="https://github.com/OWNER/REPO/releases/download/v0.2.0/" \
./scripts/release.sh 0.2.0
```
