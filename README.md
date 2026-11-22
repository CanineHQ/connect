# Canine Connect

A macOS menu bar app that puts your Mac on a [Canine](https://github.com/CanineHQ/canine) cluster's private network with one switch, using
[Telepresence](https://telepresence.io). Once it's connected, `http://<service>.<namespace>.svc.cluster.local`
resolves and works from your browser, `psql`, `curl`, and so on, even for services that aren't public.

## Build and run

Needs macOS 13+ and the Swift toolchain (the Xcode Command Line Tools are enough):

```bash
script/build.sh --install   # builds, copies to ~/Applications, launches
```

`script/build.sh` on its own just builds `dist/Canine Connect.app`.

To check UI changes without clicking through the menu bar, render every state (signed out, disconnected,
connecting, connected, error) in light and dark mode to PNGs:

```bash
swift build && .build/debug/CanineConnect --snapshot /tmp/canine-connect-snapshots
```

## Using it

1. Click the Canine dog in the menu bar.
2. Check the Canine URL and click **Sign In with Canine**. Approve Canine Connect in your browser and the app
   signs in. (**Use an API token instead** works too, e.g. without a browser or against an older Canine.)
3. Choose a cluster and flip the switch. The first time, macOS asks for your password so Telepresence's
   network daemon can create the tunnel.

Picking another cluster while connected moves the connection to it. Quitting the app disconnects and stops the
Telepresence daemons.

## How it works

- **Sign-in:** OAuth 2.0 authorization code with PKCE, as a public native client. On first sign-in to a Canine
  the app registers itself through dynamic client registration (`POST /oauth/register`, RFC 7591), so nobody has
  to create an OAuth application. It opens `/oauth/authorize` in your default browser, where you're probably
  already signed in, and the browser hands the code back on `canine-connect://oauth/callback`, a URL scheme
  declared in `Info.plist`. The app exchanges the code at `/oauth/token`, and revokes the token at
  `/oauth/revoke` when you sign out.
- **Open from Canine:** Canine's Canine Connect page links to `canine-connect://connect?url=<that Canine's URL>`.
  The app puts the address in its sign-in form, so nobody has to type the URL of a self-hosted Canine. It never
  signs in by itself: any web page can open that link, so the person still sees the address and clicks Sign In.
- **Canine:** calls `GET /api/v1/me` and `GET /api/v1/clusters` with `Authorization: Bearer` (or `X-API-Key`
  when signed in with an API token), plus `X-Account-Id` for the selected account. On connect it downloads that cluster's kubeconfig from
  `GET /api/v1/clusters/:name/download_kubeconfig` to `~/Library/Application Support/Canine Connect/kubeconfigs/`
  (mode 0600). The access token is kept in the login keychain. Canine's kubeconfigs carry a token that expires
  (`expires_at` in the response, a day by default), so the app fetches a fresh one on every connect and
  reconnects with a new one shortly before a long session's token runs out.
- **Telepresence:** the app ships its own CLI in `Contents/Resources/bin/telepresence`, pinned to the same version
  as the Traffic Manager chart Canine installs (`resources/helm/system_packages.yml` in CanineHQ/canine). It runs
  `telepresence connect --kubeconfig <file> --manager-namespace canine-system`, and polls
  `telepresence status --output json` for the menu bar state.
- **Root daemon:** Telepresence's root daemon has to run as root, and the CLI normally starts it with `sudo` from a
  terminal. A GUI app has no terminal, so the app starts `telepresence daemon-foreground` itself through the
  standard macOS administrator prompt. After that, `telepresence connect` needs no privileges.
- Clusters whose `telepresence` package isn't installed get a warning that links to the cluster in Canine.

- **Updates:** on launch and once a day the app asks GitHub for this repo's latest release. When that is newer, the
  popover offers it; clicking **Update** downloads the zip for this Mac's architecture, checks it against the
  SHA-256 GitHub recorded for the file, disconnects, replaces the app where it is installed and reopens it.
  **Check for Updates** in the ••• menu checks on demand, and `"Canine Connect.app/Contents/MacOS/CanineConnect" --update`
  does the same from a script. The app is ad-hoc signed, so an update is trusted because GitHub served it as a
  release of this repository: whoever can publish a release here can update every installed copy.

Logs are in `~/Library/Logs/telepresence` (••• menu → **Open Telepresence Logs**).

## Releasing

People download the app from the **Canine Connect** page in Canine (`/canine_connect`, also linked from every
service's "Connect from your computer" dialog). It links to this repo's latest release
(`releases/latest/download/CanineConnect-macos-<arch>.zip`), so releasing needs no change in Canine:

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Push a matching tag: `git tag v0.1.0 && git push origin v0.1.0`.

`.github/workflows/release.yml` builds `CanineConnect-macos-arm64.zip` and `CanineConnect-macos-x86_64.zip`
(`ARCH=... script/build.sh --zip`) and attaches them to that release. Keep the zip names: Canine's download links
and the app's own updater depend on them. Installed copies offer the new version within a day.

The screenshot on Canine's download page (`public/images/canine_connect/connected.png` in CanineHQ/canine) is the
`connected-dark.png` output of `--snapshot`.

## Bumping Telepresence

The bundled CLI must match the Traffic Manager Canine installs. Change `TELEPRESENCE_VERSION` in `script/build.sh`
together with, in CanineHQ/canine, the telepresence `chart_version` in `resources/helm/system_packages.yml` (and the
CLI version in its `Dockerfile` and `resources/system_install.sh`).

## Limitations

- The app is ad-hoc signed, not notarized. A browser download is quarantined, so macOS asks people to approve it
  under System Settings → Privacy & Security → Open Anyway. Updates the app installs itself aren't quarantined, so
  that happens once. A Developer ID signature and notarization would remove the step, and would give updates a
  publisher signature to check.
- Releases are per-architecture (Apple Silicon and Intel), not a universal binary.
- A kubeconfig that authenticates through an exec plugin (`aws`, `gcloud`, `doctl`) needs that tool in
  `/opt/homebrew/bin`, `/usr/local/bin` or the system paths.
