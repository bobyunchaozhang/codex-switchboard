// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSwitchboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexSwitchboard", targets: ["SwitchboardApp"]),
        .executable(name: "SwitchboardPreview", targets: ["SwitchboardPreview"])
    ],
    targets: [
        .target(name: "ProcessEnvironment", publicHeadersPath: "include"),
        .target(name: "SwitchboardCore", dependencies: ["ProcessEnvironment"]),
        .executableTarget(name: "SwitchboardApp", dependencies: ["SwitchboardCore"]),
        .target(name: "PreviewCore", dependencies: ["SwitchboardCore"]),
        .executableTarget(name: "SwitchboardPreview", dependencies: ["PreviewCore", "SwitchboardCore"]),
        .executableTarget(name: "PreviewChecks", dependencies: ["PreviewCore", "SwitchboardCore"], path: "Tests/PreviewChecks"),
        .executableTarget(name: "SwitchboardChecks", dependencies: ["SwitchboardCore"], path: "Tests/SwitchboardCoreTests")
    ]
)
