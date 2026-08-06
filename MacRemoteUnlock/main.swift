import Cocoa

// Manual main entry: there is no MainMenu.xib in this app, so we wire up the
// AppDelegate explicitly (an @NSApplicationMain class would not be instantiated
// without a nib/storyboard).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
