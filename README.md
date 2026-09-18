# wlshare-macos

A native macOS client for the [`wlshare`](https://github.com/andrewtheguy/wlshare)
VNC server: an AppKit window drawing a Metal texture, over a Rust core that
speaks the whole RFB session.

**Scope:** the screen, the keyboard, the pointer, retina, the clipboard and the
desktop's sound. The screen arrives as wlshare's VP9 stream — the whole desktop,
4:4:4, at the server's `vp9_quality` or, while the link is behind, lower, down
to its `vp9_quality_min` — or, when the connect
form's **Encoding** says so, as exact ZRLE. VP9 is asked for alone: a server
without it ends the session with an error instead of sending ZRLE, and the
window's title ends in `· VP9` when the form chose it. The desktop is asked to be exactly the window's backing store,
drawn at the window's density, so what is on screen is one device pixel per
desktop pixel and never resampled. The clipboard is text, both ways, as UTF-8.
The sound is wlshare's lossless FLAC stream, played on the Mac's default output,
and only when the connect form's **Play the desktop's sound** is ticked. Camera,
microphone and picking an output are wlshare extensions this client does not
speak.

macOS only, Apple Silicon only. There is no iOS target.

## Install

Each release carries `WlshareViewer-macos-arm64.dmg` — the app in a
drag-to-Applications disk image — and a `SHA256SUMS` beside it.

The image is **unsigned and not notarized**: there is no Developer ID behind it.
Gatekeeper quarantines anything a browser downloads and then says *"wlshare" is
damaged and can't be opened*, which is the message it gives for this rather than
for anything actually being wrong.

The clean way around it is not to pick up the quarantine flag at all — browsers
set `com.apple.quarantine`, `curl` does not:

```sh
# Replace vX.Y.Z with the tag from the Releases page.
curl -fL -o WlshareViewer.dmg \
  https://github.com/andrewtheguy/wlshare-macos/releases/download/vX.Y.Z/WlshareViewer-macos-arm64.dmg
shasum -a 256 WlshareViewer.dmg
```

Then open the image, drag the app — Finder shows it as **wlshare**, the bundle is
`WlshareViewer.app` — onto the **Applications** shortcut in the window, and eject
it. If you already downloaded through a browser, the flag
follows the app out of the image, so clear it where it landed:

```sh
xattr -cr /Applications/WlshareViewer.app
```

Right-clicking the app and choosing **Open** the first time works too.

Building it yourself avoids all of this — a locally built app is never
quarantined:

```sh
scripts/package-mac.sh   # dist/package/WlshareViewer-macos-arm64.dmg
```

## What you need

- A Mac with Xcode (for `xcodebuild` and the Metal toolchain —
  `xcodebuild -downloadComponent MetalToolchain` if `metal` is missing) and
  [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Rust. The core links `wlshare-rfb`, where every protocol byte comes from,
  pinned in `core/Cargo.toml` to a released tag of the `wlshare` repo and
  fetched by cargo — no sibling checkout needed to build.

## Connecting

Opening the app — from the Finder, from the Dock, from `open` — puts up a form
for the host, the port, the user name and the password, and connects when you
fill it in. It comes back filled with the last destination, and with the
password too if you ticked **Remember the password**, which puts it in the
keychain and nowhere else. **File ▸ Connect…** (⌘N) asks again, **Disconnect**
(⌘D) ends the session, and a connection that is refused or drops brings the form
back with the reason on it.

An empty password asks for the `None` security type; anything else asks for
RSA-AES, which is the only type this client authenticates with — and the one
that encrypts the session.

A destination on the command line skips the form, which is what the script and
the tests use:

```sh
scripts/run-macos.sh                            # ask in the app's own window
scripts/run-macos.sh 192.168.1.10:5900          # straight to that desktop
```

That builds the core, generates the project, builds the app and opens it. The
app takes the same words by hand:

```sh
WlshareViewer.app/Contents/MacOS/WlshareViewer -server host:port -username me -audio YES -encoding zrle
```

`-audio YES` is the form's sound checkbox; without it the session is silent.
`-encoding` is the form's encoding, `vp9` (the default) or `zrle`.

There is no password argument, deliberately: an argument list is in the shell's
history and in everyone's `ps`. A password that was remembered for that
destination comes from the keychain, and anything else is typed into the form —
which is what a connection refused for want of one brings back.

## Checks

```sh
ci/ci.sh                # the Rust core's tests and clippy, then the app build
ci/ci.sh package        # the Release build and the disk image a release ships
ci/ci.sh live           # the session tests, against a real wlshare
```

`core/` builds and tests on Linux too, and that is the fast loop: the protocol,
the decoders and the session state machine have nothing Apple in them.

## Releasing

Bump `MARKETING_VERSION` in `project.yml`, then run the **Release the macOS app**
workflow by hand (`gh workflow run release.yml --ref main`). It builds and
packages on a runner with `scripts/package-mac.sh`, publishes the disk image and
`SHA256SUMS` as `v<MARKETING_VERSION>`, and creates that tag — a run on any
branch other than `main` is a prerelease instead. A version that already has a
tag is refused.

## Layout

- `core/` — the Rust crate: session, framebuffer, keysym and wheel tables, and
  the C ABI in `src/ffi.rs` behind `include/wlshare_client.h`.
- `Sources/WlshareViewer/` — the app: the connect form, the window, the Metal
  view, the input.
- `scripts/package-mac.sh` — the release build and the disk image; the release
  workflow runs nothing else.
- `docs/architecture.md` — how the two halves fit together, and why.
