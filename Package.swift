// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WYSIWAG",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WYSIWAGCore", targets: ["WYSIWAGCore"]),
        .executable(name: "WYSIWAG", targets: ["WYSIWAGApp"]),
        .executable(name: "wysiwag-cli", targets: ["WYSIWAGCLI"])
    ],
    targets: [
        .target(name: "WYSIWAGCore", resources: [.copy("Resources/ocr-fixture.png"), .copy("Resources/ocr-changed.png")]),
        .executableTarget(name: "WYSIWAGApp", dependencies: ["WYSIWAGCore"],
                          resources: [.process("Resources")]),
        .executableTarget(name: "WYSIWAGCLI", dependencies: ["WYSIWAGCore"]),
        .testTarget(name: "WYSIWAGCoreTests", dependencies: ["WYSIWAGCore"])
    ]
)
