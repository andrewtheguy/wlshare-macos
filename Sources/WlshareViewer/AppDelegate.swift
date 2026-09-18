import AppKit
import Metal

/// The connect form, the window behind it, and the session between them.
/// Everything that is about the desktop is in `DesktopView`; everything about
/// the wire is in the Rust core.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var device: MTLDevice?
    private var window: NSWindow?
    private var view: DesktopView?
    private var client: Client?
    private var clipboard: ClipboardSync?
    private var audio: AudioOutput?
    private let banner = NSTextField(labelWithString: "")
    private let form = ConnectWindow()
    /// The last destination tried, which is what the form comes back filled
    /// with — including a password that was typed but not remembered, so a
    /// connection that failed for some other reason can be retried as it is.
    private var last: Destination?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return fail("this Mac has no Metal device")
        }
        self.device = device

        banner.alignment = .center
        banner.textColor = .white
        banner.translatesAutoresizingMaskIntoConstraints = false
        form.onConnect = { [weak self] destination in self?.open(destination) }

        makeMenu()
        // The moments the desktop window becomes the one in use, which is when
        // the Mac's clipboard is offered to the desktop.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(inUse), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(inUse), name: NSWindow.didBecomeKeyNotification, object: nil)
        NSApp.setActivationPolicy(.regular)
        // A launch from a shell says where to go; a launch from the Finder asks.
        if let destination = Destination.fromArguments() {
            open(destination)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            ask()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ends the session and joins its thread while there is still a window
        // for its callbacks to have reached.
        audio?.stop()
        audio = nil
        client = nil
    }

    // MARK: - A session

    private func open(_ destination: Destination) {
        guard let device else { return }
        close()
        last = destination

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = destination.label
        // A window made this way frees itself on close, which under ARC is one
        // release too many the moment anything still holds it — and this holds
        // it, because closing it is something the app does rather than only the
        // person using it.
        window.isReleasedWhenClosed = false
        window.center()
        // The next session opens at the size the last one was left at.
        window.setFrameAutosaveName("desktop")
        self.window = window

        // The first surface is the window's own size, so the desktop is asked
        // to match before the first frame rather than after it.
        let backing = window.convertToBacking(NSRect(origin: .zero, size: window.contentLayoutRect.size)).size
        let client = Client(
            host: destination.host,
            port: destination.port,
            username: destination.username,
            password: destination.password,
            audio: destination.audio,
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

        client.onChange = { [weak self] in self?.changed() }
        changed()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// Put the session and its window away. Nothing here quits the app on its
    /// own: the caller has already brought the form up, and a window closed
    /// while another is on screen is not the last one.
    private func close() {
        clipboard = nil
        // Before the client: the audio device's thread reads from it until the
        // engine has stopped.
        audio?.stop()
        audio = nil
        client = nil
        banner.removeFromSuperview()
        // Ordered out rather than closed: `close()` runs the window out with an
        // animation, and a window taken apart underneath one leaves its last
        // frame on the screen for good.
        window?.orderOut(nil)
        window?.contentView = nil
        view = nil
        window = nil
    }

    /// The session has something new: a frame, a size, a state. Called on the
    /// main queue.
    private func changed() {
        guard let client, let window, let view else { return }
        let status = client.status
        switch status.state {
        case .connecting:
            banner.stringValue = "Connecting to \(window.title)…"
        case .ready:
            banner.stringValue = ""
            let name = status.name.isEmpty ? window.title : status.name
            window.title = "\(name) — \(status.desktop.width)×\(status.desktop.height) @ \(scale(status.scale))"
            // Not before the server has said it has sound: a session without it
            // keeps the Mac's audio device out of it.
            if status.audio, audio == nil {
                audio = AudioOutput(client: client)
            }
        case .closed:
            // Back to the form with the reason on it, and only then take the
            // window away, so the app is never down to no windows at all.
            ask(error: status.error ?? "The connection closed.")
            return close()
        }
        banner.isHidden = banner.stringValue.isEmpty
        clipboard?.take()
        view.needsDisplay = true
    }

    /// The app came to the front, or a window became key: if it is the
    /// desktop's, and the app is the one in front, the desktop may now be
    /// pasted into.
    @objc private func inUse() {
        guard NSApp.isActive, let window, window.isKeyWindow else { return }
        clipboard?.offer()
    }

    private func scale(_ scale: Double) -> String {
        scale == scale.rounded() ? "\(Int(scale))×" : String(format: "%.2f×", scale)
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func ask(error: String? = nil) {
        form.show(last ?? Destination.remembered(), error: error)
    }

    @objc private func askWhereToConnect() {
        ask()
    }

    @objc private func disconnect() {
        ask()
        close()
    }

    /// The smallest menu that makes the app behave like one: without it there
    /// is no ⌘Q, and every key the desktop does not want is a beep.
    private func makeMenu() {
        let root = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Hide WlshareViewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit WlshareViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Connect…", action: #selector(askWhereToConnect), keyEquivalent: "n")
        file.addItem(withTitle: "Disconnect", action: #selector(disconnect), keyEquivalent: "d")
        for item in file.items { item.target = self }

        for menu in [app, file] {
            let item = NSMenuItem()
            item.title = menu.title
            item.submenu = menu
            root.addItem(item)
        }
        NSApp.mainMenu = root
    }
}
