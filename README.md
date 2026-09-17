# wlshare-macos

A native macOS client for the [`wlshare`](https://github.com/andrewtheguy/wlshare)
VNC server: an AppKit window drawing a Metal texture, over a Rust core that
speaks the whole RFB session.

**Scope:** the screen, the keyboard, the pointer, and retina. The desktop is
asked to be exactly the window's backing store, drawn at the window's density,
so what is on screen is one device pixel per desktop pixel and never resampled.
Audio, camera, microphone, clipboard and picking an output are wlshare
extensions this client does not speak.

macOS only, Apple Silicon only. There is no iOS target.

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
scripts/run-macos.sh 192.168.1.10:5900          # a server with no password
scripts/run-macos.sh 192.168.1.10:5900 secret   # one that wants RSA-AES
```

That builds the core, generates the project, builds the app and opens it. The
app takes the same words by hand:

```sh
WlshareViewer.app/Contents/MacOS/WlshareViewer -server host:port -password secret
```

## Checks

```sh
ci/ci.sh                # the Rust core's tests and clippy, then the app build
ci/ci.sh live           # the session tests, against a real wlshare
```

`core/` builds and tests on Linux too, and that is the fast loop: the protocol,
the decoders and the session state machine have nothing Apple in them.

## Layout

- `core/` — the Rust crate: session, framebuffer, keysym and wheel tables, and
  the C ABI in `src/ffi.rs` behind `include/wlshare_client.h`.
- `Sources/WlshareViewer/` — the app: the connect form, the window, the Metal
  view, the input.
- `docs/architecture.md` — how the two halves fit together, and why.
