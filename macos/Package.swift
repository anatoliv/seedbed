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
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.58.0")
    ],
    targets: [
        .executableTarget(
            name: "Seedbed",
            dependencies: [.product(name: "Sentry", package: "sentry-cocoa")],
            path: "Sources/Seedbed"
        )
    ]
)
