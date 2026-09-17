# wlshare-macos — repository instructions

A native macOS client for the [`wlshare`](https://github.com/andrewtheguy/wlshare)
VNC server, built against a released `wlshare-rfb` — the shared Rust library
that repo holds.

- Strict no backward-compatibility or legacy paths no matter what.
- **macOS only.** No iOS target, no Simulator, no OTA install — the pieces
  `../ezvpn-apple` carries for those do not belong here.
- Two halves: `core/` is the Rust crate (`wlshare-client-core`) that speaks the
  whole session and owns the framebuffer, and `Sources/` is the AppKit app that
  puts it in a window. The app never parses a protocol byte.
- **Every protocol byte comes from `wlshare-rfb`**, exactly as the daemon does
  it: `core/` turns window events into calls on that crate and copies the
  results to the framebuffer, and writes no wire format of its own. A wire
  change belongs in `../wlshare/crates/wlshare-rfb`, not here.
- **The dependency is a pinned release tag**, not the sibling checkout, so a
  build does not depend on what happens to be in `../wlshare` — `core/Cargo.toml`
  names the tag and `core/Cargo.lock` the revision. A wire change therefore
  lands in `../wlshare`, is released from there, and the tag is bumped here in
  its own commit. To build against one before it is released, pass the `--config`
  patch `core/Cargo.toml` spells out rather than editing the dependency.
- After Rust changes run `cargo test` and `cargo clippy --all-targets -- -D warnings`
  in `core/`. Do not run `cargo fmt`. Use `anyhow` for application errors and
  `thiserror` for typed ones.
- The Rust core is in this repo rather than the sibling because `../wlshare` is a
  Linux daemon repo whose two crates are the daemon and the protocol; an Apple
  client's session logic is neither. That is also why there is no xcframework or
  pinned release zip — the pin here is a cargo one on the crate, not a
  downloaded artefact: one repo, one `./build-core.sh`, a static library the app
  target links directly.
- `core/tests/live_session.rs` is `#[ignore]`d and needs a real wlshare to talk
  to — see CLAUDE.local.md for the container and the tunnel that provide one.
- **Packaging is one script.** `scripts/package-mac.sh` builds Release and makes
  the drag-to-Applications `.dmg`, and `.github/workflows/release.yml` runs that
  and nothing else before publishing `v<MARKETING_VERSION>`. A change to how the
  app is packaged belongs in the script, never only in the workflow. Nothing is
  Developer-ID signed or notarized; ad-hoc signing is deliberate, not a to-do.
- Design and wire details live in `docs/architecture.md`, not here.
