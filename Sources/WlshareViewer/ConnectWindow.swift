import AppKit

/// Where a packaged app starts: a form for the host, the port, the user name
/// and the password, for someone who opened the app from the Finder and has no
/// command line to put them on.
///
/// It is also where a session ends up — a refused or dropped connection brings
/// this back with the reason on it, so there is somewhere to correct and retry.
@MainActor
final class ConnectWindow: NSObject, NSWindowDelegate {
    /// Called with a destination that parsed, after the form has put itself
    /// away. Everything about the session is the delegate's business.
    var onConnect: ((Destination) -> Void)?

    private let panel = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let host = NSTextField()
    private let port = NSTextField()
    private let username = NSTextField()
    private let password = NSSecureTextField()
    private let remember = NSButton(checkboxWithTitle: "Remember the password", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "")

    override init() {
        super.init()

        host.placeholderString = "hostname or address"
        port.placeholderString = "5900"
        username.placeholderString = "optional"
        password.placeholderString = "none"
        for field in [host, port, username, password] {
            field.widthAnchor.constraint(equalToConstant: 220).isActive = true
            // ⏎ in any field is Connect, which is what the button says too.
            // `self.connect` names the method: `connect` is also the button,
            // declared further down this initialiser.
            field.target = self
            field.action = #selector(self.connect)
        }

        message.textColor = .systemRed
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 2
        message.isHidden = true

        let form = NSGridView(views: [
            [label("Host:"), host],
            [label("Port:"), port],
            [label("User name:"), username],
            [label("Password:"), password],
            [NSGridCell.emptyContentView, remember],
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowAlignment = .firstBaseline

        let connect = NSButton(title: "Connect", target: self, action: #selector(self.connect))
        connect.keyEquivalent = "\r"
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let buttons = NSStackView(views: [NSView(), quit, connect])
        buttons.spacing = 12

        let stack = NSStackView(views: [form, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        message.widthAnchor.constraint(equalTo: buttons.widthAnchor).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        panel.title = "Connect to a Desktop"
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    /// Bring the form up filled with `destination`, and with `error` on it if
    /// this is the second attempt at something.
    func show(_ destination: Destination, error: String? = nil) {
        host.stringValue = destination.host
        port.stringValue = String(destination.port)
        username.stringValue = destination.username
        password.stringValue = destination.password
        remember.state = destination.remember ? .on : .off
        message.stringValue = error ?? ""
        message.isHidden = error == nil

        panel.makeKeyAndOrderFront(nil)
        // The first empty field is where typing should start: a remembered
        // destination usually wants only the password, or nothing at all.
        let first = [host, port, username, password].first { $0.stringValue.isEmpty } ?? host
        panel.makeFirstResponder(first)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Out of the way, not closed: a window that is merely hidden does not
    /// count as the last one, so putting it away cannot quit the app.
    func hide() {
        panel.orderOut(nil)
    }

    @objc private func connect() {
        let host = self.host.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return fail("A host is needed.", self.host) }
        let text = port.stringValue.trimmingCharacters(in: .whitespaces)
        guard let port = text.isEmpty ? 5900 : UInt16(text), port > 0 else {
            return fail("A port is a number from 1 to 65535.", self.port)
        }

        let destination = Destination(
            host: host,
            port: port,
            username: username.stringValue,
            password: password.stringValue,
            remember: remember.state == .on
        )
        destination.save()
        hide()
        onConnect?(destination)
    }

    private func fail(_ reason: String, _ field: NSTextField) {
        message.stringValue = reason
        message.isHidden = false
        panel.makeFirstResponder(field)
    }
}
