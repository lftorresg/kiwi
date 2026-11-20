import AppKit
import SwiftUI

/// What the progress panel shows.
@MainActor
final class JobProgress: ObservableObject {
    @Published var title = ""
    @Published var detail = ""
    /// Nil while the amount of work is unknown.
    @Published var fraction: Double?
}

/// A small glass panel for jobs that take a while, with a Cancel button.
/// It only appears when a job is still running after a moment, so quick
/// conversions never flash it.
@MainActor
final class ProgressPanel {
    static let shared = ProgressPanel()

    /// Called when the user presses Cancel.
    var onCancel: (() -> Void)?

    private let state = JobProgress()
    private var panel: FloatingPanel?
    private var generation = 0

    private init() {}

    func begin(title: String) {
        generation += 1
        let current = generation
        state.title = title
        state.detail = ""
        state.fraction = nil
        onCancel = nil
        after(0.6) { [weak self] in
            guard let self, self.generation == current else { return }
            self.present()
        }
    }

    func update(detail: String? = nil, fraction: Double? = nil) {
        if let detail { state.detail = detail }
        if let fraction { state.fraction = min(1, max(0, fraction)) }
    }

    func end() {
        generation += 1
        onCancel = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func present() {
        let view = ProgressPanelView(state: state) { [weak self] in
            self?.onCancel?()
        }
        let host = FirstMouseHostingView(rootView: view)
        let fitting = host.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))

        let created = FloatingPanel(size: size, level: .statusBar)
        created.contentView = host
        host.frame = NSRect(origin: .zero, size: size)

        let area = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 12)
        created.setFrame(NSRect(origin: origin, size: size), display: true)
        created.orderFrontRegardless()
        panel = created
    }
}

private struct ProgressPanelView: View {
    @ObservedObject var state: JobProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(state.title)
                    .font(.system(size: 12.5, weight: .semibold))
                bar
                Text(state.detail.isEmpty ? " " : state.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 250, alignment: .leading)

            Button("Cancel", action: onCancel)
                .buttonStyle(.glass)
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(14)
        .fixedSize()
    }

    @ViewBuilder
    private var bar: some View {
        if let fraction = state.fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Theme.kiwi)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Theme.kiwi)
        }
    }
}
