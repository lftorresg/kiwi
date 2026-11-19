// swift-tools-version: 6.2
import PackageDescription

// Kiwi has no package dependencies, on purpose: everything it links ships with macOS.
let package = Package(
    name: "Kiwi",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Kiwi",
            path: "Sources/Kiwi",
            swiftSettings: [
                // Reports every use of an unsafe construct (raw pointers, unchecked
                // casts) as a warning, so the unsafe surface stays small and visible.
                .strictMemorySafety()
            ]
        )
    ],
    // Swift 5 language mode keeps concurrency diagnostics as warnings.
    swiftLanguageModes: [.v5]
)
