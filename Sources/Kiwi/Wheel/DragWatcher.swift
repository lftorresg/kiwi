import AppKit

/// Notices when files are being dragged anywhere on the Mac and reports
/// modifier-key taps made during that drag.
///
/// It uses global mouse monitors plus the drag pasteboard's change count and
/// type list, never the pasteboard contents, so it needs neither Accessibility
/// nor Input Monitoring permission. The polling timer only runs while a file
/// drag is in flight.
@MainActor
final class DragWatcher: NSObject {
    var onTrigger: ((WheelRing) -> Void)?
    var onDragEnded: (() -> Void)?

    private var monitors: [Any] = []
    private var timer: Timer?
    private var mouseIsDown = false
    private var fileDragActive = false
    private var pasteboardCountAtMouseDown = 0
    private var previousFlags: NSEvent.ModifierFlags = []

    private let watched: NSEvent.ModifierFlags = [.shift, .command, .control]

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard !isRunning else { return }
        // Global monitors always call back on the main thread.
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouseDown()
            }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouseDragged()
            }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endDrag()
            }
        }
        for monitor in [down, dragged, up] {
            if let monitor { monitors.append(monitor) }
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        endDrag()
    }

    private func mouseDown() {
        mouseIsDown = true
        fileDragActive = false
        pasteboardCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    }

    private func mouseDragged() {
        guard mouseIsDown, !fileDragActive else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != pasteboardCountAtMouseDown else { return }
        // A new drag has started. Only file drags are interesting.
        pasteboardCountAtMouseDown = pasteboard.changeCount
        guard pasteboard.types?.contains(.fileURL) == true else { return }

        fileDragActive = true
        // Keys already held when the drag starts are ignored until released.
        previousFlags = NSEvent.modifierFlags.intersection(watched)
        startTimer()
    }

    private func startTimer() {
        self.timer?.invalidate()
        let poll = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(poll, forMode: .common)
        self.timer = poll
    }

    @objc private func tick() {
        guard fileDragActive else {
            timer?.invalidate()
            timer = nil
            return
        }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            endDrag()
            return
        }
        let flags = NSEvent.modifierFlags.intersection(watched)
        let pressed = flags.subtracting(previousFlags)
        previousFlags = flags
        if pressed.contains(.shift) {
            onTrigger?(.convert)
        } else if pressed.contains(.command) {
            onTrigger?(.tools)
        } else if pressed.contains(.control) {
            onTrigger?(.actions)
        }
    }

    private func endDrag() {
        timer?.invalidate()
        timer = nil
        let wasActive = fileDragActive
        mouseIsDown = false
        fileDragActive = false
        if wasActive {
            onDragEnded?()
        }
    }
}
