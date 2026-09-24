import AppKit
import Metal

/// The library and the desktops opened from it.
///
/// Every connection is a `Session` of its own — its own window, its own
/// socket, its own sound — and the app keeps as many as have been opened.
/// **Connect** adds one beside the library, which stays where it is; it never
/// takes one away. There is one library window, brought forward rather than
/// made again. Everything that is about a desktop is in `Session` and
/// `DesktopView`; everything about the wire is in the Rust core.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var device: MTLDevice?
    /// The sessions on the screen, oldest first.
    private var sessions: [Session] = []
    private let profiles = ProfileStore()
    private lazy var library = ConnectWindow(profiles: profiles)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return fail("this Mac has no Metal device")
        }
        self.device = device

        library.onConnect = { [weak self] destination, profile in self?.open(destination, profile: profile) }

        makeMenu()
        // The moments a desktop window becomes the one in use, which is when
        // the Mac's clipboard is offered to that desktop.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(inUse), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(inUse), name: NSWindow.didBecomeKeyNotification, object: nil)
        NSApp.setActivationPolicy(.regular)
        // A launch from a shell says where to go; a launch from the Finder asks.
        if var destination = Destination.fromArguments() {
            // The password saved for the same place and user, if any. One that
            // will not open is not tried as none: the form says why, and is
            // where it is typed.
            let profile = profiles.profile(matching: destination)
            do {
                destination.password = try profile?.password() ?? ""
            } catch {
                library.load(destination, profile: profile?.id)
                return ask(error: error.localizedDescription)
            }
            library.load(destination, profile: profile?.id)
            open(destination, profile: profile?.id)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            ask()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Not while the library holds something that cannot be saved: it stays
    /// up with the reason, as it does when its own window is closed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        library.save() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ends every session and joins its thread while there is still a window
        // for its callbacks to have reached.
        for session in sessions {
            session.end()
        }
    }

    // MARK: - Sessions

    /// Open a desktop in a window of its own, beside whatever is already open.
    private func open(_ destination: Destination, profile: UUID?) {
        guard let device else { return }
        let session = Session(destination: destination, profile: profile, device: device)
        session.onClosed = { [weak self] session, reason in
            // The library first, with which desktop it is about, and only then
            // the window away — in that order, because an app briefly down to
            // no windows at all is an app that quits itself.
            self?.ask(error: "\(session.destination.label): \(reason)")
            session.end()
        }
        session.onEnded = { [weak self] session in
            self?.sessions.removeAll { $0 === session }
        }
        sessions.append(session)
        session.show()
    }

    /// The app came to the front, or a window became key: if it is a desktop's,
    /// and the app is the one in front, that desktop may now be pasted into.
    @objc private func inUse(_ notification: Notification) {
        guard NSApp.isActive else { return }
        let window = notification.object as? NSWindow ?? NSApp.keyWindow
        guard let window, window.isKeyWindow else { return }
        sessions.first { $0.window === window }?.offerClipboard()
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func ask(error: String? = nil) {
        library.show(error: error)
    }

    /// **Window ▸ Library**: the one library window, forward.
    @objc private func showLibrary() {
        ask()
    }

    /// Close the desktop in front. With nothing else on the screen the library
    /// goes up first, so the app is never down to no windows at all.
    @objc private func disconnect() {
        guard let session = sessions.first(where: { $0.window.isKeyWindow }) else { return }
        if sessions.count == 1 { ask() }
        session.end()
    }

    /// **Disconnect** is about the desktop in front, and there is not always
    /// one: the library may be what has the keyboard.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(disconnect) else { return true }
        return sessions.contains { $0.window.isKeyWindow }
    }

    /// The smallest menu that makes the app behave like one, and the app's
    /// only way in once the desktop has the keyboard: the view claims every
    /// chord while it is first responder, so these items are clicked rather
    /// than typed until the library is the window in use.
    private func makeMenu() {
        let root = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Hide WlshareViewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit WlshareViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Disconnect", action: #selector(disconnect), keyEquivalent: "d")
        for item in file.items { item.target = self }

        // The library's fields take ⌘C and the rest only through this menu: a
        // text field has no key equivalents of its own. The items have no
        // target, so they go to whatever has the keyboard.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Several desktops at once need a way between them: AppKit keeps the
        // open windows listed under this one, to be clicked like the rest of
        // the menu bar while a desktop holds the keyboard. The library is the
        // app's one window that is not a desktop, and this is where a Mac app
        // keeps such a window: it is brought forward from here, not connected.
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        windows.addItem(withTitle: "Library", action: #selector(showLibrary), keyEquivalent: "l").target = self
        windows.addItem(.separator())

        for menu in [app, file, edit, windows] {
            let item = NSMenuItem()
            item.title = menu.title
            item.submenu = menu
            root.addItem(item)
        }
        NSApp.mainMenu = root
        NSApp.windowsMenu = windows
    }
}
