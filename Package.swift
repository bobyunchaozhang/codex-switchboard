// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSwitchboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexSwitchboard", targets: ["SwitchboardApp"])
    ],
    targets: [
        .target(name: "ProcessEnvironment", publicHeadersPath: "include"),
        .target(name: "SwitchboardCore", dependencies: ["ProcessEnvironment"]),
        .executableTarget(name: "SwitchboardApp", dependencies: ["SwitchboardCore", "AccountRuntime"]),
        .target(name: "AccountRuntime", dependencies: ["SwitchboardCore"]),
        .executableTarget(name: "AccountRuntimeChecks", dependencies: ["AccountRuntime", "SwitchboardCore"], path: "Tests/AccountRuntimeChecks"),
        .executableTarget(name: "SwitchboardChecks", dependencies: ["SwitchboardCore"], path: "Tests/SwitchboardCoreTests")
    ]
)
