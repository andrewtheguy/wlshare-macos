# How the client is put together

A native macOS window onto a [wlshare](https://github.com/andrewtheguy/wlshare)
desktop. Two halves, and the line between them is a C header:

```
  AppKit ──▶ DesktopView ──▶ Client.swift ──▶ wlshare_client.h
                 ▲                                   │
                 │ a frame, a cursor, a state        ▼
                 └────────────── core/ (Rust) ──▶ wlshare-rfb ──▶ the socket
```

`core/` is a Rust crate that owns the socket, the RFB session, the decoders and
the framebuffer they write into. `Sources/WlshareViewer/` is an AppKit app that
owns a window, a Metal texture and the events macOS hands it. The app parses no
protocol and the core knows no AppKit, which is what lets the whole of the first
be unit-tested on a machine that has never seen the second.

Every protocol byte comes from `wlshare-rfb` — the same crate the daemon is
built on, read from the other end. It is a cargo dependency on a released tag of
the `wlshare` repo rather than the sibling checkout, so what this repo builds is
decided by `core/Cargo.toml` and `core/Cargo.lock` and not by the state of
somebody's `../wlshare`. A wire change belongs there, is released from there,
and arrives here as a bumped tag.

## Scope

Screen, keyboard, pointer, retina. The client lists ZRLE, Raw, Cursor, Cursor
With Alpha, DesktopSize, ExtendedDesktopSize, Fence, ContinuousUpdates and the
density extension, and nothing else — so the server never offers audio, camera,
microphone or output selection, and `client::parse` treats a rectangle nobody
asked for as fatal. The clipboard is recognised and dropped.

## Where a session begins

The app is packaged, so the destination cannot only be a command-line argument:
`ConnectWindow` is a form for the host, the port, the user name and the
password, and it is what an app opened from the Finder starts at. `-server` on
the command line skips it, which is what `scripts/run-macos.sh` and anything
automated use.

Only one thing is remembered on purpose. The host, the port and the user name
are preferences; the password goes to the keychain, and only when the checkbox
says so — a `defaults` plist is a file, and a password in one is a password in
plain text. The preference keys are deliberately not `server`, `username` and
`password`: those are the argument names, and `UserDefaults`' argument domain
outranks anything written to the standard one, so a launch with arguments would
otherwise poison what the form reads back.

A session ends where it began. A refused connection, a dropped one and
**Disconnect** all put the form back up with the reason on it, and only then
take the window away — in that order, because an app that is briefly down to no
windows at all is an app that quits itself.

## Threads

`Client::connect` starts one thread with a current-thread tokio runtime on it
and returns before the socket is open. Everything after that is:

- **the session's thread**, which reads the socket, decodes into the
  framebuffer under its lock, and calls the window's wake callback;
- **the main thread**, which draws from the framebuffer under the same lock and
  posts input events to an unbounded channel the session selects on.

Neither waits for the other for longer than a memcpy. The wake callback runs on
the session's thread and must not block, so the Swift side's is one
`DispatchQueue.main.async`; the window is marked dirty and draws when AppKit
next lets it. `MTKView` is paused with `enableSetNeedsDisplay`, because a
desktop that has not changed has nothing to redraw.

Dropping the `Client` clears the callback *before* joining the thread, so
nothing can call into a half-deallocated window. The callback's context is a
small object of its own rather than the `Client`, because clearing and joining
does not reach a redraw that is already sitting on the main queue: that block
holds the context, and the context is let go behind it, by one more block on the
same serial queue.

## Pixels

One format, end to end. The client asks for the server's own — `XRGB8888`, the
bytes `B, G, R, X` — which is `MTLPixelFormat.bgra8Unorm` exactly, so nothing on
the path from the compositor's buffer to the screen swizzles a pixel.

The framebuffer keeps a generation and a damage rectangle. A generation the
window has not seen is a framebuffer of a new size, and its texture is made
again and filled whole; otherwise the damage is uploaded with one
`replace(region:)` and cleared. Damage accumulates as a single covering
rectangle: tracking each rectangle separately would upload less only for a
desktop whose damage is two far-apart specks, which the merging the server
already does makes uncommon.

The desktop is drawn as one textured quad over the drawable. At rest the two are
the same size and every texel lands on its own pixel; the sampler only does
anything in the moment between a window resizing and the desktop following it,
where the picture is fitted and centred rather than stretched.

## Retina

This is the whole of it: the window says what it is, and the desktop becomes
that.

- The window's backing store is `width × height` device pixels at a scale — 2 on
  a retina display. `DesktopView` posts that on every resize and every backing
  change.
- The session asks for a desktop drawn at that scale (`ClientDensity`) and that
  many pixels across (`SetDesktopSize`).
- The framebuffer is then a device-pixel-for-device-pixel match with the window,
  and the remote desktop's own widgets are drawn at the density the display has.

Two things about this were learned the hard way and are worth keeping written
down:

- **The two requests must not be in flight together.** The server applies both
  through wlr-output-management, whose configurations carry a serial the
  compositor bumps on every commit, so the second of two is cancelled and comes
  back as `invalid layout` — a perfectly good size refused for no visible
  reason. The density goes first and the size waits for the `OutputScale` the
  extension promises for every declaration. Recognising *that* answer and not
  the one every `SetEncodings` is answered with is what `Live::released_by`
  is for.
- **The scale and the size must come from the same place.** `postSurface` reads
  both out of `convertToBacking`. Taking the size from there and the scale from
  `window.backingScaleFactor` is wrong for the one call that happens before the
  view has a window: a view with no window still knows its backing store, but
  has no window to ask. That sent a retina window's pixel count with a density
  of 1, and the desktop drew a 2048-pixel-wide picture of a 2048-point desktop —
  sharp, and everything in it half the size it should be.

A resize is coalesced: a live drag posts a size every frame, and each one
honoured would be a compositor mode change and a full repaint, so the session
waits for the drag to settle before asking.

## Input

Pointer positions travel in the window's device pixels and are mapped onto the
framebuffer's, which are the same thing once a resize has landed and briefly not
while one is in flight — exactly when a click must still go where it was aimed.

Keys carry X11 keysyms, and which keysym a Mac key is comes from a table in
`core/src/keysym.rs` rather than from Swift, because a table goes wrong quietly
and a table in Rust has tests. A key that names itself — an arrow, a function
key, a keypad digit, a modifier — is found by its macOS virtual key code; every
other key is the character AppKit already resolved, case included, because the
server takes a character keysym as a character already cased and presses Shift
around the keycode to make it come out that way. Caps Lock is deliberately not
forwarded: the case is already in the keysym, and a latched Caps Lock on the
desktop would apply it twice. A key is released with the keysym it was pressed
with, so letting Shift go first cannot turn an `A` going up into an `a` that was
never down, and the view lets go of everything it holds when it stops being
first responder.

RFB has no scroll event: a wheel notch is a press and release of one of four
buttons above the real three. A Mac has no notches, so `core/src/wheel.rs`
gathers lines or trackpad points into them, keeps the leftovers, throws them
away on a reversal, and caps a flick.

## The pointer's shape

wlshare never paints the pointer into a captured frame, so a client that does
not draw one has no pointer at all. Cursor With Alpha arrives as premultiplied
RGBA, Cursor as pixels and a 1-bit mask, and the core turns either into one
`CursorImage`; an empty rectangle is a pointer that is hidden or on another
output. The shape is in the desktop's pixels, which are the window's backing
pixels, so the `NSCursor` is built at `size / scale` points with its hotspot
scaled to match — and built again when the window moves to a screen of another
density, points being what an `NSCursor` is measured in — and set as the view's
cursor rect, which also takes the local arrow away, or there would be two
pointers on the desktop. The pixels stay premultiplied the whole way, into a
`CGImage` that is told so.

The window keeps its own arrow until the first shape arrives, because until
then there is nothing to say the pointer is anywhere else. After that, a shape
that is gone is the server saying there is no pointer to draw, and the cursor
rect holds an empty image: the framebuffer carries no pointer either, so an
arrow of our own would be one the desktop does not have.

## The C ABI

`core/src/ffi.rs` is the only place in the crate with `unsafe` in it, and it is
a shell: each function turns C arguments into Rust ones, calls one method, and
turns the answer back.

Framebuffer and cursor are read through *callbacks* rather than a lock/unlock
pair, so there is no guard to hold across the boundary and no way to forget to
release one. The callback runs with the lock held and is handed pointers that
live only for that call, which is exactly long enough to upload a texture.

`include/wlshare_client.h` is hand-written, and `tests/header_matches.rs` reads
both it and `src/ffi.rs`, parses each in its own language, and fails if a
function or a struct field differs. A `uint16_t` where the Rust says `u32` links
cleanly and corrupts memory at run time; nothing else would catch it.

## Building

`./build-core.sh` puts `libwlshare_client_core.a` and the header in `dist/`,
which is what `project.yml` points the app's search paths at. There is no
xcframework and no pinned release zip — the pattern `../ezvpn-apple` uses for a
core in another repo — because the core is in *this* repo and has one consumer.
What is pinned is the crate underneath it, by cargo, on a tag.

`ci/ci.sh` runs the jobs; from the Linux checkout `scripts/mac-ci.sh` pushes
this tree, the sibling `../wlshare` and `../devtools` to the Mac and runs them
there. The sibling goes over because the shared scripts expect a core repo
beside this one and because it is what the `--config` patch points at; a build
of the tag as pinned does not read it.

## Shipping

`scripts/package-mac.sh` is the release build: the core, `xcodegen`, an Xcode
Release build, and `hdiutil` wrapping the bundle and an `/Applications` symlink
into a disk image. `.github/workflows/release.yml` runs that one script on a
macOS runner and publishes what it leaves in `dist/package/`, so the image a
release carries is the image anyone can build — the workflow adds the tag and
the release, not a different build.

Two things it deliberately does not do. It does not sign with a Developer ID or
notarize: there is no certificate, so the bundle is ad-hoc signed, which is only
as much as an arm64 binary needs to run at all, and the README carries the
quarantine workaround that costs. And it does not parse `project.yml` for the
version — it reads `CFBundleShortVersionString` back out of the bundle it just
built, so the tag `v<version>` names what actually shipped rather than what the
generator was asked for. `MARKETING_VERSION` is the one literal, and the plist
names it explicitly: xcodegen's default for that key is a flat `1.0` that
ignores the setting entirely, which is exactly the kind of mismatch reading the
version back out of the bundle turns into a visible one.
