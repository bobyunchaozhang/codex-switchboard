// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSwitchboard",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexSwitchboard", targets: ["SwitchboardApp"])],
    targets: [
        .target(name: "ProcessEnvironment", publicHeadersPath: "include"),
        .target(name: "SwitchboardCore", dependencies: ["ProcessEnvironment"]),
        .executableTarget(name: "SwitchboardApp", dependencies: ["SwitchboardCore"]),
        .executableTarget(name: "SwitchboardChecks", dependencies: ["SwitchboardCore"], path: "Tests/SwitchboardCoreTests")
    ]
)
