import AppKit
import Metal

/// One connection, in a window of its own: the desktop on the screen, the
/// session behind it, the Mac's clipboard and the desktop's sound.
///
/// A window is a session and a session is a window — several stand side by
/// side, each with its own socket, its own decoders and its own sound, and
/// none of them knows about the others. What is shared between them is the
/// list of saved desktops and the form over it, which is `ConnectWindow`'s.
///
/// The session is made when the window is, so the desktop is asked for the
/// window's size before the first frame rather than after it. It ends when the
/// window closes, and the client's thread is joined while the window is still
/// there for its callbacks to have reached.
@MainActor
final class Session: NSObject, NSWindowDelegate {
    /// Where this one went, for its title and for saying which desktop a
    /// reason belongs to.
    let destination: Destination
    let window: NSWindow

    private var client: Client?
    private var view: DesktopView?
    private var clipboard: ClipboardSync?
    private var audio: AudioOutput?
    private let banner = NSTextField(labelWithString: "")

    /// The connection ended by itself — refused, or dropped — with the reason.
    /// The session is still whole when this is called; ending it is the
    /// delegate's, which has somewhere to put the reason first.
    var onClosed: ((Session, String) -> Void)?
    /// The session is over and its window gone, by whatever hand. The delegate
    /// holds the only reference left, and this is where it lets go.
    var onEnded: ((Session) -> Void)?

    /// Where the next window that has no place of its own goes, so two
    /// desktops opened at once do not land exactly on top of each other.
    private static var cascade = NSPoint.zero

    init(destination: Destination, profile: UUID?, device: MTLDevice) {
        self.destination = destination
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = destination.label
        // A window made this way frees itself on close, which under ARC is one
        // release too many the moment anything still holds it — and this holds
        // it, because closing it is something the app does rather than only the
        // person using it.
        window.isReleasedWhenClosed = false
        window.center()
        // A desktop opens where it was last left, under the profile it was
        // connected from. Taking the name only says no other window has it —
        // AppKit gives a frame name to one window at a time — and there is a
        // frame under it only once that profile has been left somewhere. A
        // window with no place of its own cascades off the one before it, and a
        // window that has one is where the next cascade starts, so a desktop
        // opened twice does not land on itself. Cascading from `.zero` moves
        // nothing; it only reads the window's own top-left.
        let name = profile.map { "desktop-\($0.uuidString)" }
        if let name, window.setFrameAutosaveName(name), window.setFrameUsingName(name) {
            Self.cascade = window.cascadeTopLeft(from: .zero)
        } else {
            Self.cascade = window.cascadeTopLeft(from: Self.cascade)
        }
        window.delegate = self

        banner.alignment = .center
        banner.textColor = .white
        banner.translatesAutoresizingMaskIntoConstraints = false

        // The first surface is the window's own size, so the desktop is asked
        // to match before the first frame rather than after it.
        let backing = window.convertToBacking(NSRect(origin: .zero, size: window.contentLayoutRect.size)).size
        let client = Client(
            host: destination.host,
            port: destination.port,
            username: destination.username,
            password: destination.password,
            audio: destination.audio,
            encoding: destination.encoding,
            surface: Client.Surface(
                width: UInt16(clamping: Int(backing.width)),
                height: UInt16(clamping: Int(backing.height)),
                scale: Double(window.backingScaleFactor)
            )
        )
        self.client = client
        clipboard = ClipboardSync(client: client)

        let view = DesktopView(client: client, device: device)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        self.view = view

        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    /// Put the window on the screen with the desktop ready for the keyboard,
    /// and start listening to the session. Called once the delegate has been
    /// given its callbacks, so a connection refused before that has somewhere
    /// to be reported.
    func show() {
        client?.onChange = { [weak self] in self?.changed() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        changed()
    }

    /// Put the session and its window away — for the app, which has already
    /// brought the form up. The person closing the window takes the other
    /// path, through `windowWillClose`.
    func end() {
        // The delegate goes first: the window is not closed here, and nothing
        // should come back through it after this.
        window.delegate = nil
        stop()
        // Ordered out rather than closed: `close()` runs the window out with an
        // animation, and a window taken apart underneath one leaves its last
        // frame on the screen for good.
        window.orderOut(nil)
        window.contentView = nil
        view = nil
        // Held for the length of the call: the app is about to let go of the
        // only reference there is to this.
        withExtendedLifetime(self) { onEnded?(self) }
    }

    /// Give the desktop the Mac's clipboard: this window is the one in use.
    func offerClipboard() {
        clipboard?.offer()
    }

    /// The window lost the keyboard — to another desktop, or to the app going
    /// behind. The first responder does not change when that happens, so this
    /// is the only place the keys and buttons held down here are let go of.
    func windowDidResignKey(_ notification: Notification) {
        view?.releaseInput()
    }

    /// The person closed the window. The session goes with it, and the app is
    /// told so it can let go.
    func windowWillClose(_ notification: Notification) {
        stop()
        // An `NSWindow` holds its delegate weakly, so the app's list is the
        // only reference left — and this is what empties it. Held for the
        // length of the call rather than freed in the middle of it.
        withExtendedLifetime(self) { onEnded?(self) }
    }

    /// Everything that is alive in a session, in the order it has to go: the
    /// sound before the client, because the audio device's thread reads from
    /// it until the engine has stopped, and the client last, which joins its
    /// thread so nothing calls back afterwards.
    private func stop() {
        clipboard = nil
        audio?.stop()
        audio = nil
        client = nil
        banner.removeFromSuperview()
    }

    /// The session has something new: a frame, a size, a state. Called on the
    /// main queue.
    private func changed() {
        guard let client, let view else { return }
        let status = client.status
        switch status.state {
        case .connecting:
            banner.stringValue = "Connecting to \(destination.label)…"
        case .ready:
            banner.stringValue = ""
            let name = status.name.isEmpty ? destination.label : status.name
            // A VP9 session is VP9 or nothing: a server without it ends it.
            let encoding = destination.encoding == .vp9 ? " · VP9" : ""
            window.title = "\(name) — \(status.desktop.width)×\(status.desktop.height) @ \(scale(status.scale))\(encoding)"
            // Not before the server has said it has sound: a session without it
            // keeps the Mac's audio device out of it.
            if status.audio, audio == nil {
                audio = AudioOutput(client: client)
            }
        case .closed:
            onClosed?(self, status.error ?? "The connection closed.")
            return
        }
        banner.isHidden = banner.stringValue.isEmpty
        clipboard?.take()
        view.needsDisplay = true
    }

    private func scale(_ scale: Double) -> String {
        scale == scale.rounded() ? "\(Int(scale))×" : String(format: "%.2f×", scale)
    }
}
