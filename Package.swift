// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceTimeAudioBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FaceTimeAudioBridge",
            path: "Sources/FaceTimeAudioBridge",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
