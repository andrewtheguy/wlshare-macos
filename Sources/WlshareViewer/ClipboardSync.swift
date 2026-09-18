import AppKit

/// The Mac's clipboard and the desktop's, kept in step.
///
/// The desktop's arrives when it changes, and goes on the Mac's pasteboard at
/// once. The Mac's goes the other way only when the desktop window becomes the
/// one being used and the pasteboard has changed since — macOS says nothing
/// when something is copied, and that moment is when a paste into the desktop
/// can next happen. The core notifies the desktop and sends the text when it is
/// asked for, so the desktop never learns anything copied while this window was
/// not in front.
@MainActor
final class ClipboardSync {
    private let client: Client
    private let pasteboard = NSPasteboard.general
    /// The pasteboard's change count as it was last offered or written. Both
    /// directions record it, so neither sends back what the other just did.
    private var seenChange: Int?
    /// The desktop's clipboard already on the pasteboard.
    private var seenGeneration: UInt64 = 0

    init(client: Client) {
        self.client = client
    }

    /// Give the desktop the Mac's clipboard, if it has changed since.
    func offer() {
        let change = pasteboard.changeCount
        guard change != seenChange else { return }
        seenChange = change
        guard let text = pasteboard.string(forType: .string) else { return }
        client.setClipboard(text)
    }

    /// Put the desktop's clipboard on the Mac's, if there is a new one.
    func take() {
        guard let (generation, text) = client.desktopClipboard(after: seenGeneration) else { return }
        seenGeneration = generation
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        seenChange = pasteboard.changeCount
    }
}
