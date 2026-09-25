# wlshare-macos

A native macOS client for the [`wlshare`](https://github.com/andrewtheguy/wlshare)
VNC server: an AppKit window drawing a Metal texture, over a Rust core that
speaks the whole RFB session.

**Scope:** the screen, the keyboard, the pointer, retina, the clipboard and the
desktop's sound. The screen arrives as wlshare's VP9 stream — the whole desktop,
4:4:4, at the server's `vp9_quality` or, while the link is behind, lower, down
to its `vp9_quality_min`, and sharpened back to `vp9_quality` half a second after
the desktop goes quiet — or, when the connect
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
- Rust. The core links `wlshare-client`, the session both native clients are
  built on, and `wlshare-rfb` under it, where every protocol byte comes from —
  pinned in `core/Cargo.toml` to a released tag of the `wlshare` repo and
  fetched by cargo, no sibling checkout needed to build.

## Connecting

Opening the app — from the Finder, from the Dock, from `open` — puts up the
**Library**: the saved desktops as a list, and beside it a form for the one
selected — a name, the host, the port, the user name, the password, the
encoding and the sound. Nothing is saved until you say so: **Save** writes the
form into that profile, and **Connect** (or a double-click on the row) does the
same and connects; with nothing selected either makes a new profile of what
you typed. **+** clears the form for a new desktop, which joins the list once
it is saved or connected, and **−** deletes the selected one. Moving to another
row, closing the window or quitting with something unsaved asks whether to
keep it. A row is its name and where it goes — there is no picture of the
desktop.

Each desktop opens in a window of its own, in front of the library, which stays
where it is: connecting adds a window rather than taking the place of anything
that is up, so several desktops can be open at once, each with its own sound
and its own clipboard. There is one library window; **Window ▸ Library** brings
it forward from behind the desktops, and the rest of **Window** lists what is
open. Both are clicked, since every chord is the desktop's while it holds the
keyboard. The library opens where it was last left, and so does a desktop,
under its profile; a second window on the same profile, or one from the
command line, cascades off the one before it instead.

The password is saved only for a profile whose **Save the password** is ticked,
and then sealed: see [Saved passwords](#saved-passwords). **Disconnect**
closes the desktop in front, closing the last window — the library or a
desktop — quits the app, and a connection that is refused or drops says why in
its own window, which stays open until it is closed.

An empty password asks for the `None` security type; anything else asks for
RSA-AES, which is the only type this client authenticates with — and the one
that encrypts the session.

A destination on the command line skips the library, which is what the script
and the tests use:

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
history and in everyone's `ps`. A password saved in a profile for the same
host, port and user name is used, and anything else is typed into the form,
which **Window ▸ Library** opens filled with what was tried.

### Saved passwords

They are kept the way Chrome and Slack keep theirs. The keychain holds one item,
**WlshareViewer Safe Storage**: a random 256-bit key, made when the first
password is saved. Each saved password is sealed with it (AES-GCM, bound to its
profile) and kept with the profiles in the app's preferences; the password is
never written anywhere in the clear.

One key rather than one keychain item per password is what keeps the keychain
quiet for an app that is ad-hoc signed. Every build is a new signature, and
macOS asks before a new signature reads an item — so a new build asks once, the
first time a saved password is needed, and not once per desktop. Deleting the
item in Keychain Access forgets every saved password at once.

## Checks

```sh
ci/ci.sh                # the Rust core's tests and clippy, then the app build
ci/ci.sh package        # the Release build and the disk image a release ships
ci/ci.sh live           # wlshare-client's session tests, from ../wlshare, against a real wlshare
```

`core/` builds and tests on Linux too, and that is the fast loop: the key and
wheel tables and the ABI are plain Rust, and the session under them — the
protocol, the decoders and the state machine — is `wlshare-client`'s, which has
its own tests in the `wlshare` repo.

## Releasing

Bump `MARKETING_VERSION` in `project.yml`, then run the **Release the macOS app**
workflow by hand (`gh workflow run release.yml --ref main`). It builds and
packages on a runner with `scripts/package-mac.sh`, publishes the disk image and
`SHA256SUMS` as `v<MARKETING_VERSION>`, and creates that tag — a run on any
branch other than `main` is a prerelease instead. A version that already has a
tag is refused.

## Layout

- `core/` — the Rust crate: `wlshare-client`'s session with the Mac key and
  wheel tables and the C ABI in `src/ffi.rs`, behind `include/wlshare_client.h`,
  on top.
- `Sources/WlshareViewer/` — the app: the library, the window, the Metal
  view, the input.
- `scripts/package-mac.sh` — the release build and the disk image; the release
  workflow runs nothing else.
- `docs/architecture.md` — how the two halves fit together, and why.
