import AppKit

// A plain AppKit entry point instead of SwiftUI's `App`: the menu bar item is an
// `NSStatusItem`, and SwiftUI is only loaded while the Settings window is open.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // the bundle also sets LSUIElement
app.run()
