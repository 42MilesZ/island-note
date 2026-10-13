import AppKit

#if ISLAND_EVENT_PROBE
let app = IslandDiagnosticApplication.shared
guard app is IslandDiagnosticApplication, NSApp === app else {
    fatalError("The diagnostic application entry point was not installed")
}
if CommandLine.arguments.contains("--event-probe-self-test") {
    print("Event probe ready: " + NSStringFromClass(type(of: app)))
    exit(0)
}
#else
let app = NSApplication.shared
#endif
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon, no menu bar item — pure hover utility.
app.setActivationPolicy(.accessory)
app.run()
