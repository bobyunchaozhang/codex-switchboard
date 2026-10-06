import Combine
import Foundation
import SwitchboardCore

@MainActor
public final class PreviewController: ObservableObject {
    @Published public private(set) var accounts: [PreviewAccount] = []
    @Published public private(set) var readings: [UUID: Reading] = [:]
    @Published public private(set) var current: UUID?
    @Published public private(set) var busy = false
    @Published public private(set) var signingIn = false
    @Published public private(set) var needsRecovery = false
    @Published public private(set) var message = "Add both accounts using official sign-in, then open the test environment."
    @Published public private(set) var failed = false
    public var home: URL { store.home }
    public var project: URL { store.project }
    public var canReturn: Bool { state.originalHome != nil }
    private let store: PreviewStore
    private let runtime: PreviewRuntime
    private var state: PreviewState
    private var cancellation: CancellationFlag?

    public convenience init() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Switchboard Preview")
        try self.init(store: PreviewStore(root: root), runtime: InstalledRuntime())
    }
    init(store: PreviewStore, runtime: PreviewRuntime) throws {
        self.store = store; self.runtime = runtime; state = try store.load()
        publish()
    }
    private func commit(_ change: (inout PreviewState) -> Void) throws {
        var next = state; change(&next); try store.save(next); state = next; publish()
    }
    private func publish() {
        accounts = state.accounts
        needsRecovery = state.worker != nil || state.switching != nil
        if runtime.presence.home != store.home.path || needsRecovery { current = nil }
    }
    private func account(_ id: UUID) throws -> PreviewAccount {
        guard let value = state.accounts.first(where: { $0.id == id }) else { throw PreviewError.identity }
        return value
    }
    private func matches(_ reading: Reading, _ account: PreviewAccount) -> Bool {
        !reading.needsLogin && reading.identity?.matches(account.email) == true
    }
    private func run(allowRecovery: Bool = false, _ operation: () async throws -> Void) async {
        guard !busy else { return }
        guard allowRecovery || !needsRecovery else { message = PreviewError.recovery.localizedDescription; failed = true; return }
        busy = true; failed = false
        defer { busy = false; signingIn = false; cancellation = nil; publish() }
        do { try await operation() }
        catch {
            // Reload only persisted decisions after a partial disk failure.
            if let persisted = try? store.load() { state = persisted }
            message = error.localizedDescription; failed = true; current = nil
        }
    }
    public func cancelSignIn() { cancellation?.cancel() }

    public func addAccount(replacing id: UUID? = nil) async {
        await run {
            if let id, id == state.active {
                guard runtime.presence.home != store.home.path else { throw PreviewError.renewCurrent }
                try await runtime.quiescent(home: store.home.path)
                try await captureActive()
                try commit { $0.active = nil }
            }
            message = "Waiting for official sign-in…"; signingIn = true
            let worker = try beginWorker(accountID: id, login: true)
            let home = store.workerHome(worker)
            let flag = CancellationFlag(); cancellation = flag
            do {
                try await runtime.validate(home: home.path)
                _ = try await runtime.login(home: home.path, cancellation: flag)
                try await finishWorker()
                message = "Account saved. Open an account to start the desktop test."
            } catch {
                // A completed browser callback may already have created a cache.
                // Keep that journal for recovery instead of discarding a successful login.
                try await runtime.quiescent(home: home.path)
                if try store.credential(home) == nil { try discardWorker() }
                throw error
            }
        }
    }

    public func refresh() async {
        await run {
            message = "Refreshing accounts…"
            for item in state.accounts {
                let reading = try await readAccount(item.id)
                readings[item.id] = reading
            }
            let verified = state.active.flatMap { id in
                readings[id].flatMap { reading in
                    state.accounts.first(where: { $0.id == id && matches(reading, $0) })?.id
                }
            }
            current = runtime.presence.home == store.home.path ? verified : nil
            message = readings.values.contains(where: { $0.usage == nil })
                ? "Refresh finished. Unavailable usage is shown explicitly." : "Accounts refreshed."
        }
    }

    private func beginWorker(accountID: UUID?, login: Bool) throws -> WorkerJournal {
        guard state.worker == nil, state.switching == nil else { throw PreviewError.recovery }
        let worker = WorkerJournal(id: UUID(), accountID: accountID, login: login, materialized: false)
        let home = store.workerHome(worker)
        try store.prepare(home)
        try commit { $0.worker = worker }
        return worker
    }

    private func readAccount(_ id: UUID) async throws -> Reading {
        let item = try account(id)
        if state.active == id {
            try await runtime.validate(home: store.home.path)
            let reading = await runtime.read(home: store.home.path)
            // The live cache is authoritative. Never install an older vault snapshot here.
            return reading
        }
        if item.needsLogin { return Reading(identity: nil, usage: nil, needsLogin: true) }
        let worker = try beginWorker(accountID: id, login: false)
        let home = store.workerHome(worker)
        guard let credential = try store.vault.read(id.uuidString) else {
            try discardWorker(); return Reading(identity: nil, usage: nil, needsLogin: true)
        }
        try store.install(credential, in: home)
        try commit { $0.worker?.materialized = true }
        try await runtime.validate(home: home.path)
        let reading = await runtime.read(home: home.path)
        try await finishWorker(reading: reading)
        return reading
    }

    private func finishWorker(reading supplied: Reading? = nil) async throws {
        guard let worker = state.worker else { return }
        if worker.completed { try discardWorker(); return }
        let home = store.workerHome(worker)
        try await runtime.quiescent(home: home.path)
        guard let credential = try store.credential(home) else {
            if worker.materialized, let id = worker.accountID {
                try store.saveCredential(nil, id: id)
                try commit { value in
                    if let i = value.accounts.firstIndex(where: { $0.id == id }) { value.accounts[i].needsLogin = true }
                    value.worker?.completed = true
                }
            }
            try discardWorker(); return
        }
        let reading: Reading
        if let supplied { reading = supplied }
        else { try await runtime.validate(home: home.path); reading = await runtime.read(home: home.path) }
        // The official read may refresh the cache; capture only after its process exits.
        try await runtime.quiescent(home: home.path)
        let latest = try store.credential(home)
        if worker.login {
            guard let identity = reading.identity, !reading.needsLogin, let latest else { throw PreviewError.login }
            if let expected = worker.accountID, !(try account(expected)).email.caseInsensitiveEquals(identity.email) {
                try discardWorker(); throw PreviewError.identity
            }
            let existing = state.accounts.first(where: { identity.matches($0.email) })
            if existing?.id == state.active, existing != nil {
                try discardWorker(); throw SwitchboardFailure.duplicateAccount
            }
            let profile = existing ?? PreviewAccount(email: identity.email, plan: identity.plan)
            try store.saveCredential(latest, id: profile.id)
            try commit { value in
                if let i = value.accounts.firstIndex(where: { $0.id == profile.id }) {
                    value.accounts[i].needsLogin = false; value.accounts[i].plan = identity.plan
                } else { value.accounts.append(profile) }
                value.worker?.completed = true
            }
            readings[profile.id] = reading
        } else if let id = worker.accountID {
            if let identity = reading.identity, !identity.matches(try account(id).email) {
                // Keep a mismatched cache out of the saved account.
                try discardWorker(); throw PreviewError.identity
            }
            try store.saveCredential(latest, id: id)
            try commit { value in
                if let i = value.accounts.firstIndex(where: { $0.id == id }) {
                    value.accounts[i].needsLogin = reading.needsLogin || latest == nil
                }
                value.worker?.completed = true
            }
        }
        _ = credential // Credential bytes are never included in diagnostics.
        try discardWorker()
    }

    private func discardWorker() throws {
        guard let worker = state.worker else { return }
        // Persist completion before deleting: a crash cannot erase an already saved vault entry.
        if !worker.completed { try commit { $0.worker?.completed = true } }
        if FileManager.default.fileExists(atPath: store.workerHome(worker).path) {
            try FileManager.default.removeItem(at: store.workerHome(worker))
        }
        try commit { $0.worker = nil }
    }

    /// Called only by a deliberate UI action. Automated tests supply a fake desktop.
    public func switchTo(_ id: UUID) async {
        await run {
            try runtime.checkLegacy()
            let target = try account(id)
            if state.active == id, runtime.presence.home == store.home.path {
                readings[id] = try await readAccount(id)
                guard let reading = readings[id], matches(reading, target) else { throw PreviewError.login }
                current = id; message = "This account is already open in the test environment."; return
            }
            message = "Checking the target account…"
            let checked = try await readAccount(id)
            readings[id] = checked
            guard matches(checked, target) else { throw PreviewError.login }
            try await runtime.validate(home: store.home.path)
            let presence = runtime.presence
            if presence == .unknown { throw PreviewError.environment }
            let previousHome = presence.home
            if let previousHome, previousHome != store.home.path {
                try commit { $0.originalHome = previousHome }
            } else if state.originalHome == nil {
                let standardHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
                try commit { $0.originalHome = standardHome }
            }
            message = "Restarting Codex in the fixed test environment…"
            do {
                try await runtime.activate(home: store.home.path) { [self] in
                    try await runtime.quiescent(home: store.home.path)
                    try await captureActive()
                    let previous = try store.credential(store.home)
                    if let previous { try store.vault.write(previous, name: "rollback") }
                    else { try store.vault.remove("rollback") }
                    guard let next = try store.vault.read(id.uuidString) else { throw PreviewError.login }
                    try commit { $0.switching = SwitchJournal(target: id, previousAccount: state.active,
                        previousHome: previousHome, hadCredential: previous != nil) }
                    try store.install(next, in: store.home)
                }
                let reading = await runtime.read(home: store.home.path)
                guard runtime.presence.home == store.home.path, matches(reading, target) else { throw PreviewError.identity }
                try commit { $0.active = id; $0.switching = nil }
                try store.vault.remove("rollback")
                readings[id] = reading; current = id
                message = "Login verified. Check the account in Codex and continue the same test chat."
            } catch {
                let original = error
                if state.switching != nil {
                    do { try await rollback(); message = "Switch failed; the previous environment was restored." }
                    catch { throw PreviewError.recovery }
                }
                throw original
            }
        }
    }

    private func captureActive() async throws {
        guard let id = state.active else { return }
        let reading = await runtime.read(home: store.home.path)
        try await runtime.quiescent(home: store.home.path)
        if let identity = reading.identity, !identity.matches(try account(id).email) { throw PreviewError.identity }
        if reading.identity == nil && !reading.needsLogin { throw PreviewError.identity }
        try store.saveCredential(try store.credential(store.home), id: id)
        try commit { value in
            if let i = value.accounts.firstIndex(where: { $0.id == id }) { value.accounts[i].needsLogin = reading.needsLogin }
        }
    }

    private func rollback() async throws {
        guard let journal = state.switching else { return }
        let destination = journal.previousHome ?? state.originalHome
        // With no previous desktop, return to the standard home; no production files are written.
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        try await runtime.activate(home: destination ?? fallback) { [self] in
            try await runtime.quiescent(home: store.home.path)
            let live = await runtime.read(home: store.home.path)
            try await runtime.quiescent(home: store.home.path)
            if let identity = live.identity,
               let owner = state.accounts.first(where: { identity.matches($0.email) }) {
                try store.saveCredential(try store.credential(store.home), id: owner.id)
            }
            let previousIsLive = journal.previousAccount.flatMap { id in
                state.accounts.first(where: { $0.id == id && live.identity?.matches($0.email) == true })
            } != nil
            let saved = try previousIsLive ? store.credential(store.home) : store.vault.read("rollback")
            if journal.hadCredential && saved == nil { throw PreviewError.storage }
            try store.install(journal.hadCredential ? saved : nil, in: store.home)
        }
        try commit { $0.active = journal.previousAccount; $0.switching = nil }
        try store.vault.remove("rollback")
        current = nil
    }

    public func recover() async {
        await run(allowRecovery: true) {
            try runtime.checkLegacy()
            if state.worker != nil { try await finishWorker() }
            if state.switching != nil { try await rollback() }
            message = "Recovery completed. Refresh accounts before continuing."
        }
    }

    public func returnToOriginal() async {
        await run {
            try runtime.checkLegacy()
            guard let original = state.originalHome, original != store.home.path else { throw PreviewError.environment }
            if runtime.presence == .unknown { throw PreviewError.environment }
            try await runtime.activate(home: original) { [self] in
                try await runtime.quiescent(home: store.home.path)
                // No cache replacement occurs when leaving the test environment.
                // Keep the work cache authoritative, including while offline.
            }
            current = nil
            message = "Original environment restored. You can reopen the regular Codex Switchboard."
        }
    }
}

private extension String {
    func caseInsensitiveEquals(_ other: String) -> Bool { caseInsensitiveCompare(other) == .orderedSame }
}
