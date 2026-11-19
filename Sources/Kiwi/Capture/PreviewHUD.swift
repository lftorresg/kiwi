import AppKit
import QuartzCore
import SwiftUI

/// The floating glass preview that appears after every capture.
@MainActor
final class PreviewHUD {
    static let shared = PreviewHUD()

    private var panel: FloatingPanel?
    private var capture: Capture?
    private var hovering = false
    private var timerToken = 0

    private init() {}

    func show(_ capture: Capture, on screen: NSScreen?) {
        dismiss(animated: false)
        self.capture = capture

        let thumbnail = capture.image.downscaled(maxPixel: 720)
        let image = NSImage(cgImage: thumbnail, size: capture.pointSize)
        let controller = CaptureController.shared

        present(on: screen) { hoverState in
            PreviewHUDView(
                hover: hoverState,
                image: image,
                fileURL: capture.cacheURL,
                onCopy: { controller.copy(capture) },
                onEdit: { controller.edit(capture) },
                onSave: { controller.save(capture) },
                onDelete: { controller.delete(capture) },
                onClose: { [weak self] in self?.dismiss() }
            )
        }
    }

    /// Shows a finished screen recording with its own actions.
    func showRecording(at url: URL, thumbnail: NSImage?, on screen: NSScreen?) {
        dismiss(animated: false)

        present(on: screen) { hoverState in
            RecordingHUDView(
                hover: hoverState,
                image: thumbnail,
                fileURL: url,
                onReveal: {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                },
                onCopy: {
                    Clipboard.copy(files: [url])
                    Toast.show("Recording copied", symbol: "doc.on.doc.fill")
                },
                onDelete: { [weak self] in
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    self?.dismiss()
                    Toast.show("Recording moved to Trash", symbol: "trash.fill")
                },
                onClose: { [weak self] in self?.dismiss() }
            )
        }
    }

    private func present<Content: View>(on screen: NSScreen?, @ViewBuilder content: (HoverState) -> Content) {
        let hoverState = HoverState()
        let host = FirstMouseHostingView(rootView: content(hoverState))
        host.onHoverChange = { [weak self] inside in
            hoverState.hovering = inside
            self?.setHovering(inside)
        }
        let fitting = host.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))

        let hud = FloatingPanel(size: size, level: .statusBar)
        hud.contentView = host
        host.frame = NSRect(origin: .zero, size: size)

        let area = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let resting = NSRect(
            x: area.maxX - size.width - 6,
            y: area.minY + 6,
            width: size.width,
            height: size.height
        )
        hud.setFrame(resting.offsetBy(dx: 0, dy: -16), display: true)
        hud.alphaValue = 0
        hud.orderFrontRegardless()
        self.panel = hud

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hud.animator().alphaValue = 1
            hud.animator().setFrame(resting, display: true)
        }
        scheduleDismiss()
    }

    func dismiss(ifShowing target: Capture) {
        if capture === target { dismiss() }
    }

    func dismiss(animated: Bool = true) {
        timerToken += 1
        hovering = false
        capture = nil
        guard let closing = self.panel else { return }
        self.panel = nil

        guard animated else {
            closing.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            closing.animator().alphaValue = 0
        }
        after(0.25) {
            closing.orderOut(nil)
        }
    }

    private func setHovering(_ inside: Bool) {
        hovering = inside
        if inside {
            timerToken += 1 // pause the countdown while the pointer is over the preview
        } else {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        timerToken += 1
        let token = timerToken
        let seconds = max(2, Prefs.shared.previewSeconds)
        after(seconds) { [weak self] in
            guard let self, self.timerToken == token, !self.hovering else { return }
            self.dismiss()
        }
    }
}

private struct PreviewHUDView: View {
    @ObservedObject var hover: HoverState
    let image: NSImage
    let fileURL: URL
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            VStack(alignment: .trailing, spacing: 8) {
                thumbnail
                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .help("Copy to clipboard")

                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil.tip.crop.circle")
                    }
                    .help("Annotate, crop, blur")

                    Button(action: onSave) {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonBorderShape(.circle)
                    .help("Save to your screenshots folder")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonBorderShape(.circle)
                    .help("Delete this screenshot")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(16) // room for glass shadows inside the transparent panel
        .fixedSize()
    }

    private var thumbnail: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 248, maxHeight: 156)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(6)
                .opacity(hover.hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hover.hovering)
                .help("Dismiss")
            }
            .padding(6)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
            .onDrag {
                NSItemProvider(contentsOf: fileURL) ?? NSItemProvider()
            }
            .help("Click to edit, or drag into any app")
    }
}

private struct RecordingHUDView: View {
    @ObservedObject var hover: HoverState
    let image: NSImage?
    let fileURL: URL
    let onReveal: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            VStack(alignment: .trailing, spacing: 8) {
                thumbnail
                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .help("Copy the video file")

                    Button(action: onReveal) {
                        Label("Show", systemImage: "folder")
                    }
                    .help("Show in Finder")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonBorderShape(.circle)
                    .help("Move the recording to the Trash")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(16)
        .fixedSize()
    }

    private var thumbnail: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 220, height: 124)
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(radius: 6)
        }
        .frame(maxWidth: 248, maxHeight: 156)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(.black.opacity(0.55), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(6)
            .opacity(hover.hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: hover.hovering)
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(fileURL)
        }
        .onDrag {
            NSItemProvider(contentsOf: fileURL) ?? NSItemProvider()
        }
        .help("Click to play, or drag into any app")
    }
}
