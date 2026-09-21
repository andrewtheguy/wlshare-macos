import AppKit

/// The application, for one reason: AppKit withholds `keyUp` while Command is
/// down.
///
/// `NSApplication.sendEvent` drops a key release whose modifiers carry
/// Command — it never reaches the window, let alone the view. A local desktop
/// never notices, because a menu's key equivalent is done with by then. A
/// remote one does: the view forwards ⌘V as Super and V, and the V it pressed
/// is never let go of, so the desktop's own key repeat types `vvvvv…` until
/// something else presses that key. Handing the release to whatever has the
/// keyboard is what pairs it with its press. Nothing else wants a `keyUp`:
/// the default implementation passes it along and no responder here acts on
/// one it did not see go down.
final class Application: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyUp, event.modifierFlags.contains(.command) else {
            return super.sendEvent(event)
        }
        keyWindow?.firstResponder?.keyUp(with: event)
    }
}
