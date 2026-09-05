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
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.58.0"),
        // Auto-update for copies installed from a release. A copy built out of
        // the checkout does not use it — see Updater.swift.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
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
