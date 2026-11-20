import Foundation

/// Makes ZIP archives with Foundation's own archiver, the one behind
/// "Compress" in Finder. No external tool is run.
///
/// Kiwi only creates archives. Unpacking one means trusting the paths and
/// links inside it, and macOS already does that when you double-click a ZIP,
/// so Kiwi leaves it to the system.
enum Archive {
    /// One folder becomes `name.zip`. Anything else is gathered in a folder
    /// first, so the archive unpacks into a single tidy folder.
    static func zip(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else {
            throw KiwiError("Nothing to compress.")
        }
        let fm = FileManager.default
        let parent = first.deletingLastPathComponent()
        let single = urls.count == 1
        let name = single ? first.deletingPathExtension().lastPathComponent : "Archive"
        let output = CaptureStore.uniqueURL(in: parent, name: name, ext: "zip")

        let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if single, isFolder {
            try Coordination.withZippedCopy(of: first) { zipped in
                try fm.copyItem(at: zipped, to: output)
            }
            return output
        }

        // Copies on the same volume are clones, so staging costs no extra space.
        let work = CaptureStore.cacheDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        let staging = work.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }

        for url in urls {
            try Task.checkCancellation()
            var target = staging.appendingPathComponent(url.lastPathComponent)
            var counter = 2
            while fm.fileExists(atPath: target.path) {
                target = staging.appendingPathComponent("\(counter) \(url.lastPathComponent)")
                counter += 1
            }
            try fm.copyItem(at: url, to: target)
        }
        try Coordination.withZippedCopy(of: staging) { zipped in
            try fm.copyItem(at: zipped, to: output)
        }
        return output
    }
}
