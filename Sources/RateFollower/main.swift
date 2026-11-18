import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController!
    private let engine = Engine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusController()
        engine.onUpdate = { [weak self] device, track in self?.status.update(device: device, track: track) }
        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon

// Route SIGTERM/SIGINT (pkill, logout) through a normal quit so the
// `log stream` child is terminated too.
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { NSApp.terminate(nil) }
    src.resume()
    _ = Unmanaged.passRetained(src)  // lives for the process lifetime
}
app.run()
