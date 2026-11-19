import AppKit

/// Entry point. Kiwi runs as a menu bar agent: no Dock icon, no main window.
@main
@MainActor
enum KiwiApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
