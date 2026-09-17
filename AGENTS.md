# wlshare-macos — repository instructions

A native macOS client for the [`wlshare`](https://github.com/andrewtheguy/wlshare)
VNC server. Sibling of `../wlshare`, which holds the shared Rust library.

- Strict no backward-compatibility or legacy paths no matter what.
- **macOS only.** No iOS target, no Simulator, no OTA install — the pieces
  `../ezvpn-apple` carries for those do not belong here.
- Two halves: `core/` is the Rust crate (`wlshare-client-core`) that speaks the
  whole session and owns the framebuffer, and `Sources/` is the AppKit app that
  puts it in a window. The app never parses a protocol byte.
- **Every protocol byte comes from `wlshare-rfb`**, the sibling's crate, exactly
  as the daemon does it: `core/` turns window events into calls on that crate
  and copies the results to the framebuffer, and writes no wire format of its
  own. A wire change belongs in `../wlshare/crates/wlshare-rfb`, not here.
- After Rust changes run `cargo test` and `cargo clippy --all-targets -- -D warnings`
  in `core/`. Do not run `cargo fmt`. Use `anyhow` for application errors and
  `thiserror` for typed ones.
- The Rust core is in this repo rather than the sibling because `../wlshare` is a
  Linux daemon repo whose two crates are the daemon and the protocol; an Apple
  client's session logic is neither. That is also why there is no xcframework or
  pinned release zip: one repo, one `./build-core.sh`, a static library the app
  target links directly.
- `core/tests/live_session.rs` is `#[ignore]`d and needs a real wlshare to talk
  to — see CLAUDE.local.md for the container and the tunnel that provide one.
- Design and wire details live in `docs/architecture.md`, not here.
