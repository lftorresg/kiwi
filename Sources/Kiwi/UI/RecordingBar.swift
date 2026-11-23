import AppKit
import SwiftUI

/// The bar that opens when you ask to record: choose what to record and
/// which sound to include, then press Record. Return starts, Esc closes.
@MainActor
final class RecordingBar {
    static let shared = RecordingBar()

    private var panel: FloatingPanel?

    private init() {}

    var isVisible: Bool { panel != nil }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard panel == nil else { return }
        let view = RecordingBarView(
            prefs: Prefs.shared,
            onRecord: { [weak self] in self?.record() },
            onClose: { [weak self] in self?.hide() }
        )
        let host = FirstMouseHostingView(rootView: view)
        let fitting = host.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))

        let bar = FloatingPanel(size: size, level: .statusBar)
        // Taking the keyboard lets Return and Esc work without activating Kiwi.
        bar.allowsKey = true
        bar.contentView = host
        host.frame = NSRect(origin: .zero, size: size)

        let area = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 64)
        bar.setFrame(NSRect(origin: origin, size: size), display: true)
        bar.makeKeyAndOrderFront(nil)
        panel = bar
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func record() {
        let wholeScreen = Prefs.shared.recordWholeScreen
        hide()
        CaptureController.shared.beginRecording(wholeScreen: wholeScreen)
    }
}

private struct RecordingBarView: View {
    @ObservedObject var prefs: Prefs
    let onRecord: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")

            Picker("What to record", selection: $prefs.recordWholeScreen) {
                Text("Area or Window").tag(false)
                Text("Entire Screen").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Toggle(isOn: $prefs.recordMicrophone) {
                Image(systemName: prefs.recordMicrophone ? "mic.fill" : "mic.slash")
            }
            .toggleStyle(.button)
            .help("Record your microphone")

            Toggle(isOn: $prefs.recordSystemAudio) {
                Image(systemName: prefs.recordSystemAudio ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .toggleStyle(.button)
            .help("Record the Mac's sound")

            Button(action: onRecord) {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
            .help(prefs.recordWholeScreen
                ? "Start recording the screen under the pointer (Return)"
                : "Choose an area, or press Space for a window, and recording starts (Return)")
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(14)
        .fixedSize()
    }
}

/// What the Stop pill shows.
@MainActor
final class RecordingClock: ObservableObject {
    @Published var text = "Starting…"
}

/// A small floating Stop button with the elapsed time, on screen for the
/// whole recording. It is one of Kiwi's own windows, so it is never part of
/// the video.
@MainActor
final class RecordingPill: NSObject {
    static let shared = RecordingPill()

    private let clock = RecordingClock()
    private var panel: FloatingPanel?
    private var timer: Timer?

    private override init() {
        super.init()
    }

    func show(on screen: NSScreen) {
        hide()
        clock.text = "Starting…"
        let view = RecordingPillView(clock: clock) {
            RecordingController.shared.stop()
        }
        let host = FirstMouseHostingView(rootView: view)
        let fitting = host.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))

        let pill = FloatingPanel(size: size, level: .statusBar)
        pill.isMovable = true
        pill.isMovableByWindowBackground = true
        pill.contentView = host
        host.frame = NSRect(origin: .zero, size: size)

        let area = screen.visibleFrame
        pill.setFrame(
            NSRect(x: area.midX - size.width / 2, y: area.minY + 8, width: size.width, height: size.height),
            display: true
        )
        pill.orderFrontRegardless()
        panel = pill

        let tick = Timer(timeInterval: 0.5, target: self, selector: #selector(update), userInfo: nil, repeats: true)
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func update() {
        guard let started = RecordingController.shared.startedAt else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(started)))
        let seconds = elapsed % 60
        let text = "\(elapsed / 60):\(seconds < 10 ? "0" : "")\(seconds)"
        if clock.text != text {
            clock.text = text
        }
    }
}

private struct RecordingPillView: View {
    @ObservedObject var clock: RecordingClock
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
                Text(clock.text)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 62, alignment: .leading)
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .help("Stop recording")
        .padding(14)
        .fixedSize()
    }
}
