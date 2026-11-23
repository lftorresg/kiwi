import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records a display, or part of one, straight to a video file (HEVC by default) using
/// ScreenCaptureKit's own recording output. No frames or audio pass through Kiwi.
/// The file is MP4, or MOV when the microphone is recorded.
@MainActor
final class RecordingController: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    static let shared = RecordingController()

    /// Called on the main actor whenever recording starts or stops.
    var onStateChange: ((Bool) -> Void)?

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// The most recent finished recording of this session.
    private(set) var lastURL: URL?
    /// This session's recordings, newest first.
    private(set) var recent: [URL] = []
    /// Called whenever the list of recordings changes.
    var onRecentChange: (() -> Void)?

    private func remember(_ url: URL) {
        recent.removeAll { $0.path == url.path }
        recent.insert(url, at: 0)
        if recent.count > 8 { recent.removeLast() }
        lastURL = url
        onRecentChange?()
    }

    /// A recording was deleted.
    func forget(_ url: URL) {
        recent.removeAll { $0.path == url.path }
        if lastURL?.path == url.path { lastURL = recent.first }
        onRecentChange?()
    }

    /// A recording was saved again under a (possibly) different name.
    func replace(_ old: URL, with new: URL) {
        if let index = recent.firstIndex(where: { $0.path == old.path }) {
            recent[index] = new
        }
        if lastURL?.path == old.path { lastURL = new }
        onRecentChange?()
    }

    private var isBusy = false
    private var didFinishWriting = false
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var outputURL: URL?
    private var borderPanel: FloatingPanel?
    private var screen: NSScreen?

    // Follow Me: the recording moves to the screen the user clicks on.
    private var followMonitor: Any?
    private var currentDisplayID: CGDirectDisplayID?
    private var isSwitching = false
    /// A capture filter for every screen, made when the recording starts, so
    /// that moving to another screen needs no look-up.
    private var followFilters: [CGDirectDisplayID: SCContentFilter] = [:]

    /// Starts recording. `rect` is in the display's point space with a top-left
    /// origin; nil records the whole display.
    func start(displayID: CGDirectDisplayID, rect: CGRect?, screen: NSScreen, follows: Bool = false) {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        self.screen = screen
        currentDisplayID = displayID
        if follows, rect == nil {
            // A global monitor only reports that a click happened somewhere;
            // it needs no permission and Kiwi reads nothing else from it.
            followMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.followPointer()
                }
            }
        }
        didFinishWriting = false

        if let rect {
            let border = RegionBorder.make(around: rect, on: screen, color: .systemRed)
            border.orderFrontRegardless()
            borderPanel = border
        }
        RecordingBar.shared.hide()
        RecordingPill.shared.show(on: screen)
        let systemAudio = Prefs.shared.recordSystemAudio
        let wantsMicrophone = Prefs.shared.recordMicrophone
        let useHEVC = Prefs.shared.recordHEVC
        let maxHeight = Prefs.shared.recordMaxHeight
        let frameRate = Prefs.shared.recordFrameRate
        let followsScreens = follows && rect == nil
        let folder = Prefs.shared.saveFolderURL

        Task { @MainActor in
            do {
                // Let the outline appear first so the capture filter can exclude Kiwi's windows.
                try await Task.sleep(nanoseconds: 150_000_000)
                let found = try await ScreenGrabber.locateDisplay(displayID)
                let setup = try ScreenGrabber.regionSetup(
                    display: found.display, content: found.content, rect: rect, showCursor: true
                )

                var configuration = setup.configuration
                if followsScreens {
                    self.followFilters = ScreenGrabber.displayFilters(in: found.content)
                    // One 16:9 picture for every screen. These settings name no
                    // particular part of a screen, so whichever screen the
                    // stream is pointed at is captured whole and scaled to fit
                    // the picture. That matters because changing the settings
                    // in the middle of a recording ended it when Kiwi tried, so
                    // on a switch only the screen being captured changes.
                    let frame = Self.followCanvas(maxHeight: maxHeight)
                    let whole = SCStreamConfiguration()
                    whole.width = Int(frame.width)
                    whole.height = Int(frame.height)
                    whole.showsCursor = true
                    whole.captureResolution = .best
                    StreamBackground.setBlack(on: whole)
                    configuration = whole
                } else {
                    let size = Self.videoSize(
                        width: configuration.width, height: configuration.height, maxHeight: maxHeight
                    )
                    configuration.width = size.width
                    configuration.height = size.height
                }
                configuration.scalesToFit = true
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                configuration.queueDepth = 6
                configuration.capturesAudio = systemAudio
                configuration.excludesCurrentProcessAudio = true

                // The microphone is used only when the user turned it on, and
                // only if macOS confirms that Kiwi is allowed to.
                var microphone = false
                if wantsMicrophone {
                    if let device = AVCaptureDevice.default(for: .audio), await Self.microphoneAllowed() {
                        configuration.captureMicrophone = true
                        configuration.microphoneCaptureDeviceID = device.uniqueID
                        microphone = true
                    } else {
                        Toast.error("No microphone access, recording without it")
                    }
                }

                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = CaptureStore.makeName().replacingOccurrences(of: "Kiwi ", with: "Kiwi Recording ")
                let url = CaptureStore.uniqueURL(in: folder, name: name, ext: microphone ? "mov" : "mp4")

                let recordingConfiguration = SCRecordingOutputConfiguration()
                recordingConfiguration.outputURL = url
                recordingConfiguration.outputFileType = microphone ? .mov : .mp4
                recordingConfiguration.videoCodecType = useHEVC ? .hevc : .h264

                let stream = SCStream(filter: setup.filter, configuration: configuration, delegate: self)
                let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
                try stream.addRecordingOutput(output)
                try await stream.startCapture()

                self.stream = stream
                self.output = output
                self.outputURL = url
                self.startedAt = Date()
                self.isBusy = false
                self.isRecording = true
                self.onStateChange?(true)
            } catch {
                NSLog("Kiwi: recording could not start: %@", error.localizedDescription)
                self.reset()
                Toast.error("Couldn't start recording")
            }
        }
    }

    /// Stops recording and shows the finished file.
    func stop() {
        guard isRecording, !isBusy else { return }
        finish()
    }

    /// Ends the recording and shows the file. Also used when the recording
    /// was ended from outside Kiwi, for example with the screen recording
    /// control that macOS itself puts in the menu bar.
    private func finish() {
        guard let stream else {
            reset()
            return
        }
        isBusy = true
        let url = outputURL
        let screen = self.screen

        Task { @MainActor in
            // Harmless when the stream has already stopped.
            try? await stream.stopCapture()
            // Give the writer a moment to finalize the file.
            var waited = 0
            while !self.didFinishWriting, waited < 40 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            self.reset()
            guard let url, FileManager.default.fileExists(atPath: url.path) else {
                Toast.error("The recording could not be saved")
                return
            }
            self.remember(url)
            if Prefs.shared.editAfterCapture {
                VideoEditorCoordinator.shared.open(url)
                return
            }
            let thumbnail = await Self.thumbnail(for: url)
            PreviewHUD.shared.showRecording(at: url, thumbnail: thumbnail, on: screen)
        }
    }

    private func reset() {
        let wasRecording = isRecording
        if let followMonitor {
            NSEvent.removeMonitor(followMonitor)
        }
        followMonitor = nil
        currentDisplayID = nil
        followFilters.removeAll()
        isSwitching = false
        RecordingPill.shared.hide()
        borderPanel?.orderOut(nil)
        borderPanel = nil
        stream = nil
        output = nil
        outputURL = nil
        startedAt = nil
        isRecording = false
        isBusy = false
        if wasRecording { onStateChange?(false) }
    }

    // MARK: Follow Me

    /// After a click, points the recording at the screen the pointer is on,
    /// if that is not the screen being recorded. The video keeps its size;
    /// a screen with another shape is scaled to fit.
    private func followPointer() {
        guard isRecording, !isBusy, !isSwitching, let stream,
              let target = NSScreen.underMouse, let displayID = target.displayID,
              displayID != currentDisplayID else { return }
        isSwitching = true
        Task { @MainActor in
            do {
                // Only the screen changes. The stream's settings stay as they
                // are, and they capture whichever screen this is in full.
                let filter: SCContentFilter
                if let ready = self.followFilters[displayID] {
                    filter = ready
                } else {
                    // A screen connected after the recording began.
                    let found = try await ScreenGrabber.locateDisplay(displayID)
                    let filters = ScreenGrabber.displayFilters(in: found.content)
                    self.followFilters = filters
                    guard let fresh = filters[displayID] else {
                        throw KiwiError("That display is no longer available.")
                    }
                    filter = fresh
                }
                try await stream.updateContentFilter(filter)
                if self.isRecording {
                    self.currentDisplayID = displayID
                    if let moved = NSScreen.matching(displayID) {
                        self.screen = moved
                        RecordingPill.shared.move(to: moved)
                    }
                }
            } catch {
                NSLog("Kiwi: could not switch the recording to another screen: %@", error.localizedDescription)
            }
            self.isSwitching = false
        }
    }

    // MARK: SCRecordingOutputDelegate (called on a background queue)

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            self.didFinishWriting = true
            // Finished without Kiwi asking: something else ended the recording.
            if self.isRecording, !self.isBusy {
                self.finish()
            }
        }
    }

    // MARK: SCStreamDelegate (called on a background queue)

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            guard self.isRecording, !self.isBusy else { return }
            NSLog("Kiwi: the capture stream was stopped: %@", description)
            self.finish()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            NSLog("Kiwi: recording failed: %@", description)
            self.didFinishWriting = true
            // Keep whatever was written; finish() reports it if there is no file.
            if self.isRecording, !self.isBusy {
                self.finish()
            }
        }
    }

    // MARK: Helpers

    /// Whether Kiwi may use the microphone. Asks the first time.
    static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// H.264 wants even dimensions and is happiest at 4K or below.
    /// `maxHeight` is the user's resolution limit; 0 means none.
    static func videoSize(width: Int, height: Int, maxHeight limit: Int = 0) -> (width: Int, height: Int) {
        let maxWidth = 3840.0
        let maxHeight = limit > 0 ? min(2160.0, Double(limit)) : 2160.0
        let w = Double(max(2, width))
        let h = Double(max(2, height))
        let fit = min(1, maxWidth / w, maxHeight / h)
        let evenWidth = max(2, Int((w * fit) / 2) * 2)
        let evenHeight = max(2, Int((h * fit) / 2) * 2)
        return (evenWidth, evenHeight)
    }

    /// The 16:9 picture a recording that follows the user is laid out in. It
    /// is as tall as the resolution limit allows, and never taller than the
    /// smallest connected screen, so nothing has to be enlarged.
    static func followCanvas(maxHeight limit: Int) -> CGSize {
        var height: CGFloat = limit > 0 ? CGFloat(limit) : 2160
        for screen in NSScreen.screens {
            height = min(height, (screen.frame.height * screen.backingScaleFactor).rounded())
        }
        height = max(360, (height / 2).rounded(.down) * 2)
        let width = (height * 16 / 9 / 2).rounded(.down) * 2
        return CGSize(width: width, height: height)
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        guard let frame = try? await generator.image(at: .zero) else { return nil }
        let image = frame.image
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
