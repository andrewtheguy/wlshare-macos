import AppKit

// Explicit rather than `@main`: the app has no storyboard and no principal
// class to name in its Info.plist, and this is the whole of what those would do.
// `Application`'s own `shared` is what makes the shared instance that class,
// and the app must have no other before it.
let application = Application.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
