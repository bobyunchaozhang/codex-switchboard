import AppKit
import Foundation
import ProcessEnvironment

public enum ProcessHome {
    public static func read(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 32_768)
        let found = sb_environment_value(pid, "CODEX_HOME", &buffer, buffer.count)
        if found == 1 {
            let value = String(cString: buffer)
            guard value.hasPrefix("/") else { return nil }
            return normalizedHome(value)
        }
        guard found == 0, sb_environment_value(pid, "HOME", &buffer, buffer.count) == 1 else { return nil }
        let home = String(cString: buffer)
        guard home.hasPrefix("/") else { return nil }
        return normalizedHome(home + "/.codex")
    }
}

@MainActor
public final class Desktop {
    public let application: URL
    public let executable: URL
    private let bundleID = "com.openai.codex"

    public init() throws {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID else { throw SwitchboardFailure.desktopMissing }
        application = url
        let candidates = ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"]
        guard let cli = candidates.map({ url.appendingPathComponent($0) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw SwitchboardFailure.desktopMissing }
        executable = cli
    }

    public func observe() -> DesktopPresence {
        let apps = runningApplications()
        guard !apps.isEmpty else { return .stopped }
        guard apps.count == 1, let app = apps.first, let home = ProcessHome.read(pid: app.processIdentifier) else { return .unknown }
        return .running(pid: app.processIdentifier, home: home)
    }

    public func activate(home: String, beforeLaunch: (() async throws -> Void)? = nil) async throws {
        let previousHome = observe().home
        let apps = runningApplications()
        guard apps.count <= 1 else { throw SwitchboardFailure.currentUnknown }
        if let app = apps.first {
            guard app.terminate() else { throw SwitchboardFailure.quitFailed }
            let deadline = Date().addingTimeInterval(20)
            while !app.isTerminated && Date() < deadline { try await Task.sleep(nanoseconds: 150_000_000) }
            guard app.isTerminated else { throw SwitchboardFailure.quitFailed }
        }
        guard runningApplications().isEmpty else { throw SwitchboardFailure.quitFailed }
        do {
            try await beforeLaunch?()
            try await launch(home: home)
        } catch {
            // A failed setup must not strand the user with the desktop closed.
            if runningApplications().isEmpty, let previousHome { try? await launch(home: previousHome) }
            throw error
        }
    }

    private func launch(home: String) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = ["CODEX_HOME": home]
        configuration.activates = true
        let launched: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: SwitchboardFailure.launchFailed) }
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if case .running(let pid, let actualHome) = observe(), pid == launched.processIdentifier,
               actualHome == normalizedHome(home) { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw SwitchboardFailure.currentUnknown
    }

    private func runningApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.bundleURL?.resolvingSymlinksInPath() == application.resolvingSymlinksInPath() && !$0.isTerminated
        }
    }
}
