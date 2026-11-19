import AppKit
import SwiftUI

/// Live status shown in the scrolling-capture control panel.
@MainActor
final class ScrollCaptureState: ObservableObject {
    @Published var message = "Scroll down slowly"
    @Published var height = 0
    @Published var warning = false
}

/// Captures a region repeatedly while the user scrolls and stitches the
/// frames into one tall screenshot.
@MainActor
final class ScrollCaptureController {
    static let shared = ScrollCaptureController()

    private let state = ScrollCaptureState()
    private let queue = DispatchQueue(label: "io.github.lftorresg.kiwi.scroll", qos: .userInitiated)

    private var grabber: RegionGrabber?
    private var stitcher: ScrollStitcher?
    private var borderPanel: FloatingPanel?
    private var controlPanel: FloatingPanel?
    private var screen: NSScreen?
    private var session = 0
    private var busy = false

    private(set) var isActive = false

    private init() {}

    /// - Parameter rect: Region in the display's point space, origin top-left.
    func start(displayID: CGDirectDisplayID, rect: CGRect, screen: NSScreen) {
        guard !isActive else { return }
        isActive = true
        session += 1
        let current = session
        self.screen = screen
        busy = false
        state.message = "Scroll down slowly"
        state.height = 0
        state.warning = false
        stitcher = ScrollStitcher()

        showPanels(around: rect, on: screen)

        // Kiwi's panels are on screen now, so the capture filter can exclude them.
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                let grabber = try await ScreenGrabber.makeRegionGrabber(displayID, rect: rect)
                guard self.isActive, self.session == current else { return }
                self.grabber = grabber
                self.tick(current)
            } catch {
                guard self.session == current else { return }
                NSLog("Kiwi: scrolling capture could not start: %@", error.localizedDescription)
                self.cancel()
                Toast.error("Couldn't start scrolling capture")
            }
        }
    }

    /// Stops and delivers the stitched image through the normal capture flow.
    func finish() {
        guard isActive, let stitcher, let screen else {
            cancel()
            return
        }
        let scale = grabber?.scale ?? screen.backingScaleFactor
        teardown()
        queue.async {
            let image = stitcher.finish()
            Task { @MainActor in
                if let image {
                    CaptureController.shared.ingest(image: image, scale: scale, screen: screen)
                } else {
                    Toast.error("Nothing was captured")
                }
            }
        }
    }

    func cancel() {
        teardown()
    }

    private func teardown() {
        isActive = false
        session += 1
        grabber = nil
        stitcher = nil
        borderPanel?.orderOut(nil)
        controlPanel?.orderOut(nil)
        borderPanel = nil
        controlPanel = nil
    }

    // MARK: Capture loop

    private func tick(_ current: Int) {
        guard isActive, session == current else { return }
        after(0.11) { [weak self] in
            self?.tick(current)
        }
        guard !busy, let grabber, let stitcher else { return }
        busy = true

        Task { @MainActor in
            guard let frame = try? await grabber.grab() else {
                self.busy = false
                return
            }
            guard self.isActive, self.session == current else { return }
            self.queue.async {
                let step = stitcher.add(frame)
                Task { @MainActor in
                    self.handle(step, session: current)
                }
            }
        }
    }

    private func handle(_ step: ScrollStitcher.Step, session current: Int) {
        guard isActive, session == current else { return }
        busy = false
        switch step {
        case .first, .idle:
            if state.warning {
                state.warning = false
                state.message = "Scroll down slowly"
            }
        case .scrolled(let height):
            state.height = height
            state.warning = false
            state.message = "Keep scrolling, then press Done"
        case .lost:
            state.warning = true
            state.message = "Lost track. Scroll back up a little."
        case .full:
            finish()
        }
    }

    // MARK: Panels

    private func showPanels(around rect: CGRect, on screen: NSScreen) {
        let border = RegionBorder.make(around: rect, on: screen, color: Theme.kiwiNS)
        border.orderFrontRegardless()
        borderPanel = border

        let view = ScrollCaptureControls(
            state: state,
            onDone: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )
        let host = FirstMouseHostingView(rootView: view)
        let fitting = host.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        let panel = FloatingPanel(size: size, level: .statusBar)
        panel.contentView = host
        host.frame = NSRect(origin: .zero, size: size)

        // Prefer just below the region, then just above, then inside its bottom edge.
        let region = RegionBorder.globalFrame(for: rect, on: screen)
        let bounds = screen.visibleFrame
        var origin = NSPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 4)
        if origin.y < bounds.minY {
            origin.y = region.maxY + 4
        }
        if origin.y + size.height > bounds.maxY {
            origin.y = region.minY + 8
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        controlPanel = panel
    }
}

private struct ScrollCaptureControls: View {
    @ObservedObject var state: ScrollCaptureState
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.warning ? "exclamationmark.triangle.fill" : "arrow.down.to.line.compact")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state.warning ? Color.orange : Theme.kiwi)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.message)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(state.height > 0 ? "\(state.height) px tall" : "Waiting for the first scroll")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 210, alignment: .leading)

            Button("Cancel", action: onCancel)
                .buttonStyle(.glass)
            Button("Done", action: onDone)
                .buttonStyle(.glassProminent)
                .tint(Theme.kiwi)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(14)
        .fixedSize()
    }
}
