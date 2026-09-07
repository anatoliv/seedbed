// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Seedbed",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Crash + error reporting. Opt-in and DSN-gated at runtime — see
        // Sources/Seedbed/CrashReporting.swift. Linked unconditionally because
        // a build flag would mean the shipped binary and the one tested here
        // are different binaries.
        // Pinned exactly, not by range. This is a signed, notarized app whose
        // crash reporting is privacy-hardened against option names and defaults
        // that a minor release can move, and a public checkout should build the
        // binary that was tested rather than whatever resolved that morning.
        // The sibling projects pin the same way for the same reason.
        .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "8.58.4"),
        // Auto-update for copies installed from a release. A copy built out of
        // the checkout does not use it — see Updater.swift.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Seedbed",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Seedbed",
            linkerSettings: [
                // Find Sparkle.framework inside the packaged .app at runtime.
                // Without this the binary links but cannot launch from the
                // bundle, which is the only place it is ever run.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
