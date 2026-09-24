import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon, no menu bar item — pure hover utility.
app.setActivationPolicy(.accessory)
app.run()
