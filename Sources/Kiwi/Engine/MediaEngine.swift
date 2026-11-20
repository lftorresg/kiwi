import AVFoundation
import UniformTypeIdentifiers

/// Reports how far a job has come, from 0 to 1. May be called from any thread.
typealias ProgressHandler = @Sendable (Double) -> Void

/// What the wheel can do with a video.
enum VideoJob {
    case mp4
    case hevc
    case mov
    case audio
    case compress
    case fit1080
    case fit720
    case mute

    /// Shown while the job runs.
    var working: String {
        switch self {
        case .mp4: return "Converting to MP4"
        case .hevc: return "Converting to HEVC"
        case .mov: return "Converting to MOV"
        case .audio: return "Extracting audio"
        case .compress: return "Compressing"
        case .fit1080: return "Resizing to 1080p"
        case .fit720: return "Resizing to 720p"
        case .mute: return "Removing sound"
        }
    }

    /// Words for the result, as in "Converted 2 videos to MP4".
    var result: (verb: String, suffix: String) {
        switch self {
        case .mp4: return ("Converted", "to MP4")
        case .hevc: return ("Converted", "to HEVC")
        case .mov: return ("Converted", "to MOV")
        case .audio: return ("Extracted audio from", "")
        case .compress: return ("Compressed", "")
        case .fit1080: return ("Resized", "to 1080p")
        case .fit720: return ("Resized", "to 720p")
        case .mute: return ("Muted", "")
        }
    }
}

enum AudioFormat: String {
    case m4a
    case wav
    case aiff
    case flac

    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
}

/// Video and audio conversion built only on AVFoundation, so the formats are
/// the ones macOS itself can write. Results go next to the original under a
/// new name; originals are never modified.
enum MediaEngine {
    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func isAudio(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audio)
    }

    // MARK: Video

    static func run(_ job: VideoJob, on url: URL, progress: @escaping ProgressHandler) async throws -> URL {
        let asset = AVURLAsset(url: url)
        switch job {
        case .mp4:
            return try await export(
                asset, beside: url, presets: [AVAssetExportPresetHighestQuality],
                type: .mp4, fileExtension: "mp4", progress: progress
            )
        case .hevc:
            return try await export(
                asset, beside: url, presets: [AVAssetExportPresetHEVCHighestQuality],
                type: .mp4, fileExtension: "mp4", progress: progress
            )
        case .mov:
            // Rewrap without re-encoding when the contents allow it.
            return try await export(
                asset, beside: url, presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality],
                type: .mov, fileExtension: "mov", progress: progress
            )
        case .audio:
            return try await export(
                asset, beside: url, presets: [AVAssetExportPresetAppleM4A],
                type: .m4a, fileExtension: "m4a", progress: progress
            )
        case .compress:
            return try await export(
                asset, beside: url, presets: [AVAssetExportPresetHEVC1920x1080, AVAssetExportPresetMediumQuality],
                type: .mp4, fileExtension: "mp4", progress: progress
            )
        case .fit1080:
            return try await export(
                asset, beside: url, presets: [AVAssetExportPreset1920x1080],
                type: .mp4, fileExtension: "mp4", progress: progress
            )
        case .fit720:
            return try await export(
                asset, beside: url, presets: [AVAssetExportPreset1280x720],
                type: .mp4, fileExtension: "mp4", progress: progress
            )
        case .mute:
            let silent = try await videoOnlyCopy(of: asset)
            let keepsMP4 = ["mp4", "m4v"].contains(url.pathExtension.lowercased())
            return try await export(
                silent, beside: url, presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality],
                type: keepsMP4 ? .mp4 : .mov, fileExtension: keepsMP4 ? "mp4" : "mov", progress: progress
            )
        }
    }

    /// Tries each preset in turn and returns the first export that works.
    private static func export(
        _ asset: AVAsset,
        beside source: URL,
        presets: [String],
        type: AVFileType,
        fileExtension: String,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        var failure: Error = KiwiError("\(source.lastPathComponent) can't be converted to that format.")
        for preset in presets {
            try Task.checkCancellation()
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let output = ImageEngine.outputURL(for: source, fileExtension: fileExtension)

            let monitor = Task {
                for await state in session.states(updateInterval: 0.25) {
                    if case .exporting(let exported) = state {
                        progress(exported.fractionCompleted)
                    }
                }
            }
            do {
                try await withTaskCancellationHandler {
                    try await session.export(to: output, as: type)
                } onCancel: {
                    session.cancelExport()
                }
                monitor.cancel()
                return output
            } catch {
                monitor.cancel()
                try? FileManager.default.removeItem(at: output)
                if Task.isCancelled { throw CancellationError() }
                failure = error
            }
        }
        throw failure
    }

    /// The asset's video tracks, without any sound.
    private static func videoOnlyCopy(of asset: AVAsset) async throws -> AVMutableComposition {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else {
            throw KiwiError("There is no video in this file.")
        }
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        for track in tracks {
            guard let copy = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try copy.insertTimeRange(range, of: track, at: .zero)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        return composition
    }

    // MARK: Audio

    static func convertAudio(_ url: URL, to format: AudioFormat, progress: @escaping ProgressHandler) async throws -> URL {
        if format == .m4a {
            return try await export(
                AVURLAsset(url: url), beside: url, presets: [AVAssetExportPresetAppleM4A],
                type: .m4a, fileExtension: "m4a", progress: progress
            )
        }
        let output = ImageEngine.outputURL(for: url, fileExtension: format.fileExtension)
        do {
            try rewrite(url, to: output, as: format, progress: progress)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Decodes the file and writes it again as uncompressed or lossless audio,
    /// keeping its sample rate and channels.
    private static func rewrite(_ url: URL, to output: URL, as format: AudioFormat, progress: ProgressHandler) throws {
        let input = try AVAudioFile(forReading: url)
        let source = input.processingFormat

        var settings: [String: Any] = [
            AVSampleRateKey: source.sampleRate,
            AVNumberOfChannelsKey: Int(source.channelCount),
        ]
        if format == .flac {
            settings[AVFormatIDKey] = Int(kAudioFormatFLAC)
            settings[AVEncoderBitDepthHintKey] = 16
        } else {
            settings[AVFormatIDKey] = Int(kAudioFormatLinearPCM)
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = (format == .aiff)
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        let file = try AVAudioFile(
            forWriting: output, settings: settings,
            commonFormat: source.commonFormat, interleaved: source.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 65_536) else {
            throw KiwiError("Couldn't read \(url.lastPathComponent).")
        }

        let total = max(1, input.length)
        var reported = 0.0
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try file.write(from: buffer)
            let fraction = Double(input.framePosition) / Double(total)
            if fraction - reported >= 0.02 {
                reported = fraction
                progress(fraction)
            }
        }
    }
}
