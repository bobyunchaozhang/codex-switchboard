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
        var blocked: [CredentialWriters.Entry] = []
        repeat {
            blocked = try CredentialWriters.blockers(in: CredentialWriters.inventory(), home: home,
                application: desktop.application, cli: desktop.executable)
            if blocked.isEmpty { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        throw CredentialWriterBusy(pids: blocked.map(\.pid))
    }
}
