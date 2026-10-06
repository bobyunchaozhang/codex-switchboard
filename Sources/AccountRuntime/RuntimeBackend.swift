import AppKit
import Foundation
import SwitchboardCore

@MainActor
protocol RuntimeBackend {
    var presence: DesktopPresence { get }
    func validate(home: String) async throws
    func read(home: String) async -> Reading
    func login(home: String, cancellation: CancellationFlag) async throws -> Identity
    func logout(home: String, email: String, stillNonCurrent: @escaping @MainActor () -> Bool) async throws
    func activate(home: String, change: @escaping () async throws -> Void) async throws
    func quiescent(home: String) async throws
    func checkLegacy() throws
}

@MainActor
final class InstalledRuntime: RuntimeBackend {
    private let desktop: Desktop
    private let service: CodexService
    init() throws {
        desktop = try Desktop()
        service = CodexService(executable: desktop.executable)
    }
    var presence: DesktopPresence { desktop.observe() }
    func validate(home: String) async throws {
        do { try await AuthBackend.validateConfiguration(executable: desktop.executable, home: home) }
        catch { throw AccountFailure.policy }
    }
    func read(home: String) async -> Reading { await service.read(home: home) }
    func login(home: String, cancellation: CancellationFlag) async throws -> Identity {
        try await service.login(home: home, cancellation: cancellation) { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
    }
    func logout(home: String, email: String, stillNonCurrent: @escaping @MainActor () -> Bool) async throws {
        try await service.logout(SavedAccount(home: home, email: email)) {
            DispatchQueue.main.sync { MainActor.assumeIsolated { stillNonCurrent() } }
        }
    }
    func activate(home: String, change: @escaping () async throws -> Void) async throws {
        try await desktop.activate(home: home, beforeLaunch: change)
    }
    func checkLegacy() throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex-switchboard.preview").isEmpty else {
            throw AccountFailure.legacyApp
        }
    }
    func quiescent(home: String) async throws {
        let deadline = Date().addingTimeInterval(6)
        repeat {
            if try !hasWriter(home: home) { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        throw AccountFailure.writers
    }
    private func hasWriter(home: String) throws -> Bool {
        // Process names only: never request command arguments or environment dumps.
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-U", String(getuid()), "-o", "pid=,comm="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
            throw AccountFailure.writers
        }
        for line in output.split(separator: "\n") {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]), pid != getpid() else { continue }
            let name = fields[1].lowercased()
            guard name.contains("codex") || name.contains("chatgpt.app/") else { continue }
            guard let observed = ProcessHome.read(pid: pid) else {
                // Exited processes are harmless; a live unreadable process is not.
                if kill(pid, 0) == 0 { return true }
                continue
            }
            if observed == normalizedHome(home) { return true }
        }
        return false
    }
}
