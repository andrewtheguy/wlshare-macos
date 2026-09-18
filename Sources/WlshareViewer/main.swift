import AppKit

// Explicit rather than `@main`: the app has no storyboard and no principal
// class to name in its Info.plist, and this is the whole of what those would do.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
