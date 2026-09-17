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
- Rust, and a sibling checkout of `wlshare` at `../wlshare`: the core links its
  `wlshare-rfb` crate, which is where every protocol byte comes from.

## Running it

```sh
scripts/run-macos.sh 192.168.1.10:5900          # a server with no password
scripts/run-macos.sh 192.168.1.10:5900 secret   # one that wants RSA-AES
```

That builds the core, generates the project, builds the app and opens it. The
app takes its arguments the same way by hand:

```sh
WlshareViewer.app/Contents/MacOS/WlshareViewer -server host:port -password secret
```

An empty password asks for the `None` security type; anything else asks for
RSA-AES, which is the only type this client authenticates with — and the one
that encrypts the session.

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
- `Sources/WlshareViewer/` — the app: the window, the Metal view, the input.
- `docs/architecture.md` — how the two halves fit together, and why.
