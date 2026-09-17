import AppKit
import Metal

/// The window, the connection behind it, and nothing else. Everything that is
/// about the desktop is in `DesktopView`; everything about the wire is in the
/// Rust core.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var view: DesktopView?
    private var client: Client?
    private let banner = NSTextField(labelWithString: "")

    /// Where to connect, from the command line:
    ///
    ///     WlshareViewer -server 127.0.0.1:5999 -password secret
    ///
    /// `UserDefaults` reads `-key value` pairs off the argument list, so the
    /// same words work through `open --args`.
    private struct Arguments {
        var host: String
        var port: UInt16
        var username: String
        var password: String

        init() {
            let defaults = UserDefaults.standard
            let server = defaults.string(forKey: "server") ?? "127.0.0.1:5900"
            let (host, port) = Self.split(server)
            self.host = host
            self.port = port
            username = defaults.string(forKey: "username") ?? ""
            password = defaults.string(forKey: "password") ?? ""
        }

        /// `host:port`, `host`, or an IPv6 literal in brackets.
        static func split(_ server: String) -> (String, UInt16) {
            if server.hasPrefix("["), let end = server.firstIndex(of: "]") {
                let host = String(server[server.index(after: server.startIndex)..<end])
                let rest = server[server.index(after: end)...]
                return (host, UInt16(rest.dropFirst()) ?? 5900)
            }
            guard let colon = server.lastIndex(of: ":"), let port = UInt16(server[server.index(after: colon)...]) else {
                return (server, 5900)
            }
            return (String(server[..<colon]), port)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return fail("this Mac has no Metal device")
        }
        let arguments = Arguments()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(arguments.host):\(arguments.port)"
        window.center()
        window.setFrameAutosaveName("desktop")
        self.window = window

        // The first surface is the window's own size, so the desktop is asked
        // to match before the first frame rather than after it.
        let backing = window.convertToBacking(NSRect(origin: .zero, size: window.contentLayoutRect.size)).size
        let client = Client(
            host: arguments.host,
            port: arguments.port,
            username: arguments.username,
            password: arguments.password,
            surface: Client.Surface(
                width: UInt16(clamping: Int(backing.width)),
                height: UInt16(clamping: Int(backing.height)),
                scale: Double(window.backingScaleFactor)
            )
        )
        self.client = client

        let view = DesktopView(client: client, device: device)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        self.view = view

        banner.alignment = .center
        banner.textColor = .white
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        client.onChange = { [weak self] in self?.changed() }
        changed()

        makeMenu()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ends the session and joins its thread while there is still a window
        // for its callbacks to have reached.
        client = nil
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
        case .closed:
            banner.stringValue = status.error.map { "Disconnected: \($0)" } ?? "Disconnected"
        }
        banner.isHidden = banner.stringValue.isEmpty
        view.needsDisplay = true
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

    /// The smallest menu that makes the app behave like one: without it there
    /// is no ⌘Q, and every key the desktop does not want is a beep.
    private func makeMenu() {
        let root = NSMenu()
        let item = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Hide WlshareViewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit WlshareViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app
        root.addItem(item)
        NSApp.mainMenu = root
    }
}
