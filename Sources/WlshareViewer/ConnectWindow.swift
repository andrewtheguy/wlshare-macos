import AppKit

/// Where a packaged app starts: the saved desktops as a list, and a form for
/// the one selected — its name, the host, the port, the user name, the
/// password and the encoding — for someone who opened the app from the Finder
/// and has no command line to put them on.
///
/// Every connection made here is to a profile. **Connect** saves the form into
/// the selected one first, and with nothing selected makes a new one of it, so
/// a desktop connected to once is in the list from then on; **+** starts an
/// empty one and **−** deletes one. What is typed into the form is saved when
/// the selection moves, on **Connect**, and when the window or the app closes.
///
/// It is also where a session ends up — a refused or dropped connection brings
/// this back with the reason on it and the form as it was, password included,
/// so there is somewhere to correct and retry.
@MainActor
final class ConnectWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// Called with a destination that parsed and the profile it was saved as,
    /// after the form has put itself away. Everything about the session is the
    /// delegate's business.
    var onConnect: ((Destination, UUID) -> Void)?

    private let profiles: ProfileStore
    /// The profile the form is showing; nil for a desktop not saved yet.
    private var current: UUID?

    private let panel = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let table = NSTableView()
    private let add = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: nil, action: nil)
    private let remove = NSButton(image: NSImage(named: NSImage.removeTemplateName)!, target: nil, action: nil)
    private let name = NSTextField()
    private let host = NSTextField()
    private let port = NSTextField()
    private let username = NSTextField()
    private let password = NSSecureTextField()
    /// VP9 first, because it is the default; the order is the tags'.
    private let encoding = NSPopUpButton(frame: .zero, pullsDown: false)
    private static let encodings: [(Encoding, String)] = [
        (.vp9, "VP9 4:4:4"),
        (.zrle, "ZRLE (exact, larger)"),
    ]
    private let savesPassword = NSButton(checkboxWithTitle: "Save the password", target: nil, action: nil)
    private let audio = NSButton(checkboxWithTitle: "Play the desktop's sound", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var form: NSGridView!

    init(profiles: ProfileStore) {
        self.profiles = profiles
        super.init()

        let column = NSTableColumn(identifier: ProfileCell.identifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 36
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connectClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 210).isActive = true

        for button in [add, remove] {
            button.bezelStyle = .smallSquare
            button.target = self
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        add.action = #selector(addProfile)
        remove.action = #selector(removeProfile)
        add.toolTip = "New desktop"
        remove.toolTip = "Delete this desktop"
        let bar = NSStackView(views: [add, remove, NSView()])
        bar.spacing = 0

        let list = NSStackView(views: [scroll, bar])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0

        name.placeholderString = "the host, if none"
        host.placeholderString = "hostname or address"
        port.placeholderString = "5900"
        username.placeholderString = "optional"
        for field in [name, host, port, username, password] {
            field.widthAnchor.constraint(equalToConstant: 220).isActive = true
            // ⏎ in any field is Connect, which is what the button says too.
            // `self.connect` names the method: `connect` is also the button,
            // declared further down this initialiser.
            field.target = self
            field.action = #selector(self.connect)
        }

        for (index, (_, title)) in Self.encodings.enumerated() {
            encoding.addItem(withTitle: title)
            encoding.lastItem?.tag = index
        }

        message.textColor = .systemRed
        message.maximumNumberOfLines = 3
        message.isHidden = true
        // Wrapped to the form's width rather than widening the window.
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let form = NSGridView(views: [
            [label("Name:"), name],
            [label("Host:"), host],
            [label("Port:"), port],
            [label("User name:"), username],
            [label("Password:"), password],
            [label("Encoding:"), encoding],
            [NSGridCell.emptyContentView, savesPassword],
            [NSGridCell.emptyContentView, audio],
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowAlignment = .firstBaseline
        self.form = form

        let connect = NSButton(title: "Connect", target: self, action: #selector(self.connect))
        connect.keyEquivalent = "\r"
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let buttons = NSStackView(views: [NSView(), quit, connect])
        buttons.spacing = 12

        let details = NSStackView(views: [form, message, buttons])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 16
        buttons.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        message.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true

        let stack = NSStackView(views: [list, details])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The list is as tall as the form beside it, and scrolls past that.
        list.heightAnchor.constraint(equalTo: details.heightAnchor).isActive = true

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

        select(profiles.selected.flatMap { profiles.profile($0) }?.id ?? profiles.profiles.first?.id)
        if current == nil { fill(Profile()) }
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    /// Fill the form with a destination from the command line, before it is
    /// ever shown: the profile it matched if there is one, or a desktop not
    /// saved yet. A connection refused brings this back as it was tried —
    /// with the command line's sound and encoding, not the profile's.
    func load(_ destination: Destination, profile: UUID?) {
        commit()
        select(profile)
        var tried = profile.flatMap { profiles.profile($0) } ?? Profile(destination)
        tried.audio = destination.audio
        tried.encoding = destination.encoding
        fill(tried)
        password.stringValue = destination.password
    }

    /// Bring the form up as it was left, with `error` on it if this is the
    /// second attempt at something.
    func show(error: String? = nil) {
        message.stringValue = error ?? ""
        message.isHidden = error == nil
        fit()

        panel.makeKeyAndOrderFront(nil)
        // Where typing should start: a saved desktop usually wants only the
        // password, or nothing at all.
        let saved = current.flatMap { profiles.profile($0) }?.sealedPassword != nil
        let first: NSResponder = host.stringValue.isEmpty ? host
            : saved || !password.stringValue.isEmpty ? table : password
        panel.makeFirstResponder(first)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Out of the way, not closed: a window that is merely hidden does not
    /// count as the last one, so putting it away cannot quit the app.
    func hide() {
        panel.orderOut(nil)
    }

    /// Keep what is typed into the form, for an app about to quit. False when
    /// it cannot be kept, with the form up and the reason on it.
    func save() -> Bool {
        guard commit() else {
            panel.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    /// Closing keeps what is typed, and a port that is not one or a password
    /// that will not seal keeps the window open with the reason on it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        commit()
    }

    // MARK: - The form

    /// Show `profile` in the form. The password field starts empty whatever is
    /// saved: a saved password is opened when it is connected with, not when
    /// it is looked at.
    private func fill(_ profile: Profile) {
        name.stringValue = profile.name
        host.stringValue = profile.host
        port.stringValue = String(profile.port)
        username.stringValue = profile.username
        password.stringValue = ""
        password.placeholderString = profile.sealedPassword == nil ? "none" : "saved"
        savesPassword.state = profile.savesPassword ? .on : .off
        audio.state = profile.audio ? .on : .off
        encoding.selectItem(withTag: Self.encodings.firstIndex { $0.0 == profile.encoding } ?? 0)
        message.isHidden = true
        fit()
        remove.isEnabled = current != nil
    }

    /// Write the form into the profile it is showing — or, with `creating`,
    /// into a new one when it is showing none. False, with the reason on the
    /// form, when the port is not a port or the password would not seal.
    @discardableResult
    private func commit(creating: Bool = false) -> Bool {
        let text = port.stringValue.trimmingCharacters(in: .whitespaces)
        guard let port = text.isEmpty ? 5900 : UInt16(text), port > 0 else {
            fail("A port is a number from 1 to 65535.", self.port)
            return false
        }
        var profile: Profile
        if let current, let saved = profiles.profile(current) {
            profile = saved
        } else if creating {
            profile = Profile()
        } else {
            return true
        }
        profile.name = name.stringValue.trimmingCharacters(in: .whitespaces)
        profile.host = host.stringValue.trimmingCharacters(in: .whitespaces)
        profile.port = port
        profile.username = username.stringValue
        profile.audio = audio.state == .on
        profile.encoding = Self.encodings[max(encoding.selectedTag(), 0)].0
        profile.savesPassword = savesPassword.state == .on
        if !profile.savesPassword {
            profile.sealedPassword = nil
        } else if !password.stringValue.isEmpty {
            do {
                profile.sealedPassword = try SafeStorage.seal(password.stringValue, for: profile.id)
            } catch {
                fail(error.localizedDescription, password)
                return false
            }
        }
        profiles.put(profile)
        if current == nil {
            current = profile.id
            profiles.selected = profile.id
            table.reloadData()
            select(profile.id)
        } else if let row = profiles.index(of: profile.id) {
            table.reloadData(forRowIndexes: [row], columnIndexes: [0])
        }
        password.placeholderString = profile.sealedPassword == nil ? "none" : "saved"
        remove.isEnabled = true
        return true
    }

    @objc private func connect() {
        guard !host.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            fail("A host is needed.", host)
            return
        }
        // Taken before the commit, which drops it when the checkbox is off.
        let saved = current.flatMap { profiles.profile($0) }?.sealedPassword
        guard commit(creating: true), let current, let profile = profiles.profile(current) else { return }
        // What is typed wins; with nothing typed, what is saved. A password
        // saved and no longer wanted is still the one to connect with this
        // once, as it was when the checkbox was unticked.
        let typed = password.stringValue
        let password: String
        do {
            password = try typed.isEmpty ? saved.map { try SafeStorage.open($0, for: profile.id) } ?? "" : typed
        } catch {
            fail(error.localizedDescription, self.password)
            return
        }
        hide()
        onConnect?(profile.destination(password: password), profile.id)
    }

    @objc private func connectClicked() {
        guard table.clickedRow >= 0 else { return }
        connect()
    }

    private func fail(_ reason: String, _ field: NSTextField) {
        message.stringValue = reason
        message.isHidden = false
        fit()
        panel.makeFirstResponder(field)
    }

    /// The window as tall as what is in it now, a message line more or less,
    /// with its top edge where it was.
    private func fit() {
        guard let content = panel.contentView else { return }
        message.preferredMaxLayoutWidth = form.fittingSize.width
        content.layoutSubtreeIfNeeded()
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    // MARK: - The list

    @objc private func addProfile() {
        // A desktop typed in but not saved yet is kept, not dropped.
        guard commit(creating: !host.stringValue.trimmingCharacters(in: .whitespaces).isEmpty) else { return }
        let profile = Profile()
        profiles.put(profile)
        table.reloadData()
        select(profile.id)
        panel.makeFirstResponder(host)
    }

    @objc private func removeProfile() {
        guard let current, let profile = profiles.profile(current) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(profile.title)”?"
        alert.informativeText = profile.sealedPassword == nil
            ? "It is removed from the list."
            : "It is removed from the list, with its saved password."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let row = profiles.index(of: current) ?? 0
        profiles.remove(current)
        self.current = nil
        table.reloadData()
        let next = profiles.profiles.isEmpty ? nil : profiles.profiles[min(row, profiles.profiles.count - 1)].id
        select(next)
        if next == nil { fill(Profile()) }
    }

    /// Select `id` in the list, and show it in the form if it is not already.
    private func select(_ id: UUID?) {
        let row = id.flatMap { profiles.index(of: $0) }
        table.selectRowIndexes(row.map { [$0] } ?? [], byExtendingSelection: false)
        if let row { table.scrollRowToVisible(row) }
        shown(id)
    }

    private func shown(_ id: UUID?) {
        guard id != current else { return }
        current = id
        profiles.selected = id
        fill(id.flatMap { profiles.profile($0) } ?? Profile())
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        profiles.profiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ProfileCell.identifier, owner: nil) as? ProfileCell ?? ProfileCell()
        cell.show(profiles.profiles[row])
        return cell
    }

    /// Moving off a profile saves what was typed into it, and a port that is
    /// not one keeps the selection where it is until it is put right.
    func selectionShouldChange(in tableView: NSTableView) -> Bool {
        commit()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        shown(row >= 0 ? profiles.profiles[row].id : nil)
    }
}

/// One row of the list: the name, and under it who goes where. No picture of
/// the desktop — a row is a line of text.
private final class ProfileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("profile")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        textField = title

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not from a nib")
    }

    func show(_ profile: Profile) {
        textField?.stringValue = profile.title
        detail.stringValue = profile.address
        // Hidden rather than blank, so a title on its own is centred.
        detail.isHidden = profile.address.isEmpty
    }
}
