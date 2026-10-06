import Combine
import Foundation
import SwitchboardCore

@MainActor
public final class AccountController: ObservableObject {
    @Published public private(set) var accounts: [AccountProfile] = []
    @Published public private(set) var readings: [UUID: Reading] = [:]
    @Published public private(set) var current: UUID?
    @Published public private(set) var busy = false
    @Published public private(set) var signingIn = false
    @Published public private(set) var needsRecovery = false
    @Published public private(set) var message = ""
    @Published public private(set) var failed = false
    public var home: URL { store.home }
    public var presence: DesktopPresence { runtime.presence }
    @Published public private(set) var currentEmail: String?
    private let store: RuntimeStore
    private let runtime: RuntimeBackend
    private var state: RuntimeState
    private var cancellation: CancellationFlag?

    public convenience init() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Switchboard/Runtime")
        try self.init(store: RuntimeStore(root: root, defaultHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")), runtime: InstalledRuntime())
    }
    init(store: RuntimeStore, runtime: RuntimeBackend) throws {
        self.store = store; self.runtime = runtime; state = try store.load()
        publish()
    }
    private func commit(_ change: (inout RuntimeState) -> Void) throws {
        var next = state; change(&next); try store.save(next); state = next; publish()
    }
    private func publish() {
        accounts = state.accounts
        needsRecovery = state.worker != nil || state.switching != nil || state.renewal != nil
        if runtime.presence.home != store.home.path || needsRecovery { current = nil }
    }
    private func account(_ id: UUID) throws -> AccountProfile {
        guard let value = state.accounts.first(where: { $0.id == id }) else { throw AccountFailure.identity }
        return value
    }
    private func matches(_ reading: Reading, _ account: AccountProfile) -> Bool {
        !reading.needsLogin && reading.identity?.matches(account.email) == true
    }
    private func run(operation label: String, allowRecovery: Bool = false, _ operation: () async throws -> Void) async {
        guard !busy else { return }
        guard allowRecovery || !needsRecovery else { message = AccountFailure.recovery.localizedDescription; failed = true; return }
        busy = true; failed = false
        defer { busy = false; signingIn = false; cancellation = nil; publish() }
        do { try await operation() }
        catch {
            // Reload only persisted decisions after a partial disk failure.
            if let persisted = try? store.load() { state = persisted }
            message = label + " failed. " + error.localizedDescription; failed = true; current = nil
        }
    }
    public func cancelSignIn() { cancellation?.cancel() }

    public func canRemove(_ id: UUID) -> Bool {
        guard !busy, !needsRecovery, runtime.presence.home == store.home.path,
              let email = currentEmail, let item = state.accounts.first(where: { $0.id == id }) else { return false }
        return !item.email.caseInsensitiveEquals(email)
    }

    public func remove(_ id: UUID) async {
        guard canRemove(id) else { message = SwitchboardFailure.currentAccount.localizedDescription; failed = true; return }
        await run(operation: "Remove account") {
            let item = try account(id)
            let checked = await runtime.read(home: store.home.path)
            guard runtime.presence.home == store.home.path, let identity = checked.identity,
                  !identity.matches(item.email) else { throw SwitchboardFailure.currentUnknown }
            let worker = try beginWorker(accountID: id, login: false)
            try commit { $0.worker?.removing = true }
            let home = store.workerHome(worker)
            if let credential = try store.vault.read(id.uuidString) { try store.install(credential, in: home) }
            try commit { $0.worker?.materialized = true }
            try await finishRemoval()
            message = ""
        }
    }

    private func finishRemoval() async throws {
        guard let worker = state.worker, let id = worker.accountID else { throw AccountFailure.storage }
        guard worker.materialized else { try discardWorker(); return }
        let item = try account(id), home = store.workerHome(worker)
        let observed = runtime.presence
        let active = await runtime.read(home: store.home.path)
        guard observed.home == store.home.path, observed == runtime.presence,
              let identity = active.identity else { throw SwitchboardFailure.currentUnknown }
        if identity.matches(item.email) {
            try discardWorker(); throw SwitchboardFailure.currentAccount
        }
        let activeCache = try store.credential(store.home)
        try await runtime.validate(home: home.path)
        try await runtime.logout(home: home.path, email: item.email) { [self] in
            runtime.presence == observed && (try? store.credential(store.home)) == activeCache
        }
        let after = await runtime.read(home: home.path)
        guard after.identity == nil, after.needsLogin else { throw AccountFailure.identity }
        try await runtime.quiescent(home: home.path)
        try store.saveCredential(nil, id: id)
        try commit { value in
            value.accounts.removeAll { $0.id == id }
            if value.active == id { value.active = nil }
            value.worker?.completed = true
        }
        readings.removeValue(forKey: id)
        try discardWorker()
    }

    /// One-time upgrade. Never called by a routine account switch.
    public func migrateLegacy() async {
        await run(operation: "Migration") {
            guard state.accounts.isEmpty else { message = "Migration already completed."; return }
            try runtime.checkLegacy()
            let legacy = try AccountStore().load() ?? []
            let sources = legacy.filter { normalizedHome($0.home) != store.home.path }
            guard runtime.presence == .stopped || runtime.presence.home == store.home.path else { throw AccountFailure.environment }
            for item in sources { try await runtime.quiescent(home: item.home) }
            let backup = store.root.deletingLastPathComponent().appendingPathComponent("Recovery/0.3.3")
            try PrivateFile.directory(backup)
            for name in ["config.toml", ".codex-global-state.json"] {
                let file = store.home.appendingPathComponent(name), saved = backup.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: saved.path) {
                    try PrivateFile.write(Data(contentsOf: file), to: saved)
                }
            }
            let registry = AccountStore().file
            if FileManager.default.fileExists(atPath: registry.path), !FileManager.default.fileExists(atPath: backup.appendingPathComponent("accounts.json").path) {
                try PrivateFile.write(Data(contentsOf: registry), to: backup.appendingPathComponent("accounts.json"))
            }
            let desktop = try Desktop()
            try await AuthBackend.ensureFileConfiguration(executable: desktop.executable, home: store.home.path)
            let currentReading = await runtime.read(home: store.home.path)
            var imported: [AccountProfile] = []
            for item in legacy {
                let reading = normalizedHome(item.home) == store.home.path ? currentReading : await runtime.read(home: item.home)
                guard let identity = reading.identity, identity.matches(item.email) else { throw AccountFailure.identity }
                if normalizedHome(item.home) != store.home.path { try await runtime.quiescent(home: item.home) }
                guard let credential = try store.credential(URL(fileURLWithPath: item.home)) else { throw AccountFailure.login }
                try store.saveCredential(credential, id: item.id)
                imported.append(AccountProfile(id: item.id, email: identity.email, plan: identity.plan))
            }
            if imported.isEmpty, let identity = currentReading.identity {
                let item = AccountProfile(email: identity.email, plan: identity.plan)
                if let credential = try store.credential(store.home) { try store.saveCredential(credential, id: item.id) }
                imported.append(item)
            }
            let count = try await LocalHistoryMigration.importMissing(executable: desktop.executable,
                target: store.home.path, sources: sources.map(\.home), backup: backup)
            try commit { value in
                value.accounts = imported
                value.active = imported.first(where: { currentReading.identity?.matches($0.email) == true })?.id
                value.originalHome = store.home.path
            }
            message = "Migration completed: \(imported.count) accounts, \(count) additional local chats."
        }
    }

    public func addAccount(replacing id: UUID? = nil) async {
        await run(operation: "Sign in") {
            message = "Waiting for official sign-in…"; signingIn = true
            let worker = try beginWorker(accountID: id, login: true)
            let home = store.workerHome(worker)
            let flag = CancellationFlag(); cancellation = flag
            do {
                try await runtime.validate(home: home.path)
                _ = try await runtime.login(home: home.path, cancellation: flag)
                try await finishWorker()
                if let renewal = state.renewal { try await performSwitch(renewal) }
                else { message = "" }
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
        await run(operation: "Refresh accounts") {
            message = "Refreshing accounts…"
            let observed = runtime.presence
            if observed.home == store.home.path {
                let activeReading = await runtime.read(home: store.home.path)
                currentEmail = activeReading.identity?.email
                if let identity = activeReading.identity, let found = state.accounts.first(where: { identity.matches($0.email) }), found.id != state.active {
                    try commit { $0.active = found.id }
                }
            } else { currentEmail = nil }
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
            if runtime.presence != observed { current = nil; currentEmail = nil }
            message = ""
        }
    }

    private func beginWorker(accountID: UUID?, login: Bool) throws -> WorkerJournal {
        guard state.worker == nil, state.switching == nil else { throw AccountFailure.recovery }
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
        if worker.removing == true { try await finishRemoval(); return }
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
            guard let identity = reading.identity, !reading.needsLogin, let latest else { throw AccountFailure.login }
            if let expected = worker.accountID, !(try account(expected)).email.caseInsensitiveEquals(identity.email) {
                try discardWorker(); throw AccountFailure.identity
            }
            let existing = state.accounts.first(where: { identity.matches($0.email) })
            if existing?.id == state.active, existing != nil, worker.accountID != state.active {
                try discardWorker(); throw SwitchboardFailure.duplicateAccount
            }
            let profile = existing ?? AccountProfile(email: identity.email, plan: identity.plan)
            if profile.id == state.active { try store.vault.write(latest, name: "renewal") }
            else { try store.saveCredential(latest, id: profile.id) }
            try commit { value in
                if let i = value.accounts.firstIndex(where: { $0.id == profile.id }) {
                    value.accounts[i].needsLogin = false; value.accounts[i].plan = identity.plan
                } else { value.accounts.append(profile) }
                if profile.id == value.active { value.renewal = profile.id }
                value.worker?.completed = true
            }
            readings[profile.id] = reading
        } else if let id = worker.accountID {
            if let identity = reading.identity, !identity.matches(try account(id).email) {
                // Keep a mismatched cache out of the saved account.
                try discardWorker(); throw AccountFailure.identity
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
        await run(operation: "Switch account") { try await performSwitch(id) }
    }

    private func performSwitch(_ id: UUID) async throws {
        try runtime.checkLegacy()
        let target = try account(id)
        if state.active == id, state.renewal != id, runtime.presence.home == store.home.path {
            readings[id] = try await readAccount(id)
            guard let reading = readings[id], matches(reading, target) else { throw AccountFailure.login }
            current = id; message = ""; return
        }
        message = "Checking the target account…"
        if state.renewal != id {
            let checked = try await readAccount(id)
            readings[id] = checked
            guard matches(checked, target) else { throw AccountFailure.login }
        }
        try await runtime.validate(home: store.home.path)
        let presence = runtime.presence
        if presence == .unknown { throw AccountFailure.environment }
        let previousHome = presence.home
        if let previousHome, previousHome != store.home.path {
            try commit { $0.originalHome = previousHome }
        } else if state.originalHome == nil {
            let standardHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            try commit { $0.originalHome = standardHome }
        }
        message = "Switching account…"
        do {
            try await runtime.activate(home: store.home.path) { [self] in
                try await runtime.quiescent(home: store.home.path)
                try await captureActive()
                let previous = try store.credential(store.home)
                if let previous { try store.vault.write(previous, name: "rollback") }
                else { try store.vault.remove("rollback") }
                guard let next = try store.vault.read(state.renewal == id ? "renewal" : id.uuidString) else { throw AccountFailure.login }
                try commit { $0.switching = SwitchJournal(target: id, previousAccount: state.active,
                    previousHome: previousHome, hadCredential: previous != nil, usingRenewal: state.renewal == id) }
                try store.install(next, in: store.home)
            }
            let reading = await runtime.read(home: store.home.path)
            guard runtime.presence.home == store.home.path, matches(reading, target) else { throw AccountFailure.identity }
            try commit { value in
                value.active = id; value.switching = nil; value.renewal = nil
                if let i = value.accounts.firstIndex(where: { $0.id == id }) { value.accounts[i].needsLogin = false }
            }
            try store.vault.remove("rollback")
            try store.vault.remove("renewal")
            currentEmail = reading.identity?.email
            readings[id] = reading; current = id
            message = ""
        } catch {
            let original = error
            if state.switching != nil {
                do { try await rollback(); message = "Switch failed; the previous environment was restored." }
                catch { throw AccountFailure.recovery }
            }
            throw original
        }
    }

    private func captureActive() async throws {
        guard let id = state.active else { return }
        let reading = await runtime.read(home: store.home.path)
        try await runtime.quiescent(home: store.home.path)
        if let identity = reading.identity, !identity.matches(try account(id).email) { throw AccountFailure.identity }
        if reading.identity == nil && !reading.needsLogin { throw AccountFailure.identity }
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
                let latest = try store.credential(store.home)
                try store.saveCredential(latest, id: owner.id)
                if journal.usingRenewal == true, owner.id == journal.target, let latest {
                    try store.vault.write(latest, name: "renewal")
                }
            }
            let previousIsLive = journal.previousAccount.flatMap { id in
                state.accounts.first(where: { $0.id == id && live.identity?.matches($0.email) == true })
            } != nil
            let saved = try previousIsLive ? store.credential(store.home) : store.vault.read("rollback")
            if journal.hadCredential && saved == nil { throw AccountFailure.storage }
            try store.install(journal.hadCredential ? saved : nil, in: store.home)
        }
        try commit { $0.active = journal.previousAccount; $0.switching = nil }
        try store.vault.remove("rollback")
        current = nil
    }

    public func recover() async {
        await run(operation: "Recovery", allowRecovery: true) {
            try runtime.checkLegacy()
            if state.worker != nil { try await finishWorker() }
            if state.switching != nil { try await rollback() }
            if let renewal = state.renewal { try await performSwitch(renewal) }
            message = "Recovery completed. Refresh accounts before continuing."
        }
    }


}

private extension String {
    func caseInsensitiveEquals(_ other: String) -> Bool { caseInsensitiveCompare(other) == .orderedSame }
}
