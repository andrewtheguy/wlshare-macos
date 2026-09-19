# wlshare-macos — repository instructions

A native macOS client for the [`wlshare`](https://github.com/andrewtheguy/wlshare)
VNC server, built against a released `wlshare-client` — the Rust session that
repo holds for both native clients. The sibling of `../wlshare-windows`, with
the same session under it.

- Strict no backward-compatibility or legacy paths no matter what.
- **macOS only.** No iOS target, no Simulator, no OTA install — the pieces
  `../ezvpn-apple` carries for those do not belong here.
- Two halves: `core/` is the Rust crate (`wlshare-client-core`) —
  `wlshare-client`'s session with what is the Mac's on top: the key and wheel
  tables and the C ABI — and `Sources/` is the AppKit app that puts it in a
  window. The app never parses a protocol byte.
- **The session is `wlshare-client`'s, and every protocol byte `wlshare-rfb`'s**,
  both in `../wlshare`. A change to how the session behaves — the handshake,
  resizing, decoding, the clipboard, the sound — belongs in
  `../wlshare/crates/wlshare-client`, where the Windows app gets it too, and a
  wire change in `../wlshare/crates/wlshare-rfb`; neither belongs here.
- **The dependency is a pinned release tag** of `wlshare-client`, which
  re-exports `wlshare-rfb`, not the sibling checkout, so a
  build does not depend on what happens to be in `../wlshare` — `core/Cargo.toml`
  names the tag and `core/Cargo.lock` the revision. A session or wire change
  therefore lands in `../wlshare`, is released from there, and the tag is bumped here in
  its own commit. To build against one before it is released, pass the `--config`
  patch `core/Cargo.toml` spells out rather than editing the dependency.
- After Rust changes run `cargo test` and `cargo clippy --all-targets -- -D warnings`
  in `core/`, and clippy again with `--target aarch64-apple-darwin` for the real
  target. Do not run `cargo fmt`. Use `anyhow` for application errors and
  `thiserror` for typed ones.
- The session is in `../wlshare` rather than here because the Windows app runs
  the same one, and a fix made twice drifts. What stays here is only what is
  the Mac's. There is still no xcframework or pinned release zip — the pin is a
  cargo one on the crate, not a downloaded artefact: one `./build-core.sh`, a
  static library the app target links directly.
- The live tests against a real wlshare are `wlshare-client`'s, in
  `../wlshare/crates/wlshare-client/tests/live_session.rs`, and `ci/ci.sh live`
  runs them from there — see CLAUDE.local.md for the container and the tunnel
  that provide a server.
- **Packaging is one script.** `scripts/package-mac.sh` builds Release and makes
  the drag-to-Applications `.dmg`, and `.github/workflows/release.yml` runs that
  and nothing else before publishing `v<MARKETING_VERSION>`. A change to how the
  app is packaged belongs in the script, never only in the workflow. Nothing is
  Developer-ID signed or notarized; ad-hoc signing is deliberate, not a to-do.
- Design and wire details live in `docs/architecture.md`, not here.
