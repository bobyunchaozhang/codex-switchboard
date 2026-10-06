import Darwin
import Foundation
@testable import SwitchboardCore
@testable import AccountRuntime

final class MemoryVault: CredentialVault {
    var entries: [String: Data] = [:]
    var failWrites = false
    func read(_ name: String) throws -> Data? { entries[name] }
    func write(_ data: Data, name: String) throws {
        if failWrites { throw AccountFailure.keychain }
        entries[name] = data
    }
    func remove(_ name: String) throws { entries.removeValue(forKey: name) }
}

func fixture(_ label: String, revision: Int = 1) -> Data {
    try! JSONSerialization.data(withJSONObject: ["fixture": label, "revision": revision])
}
func decode(_ data: Data?) -> (String, Int)? {
    guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let label = object["fixture"] as? String, let revision = object["revision"] as? Int else { return nil }
    return (label, revision)
}
func check(_ result: @autoclosure () throws -> Bool, _ name: String) throws {
    if try !result() { throw NSError(domain: "AccountRuntimeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
}

@MainActor
final class FakeRuntime: RuntimeBackend {
    var presence: DesktopPresence = .running(pid: 1, home: "/synthetic-original-home")
    var nextLogin = "a"
    var loginFails = false
    var loginRevision = 1
    var logoutFails = false
    var beforeLogout: (() throws -> Void)?
    var logouts = 0
    var failPolicy = false
    var writers = false
    var legacy = false
    var launchFailures = 0
    var onRead: ((String) throws -> Void)?
    var readFailureHome: String?
    var wrongIdentityHome: String?
    var invalidateHome: String?
    var rotateOnRead = false
    var afterQuit: (() throws -> Void)?
    var launches: [String] = []
    func validate(home: String) async throws { if failPolicy { throw AccountFailure.policy } }
    func read(home: String) async -> Reading {
        do { try onRead?(home) } catch { fatalError(error.localizedDescription) }
        if home == readFailureHome { return Reading(identity: nil, usage: nil) }

        let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        guard let pair = decode(try? PrivateFile.read(url)) else { return Reading(identity: nil, usage: nil, needsLogin: true) }
        if home == invalidateHome && pair.1 < 10 { return Reading(identity: nil, usage: nil, needsLogin: true) }
        if rotateOnRead { try? PrivateFile.write(fixture(pair.0, revision: pair.1 + 1), to: url) }
        let label = home == wrongIdentityHome ? "wrong" : pair.0
        let usage = try? UsageDecoder.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}"#.utf8))
        return Reading(identity: Identity(email: label + "@example.test", plan: "plus"), usage: usage)
    }
    func login(home: String, cancellation: CancellationFlag) async throws -> Identity {
        if loginFails { throw SwitchboardFailure.loginCancelled }
        try PrivateFile.write(fixture(nextLogin, revision: loginRevision), to: URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
        return Identity(email: nextLogin + "@example.test", plan: "plus")
    }
    func logout(home: String, email: String, stillNonCurrent: @escaping @MainActor () -> Bool) async throws {
        try beforeLogout?(); beforeLogout = nil
        if logoutFails { throw SwitchboardFailure.unavailable }
        guard stillNonCurrent() else { throw SwitchboardFailure.currentUnknown }
        logouts += 1
        try PrivateFile.remove(URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
    }
    func activate(home: String, change: @escaping () async throws -> Void) async throws {
        let before = presence
        presence = .stopped
        do {
            try afterQuit?(); afterQuit = nil
            try await change()
            if launchFailures > 0 { launchFailures -= 1; throw SwitchboardFailure.launchFailed }
            presence = .running(pid: 2, home: home); launches.append(home)
        } catch {
            presence = before
            throw error
        }
    }
    func quiescent(home: String) async throws { if writers { throw AccountFailure.writers } }
    func checkLegacy() throws { if legacy { throw AccountFailure.legacyApp } }
}

@MainActor
struct Harness {
    let root: URL
    let vault: MemoryVault
    let store: RuntimeStore
    let runtime: FakeRuntime
    let controller: AccountController
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("switchboard-runtime-check-" + UUID().uuidString)
        vault = MemoryVault(); store = try RuntimeStore(root: root, vault: vault)
        runtime = FakeRuntime(); controller = try AccountController(store: store, runtime: runtime)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func twoAccounts() async throws -> (UUID, UUID) {
        await controller.addAccount()
        try check(!controller.failed, "add A")
        runtime.nextLogin = "b"
        await controller.addAccount()
        try check(!controller.failed && controller.accounts.count == 2, "add B")
        return (controller.accounts[0].id, controller.accounts[1].id)
    }
}

@main
struct AccountRuntimeChecks {
    @MainActor static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("fixed home A-B-A and latest active cache", roundTrip),
            ("worker refresh is saved before switch", workerRefresh),
            ("healthy journals do not appear as interrupted operations", healthyOperationState),
            ("launch failure restores previous login", launchFailure),
            ("failed rollback leaves recoverable journal", failedRollback),
            ("unexpected target identity blocks acceptance", wrongIdentity),
            ("worker vault failure recovers latest cache", workerRecovery),
            ("completed worker cleanup is idempotent", cleanupRecovery),
            ("cancelled and mismatched login preserve accounts", cancelledLogin),
            ("policy, writer and legacy app guards", guards),
            ("credential owners exclude plugins and helpers", writerClassification),
            ("live process guard distinguishes inherited home from credential owner", liveWriters),
            ("active reauthentication replaces only credentials", renewal),
            ("renewal launch failure preserves latest login for recovery", renewalRecovery),
            ("current account removal blocked and other account logged out", removal),
            ("interrupted removal and identity race remain safe", removalRecovery),
            ("last non-current account can be removed", removeLast),
            ("private files reject symlinks and duplicate instances", privateStorage)
        ]
        do {
            if let i = CommandLine.arguments.firstIndex(of: "--migration-fixture"), CommandLine.arguments.count == i + 5 {
                let args = CommandLine.arguments
                let count = try await LocalHistoryMigration.importMissing(executable: URL(fileURLWithPath: args[i+1]),
                    target: args[i+2], sources: [args[i+3]], backup: URL(fileURLWithPath: args[i+4]))
                print("Imported local chats: \(count)")
                return
            }
            for (name, test) in tests { try await test(); print("PASS: \(name)") }
            if let index = CommandLine.arguments.firstIndex(of: "--integration-cli"), CommandLine.arguments.count > index + 1 {
                try await installedCLI(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                print("PASS: installed CLI authentication, fixed project registry, and private Keychain round-trip")
            }
            print("\(tests.count) runtime checks passed. No real credentials or desktop sessions were used.")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func roundTrip() async throws {
        let h = try Harness(); defer { h.clean() }
        let (a,b) = try await h.twoAccounts()
        let sentinel = h.store.home.appendingPathComponent("fixture-chat.jsonl")
        let content = Data("unchanged project chat".utf8)
        try PrivateFile.write(content, to: sentinel)
        await h.controller.switchTo(a)
        try check(!h.controller.failed && h.controller.current == a, "open A")
        h.runtime.afterQuit = { try h.store.install(fixture("a", revision: 9), in: h.store.home) }
        await h.controller.switchTo(b)
        try check(!h.controller.failed && h.controller.current == b, "switch B")
        try check(decode(h.vault.entries[a.uuidString])?.1 == 9, "capture latest A after stop")
        await h.controller.switchTo(a)
        try check(!h.controller.failed && h.controller.current == a, "return A")
        try check(decode(try h.store.credential(h.store.home))?.1 == 9, "newest A restored")
        try check(try PrivateFile.read(sentinel) == content, "chat unchanged")
        try check(h.runtime.launches.allSatisfy { $0 == h.store.home.path }, "one fixed home")
        try check(try h.store.load().switching == nil, "no remaining transaction")
    }
    @MainActor static func workerRefresh() async throws {
        let h = try Harness(); defer { h.clean() }
        let (a,b) = try await h.twoAccounts()
        await h.controller.switchTo(a)
        h.runtime.rotateOnRead = true
        await h.controller.refresh()
        try check(!h.controller.failed, "refresh succeeds")
        try check(decode(h.vault.entries[b.uuidString])?.1 == 2, "worker wrote refreshed B")
        try check(decode(h.vault.entries[a.uuidString])?.1 == 1, "active snapshot not treated as authoritative")
        await h.controller.switchTo(b)
        try check(!h.controller.failed, "switch after refresh")
        try check((decode(try h.store.credential(h.store.home))?.1 ?? 0) >= 3, "newest B activated")
    }
    @MainActor static func healthyOperationState() async throws {
        let h = try Harness(); defer { h.clean() }
        let (a,b) = try await h.twoAccounts(); await h.controller.switchTo(a)
        var checkedWorker = false
        h.runtime.onRead = { home in
            guard home != h.store.home.path else { return }
            checkedWorker = true
            try check(try h.store.load().worker != nil, "fixture exercises a persisted live worker")
            try check(h.controller.busy && !h.controller.needsRecovery, "live work is not an interrupted operation")
            try check(h.controller.current == a, "checking another account preserves the verified current badge")
        }
        await h.controller.refresh()
        try check(checkedWorker && !h.controller.failed, "refresh reached the transient journal")
        checkedWorker = false
        await h.controller.switchTo(b)
        try check(checkedWorker && !h.controller.failed && h.controller.current == b, "preflight and switch complete normally")
    }
    @MainActor static func launchFailure() async throws {
        let h = try Harness(); defer { h.clean() }
        let (a,b) = try await h.twoAccounts(); await h.controller.switchTo(a)
        h.runtime.launchFailures = 1
        await h.controller.switchTo(b)
        try check(h.controller.failed && !h.controller.needsRecovery, "failed launch recovered")
        try check(try h.store.load().active == a, "previous active restored")
        try check(decode(try h.store.credential(h.store.home))?.0 == "a", "A cache restored")
    }
    @MainActor static func failedRollback() async throws {
        let h = try Harness(); defer { h.clean() }
        let (a,b) = try await h.twoAccounts(); await h.controller.switchTo(a)
        h.runtime.launchFailures = 2
        await h.controller.switchTo(b)
        try check(h.controller.needsRecovery, "failed rollback kept journal")
        await h.controller.recover()
        try check(!h.controller.failed && !h.controller.needsRecovery, "manual recovery succeeds")
        try check(try h.store.load().active == a, "recovered A")
    }
    @MainActor static func wrongIdentity() async throws {
        let h = try Harness(); defer { h.clean() }
        let (_,b) = try await h.twoAccounts()
        h.runtime.wrongIdentityHome = h.store.home.path
        await h.controller.switchTo(b)
        try check(h.controller.failed && h.controller.current == nil, "wrong account never current")
        try check(h.runtime.presence.home == "/synthetic-original-home", "original desktop restored")
    }
    @MainActor static func workerRecovery() async throws {
        let h = try Harness(); defer { h.clean() }
        let (_,b) = try await h.twoAccounts()
        h.runtime.rotateOnRead = true; h.vault.failWrites = true
        await h.controller.refresh()
        try check(h.controller.needsRecovery, "failed vault write kept worker")
        h.vault.failWrites = false
        await h.controller.recover()
        try check(!h.controller.failed && !h.controller.needsRecovery, "recover latest worker")
        await h.controller.switchTo(b)
        try check(!h.controller.failed, "switch still possible")
    }
    @MainActor static func cleanupRecovery() async throws {
        let h = try Harness(); defer { h.clean() }
        var state = try h.store.load()
        var worker = WorkerJournal(id: UUID(), accountID: nil, login: true, materialized: false)
        worker.completed = true; state.worker = worker
        try h.store.save(state)
        let reloaded = try AccountController(store: h.store, runtime: h.runtime)
        await reloaded.recover()
        try check(!reloaded.needsRecovery && !reloaded.failed, "missing completed worker directory is harmless")
    }
    @MainActor static func cancelledLogin() async throws {
        let h = try Harness(); defer { h.clean() }
        h.runtime.loginFails = true; await h.controller.addAccount()
        try check(h.controller.accounts.isEmpty && !h.controller.needsRecovery, "cancel leaves no profile")
        h.runtime.loginFails = false
        let (a,_) = try await h.twoAccounts()
        h.runtime.nextLogin = "wrong"; await h.controller.addAccount(replacing: a)
        try check(h.controller.failed && !h.controller.needsRecovery, "wrong login rejected")
        try check(decode(h.vault.entries[a.uuidString])?.0 == "a", "previous credentials intact")
    }
    @MainActor static func guards() async throws {
        let h = try Harness(); defer { h.clean() }
        let (a,b) = try await h.twoAccounts()
        h.runtime.legacy = true; await h.controller.switchTo(a)
        try check(h.controller.failed && h.runtime.launches.isEmpty, "legacy guard")
        h.runtime.legacy = false; h.runtime.failPolicy = true; await h.controller.switchTo(a)
        try check(h.controller.failed && h.runtime.launches.isEmpty, "managed policy guard")
        h.runtime.failPolicy = false; await h.controller.recover()
        await h.controller.switchTo(a)
        h.runtime.writers = true; await h.controller.switchTo(b)
        try check(h.controller.failed, "writer guard")
        try check(decode(try h.store.credential(h.store.home))?.0 == "a", "writer guard kept A")
    }
    @MainActor static func writerClassification() async throws {
        let app = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let cli = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        let paths = [
            "/Users/example/Library/Application Support/Codex Switchboard/Proof-B/plugins/ChatGPT for Chrome",
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/browser_crashpad_handler",
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)",
            "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node",
            "/Users/example/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex-code-mode-host",
            "/Applications/Codex Switchboard.app/Contents/MacOS/CodexSwitchboard",
            "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex"
        ]
        let entries = paths.enumerated().map { CredentialWriters.Entry(pid: Int32($0.offset + 1), executable: $0.element) }
        let sameHome = CredentialWriters.blockers(in: entries, home: "/fixture", application: app, cli: cli,
            ownPID: 100, readHome: { _ in "/fixture" }, isAlive: { _ in true })
        try check(sameHome.map(\.pid) == [8,9,10], "only desktop and real CLI names are owners")
        let others = CredentialWriters.blockers(in: entries, home: "/fixture", application: app, cli: cli,
            ownPID: 8, readHome: { pid in pid == 9 ? nil : "/other" }, isAlive: { _ in true })
        try check(others.map(\.pid) == [9], "unknown live owner fails closed; other home and self ignored")
        let exited = CredentialWriters.blockers(in: entries, home: "/fixture", application: app, cli: cli,
            readHome: { _ in nil }, isAlive: { _ in false })
        try check(exited.isEmpty, "exited process does not block")
    }
    @MainActor static func liveWriters() async throws {
        let h = try Harness(); defer { h.clean() }
        let app = h.root.appendingPathComponent("ChatGPT.app")
        let helperURL = app.appendingPathComponent("Contents/Frameworks/browser_crashpad_handler")
        let cli = h.root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in [helperURL, cli] { try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: url) }
        var processes: [Process] = []
        defer { for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() } }
        func start(_ url: URL, home: String) throws -> Process {
            let p = Process(); p.executableURL = url; p.arguments = ["60"]
            p.environment = ["HOME": h.root.path, "CODEX_HOME": home]
            try p.run(); processes.append(p); return p
        }
        let helper = try start(helperURL, home: h.store.home.path)
        let owner = try start(cli, home: h.store.home.path)
        let other = try start(cli, home: h.root.appendingPathComponent("Other").path)
        let ids = Set([helper.processIdentifier, owner.processIdentifier, other.processIdentifier])
        let inventory = try CredentialWriters.inventory().filter { ids.contains($0.pid) }
        try check(inventory.count == 3, "actual process inventory found fixtures")
        let blocked = CredentialWriters.blockers(in: inventory, home: h.store.home.path, application: app, cli: cli)
        try check(blocked.map(\.pid) == [owner.processIdentifier], "inherited home alone does not make helper an owner")
        owner.terminate(); owner.waitUntilExit()
        let remaining = try CredentialWriters.inventory().filter { ids.contains($0.pid) }
        try check(CredentialWriters.blockers(in: remaining, home: h.store.home.path, application: app, cli: cli).isEmpty,
            "guard releases after real owner stops even with helper still running")
    }
    @MainActor static func renewal() async throws {
        let h = try Harness(); defer { h.clean() }
        let (a,_) = try await h.twoAccounts(); await h.controller.switchTo(a)
        h.runtime.invalidateHome = h.store.home.path
        h.runtime.nextLogin = "a"; h.runtime.loginRevision = 10
        await h.controller.addAccount(replacing: a)
        try check(!h.controller.failed && h.controller.current == a, "renew current without leaving fixed home")
        try check(decode(try h.store.credential(h.store.home))?.1 == 10, "new login installed")
        try check(!h.controller.needsRecovery, "renewal completed")
    }
    @MainActor static func renewalRecovery() async throws {
        let h = try Harness(); defer { h.clean() }
        let (a,_) = try await h.twoAccounts(); await h.controller.switchTo(a)
        h.runtime.nextLogin = "a"; h.runtime.loginRevision = 10
        h.runtime.rotateOnRead = true; h.runtime.launchFailures = 1
        await h.controller.addAccount(replacing: a)
        try check(h.controller.failed && h.controller.needsRecovery, "interrupted renewal journal retained")
        let revision = decode(try h.store.credential(h.store.home))!.1
        await h.controller.recover()
        try check(!h.controller.failed && !h.controller.needsRecovery, "renewal recovery")
        try check(decode(try h.store.credential(h.store.home))!.1 >= revision, "renewed cache never regressed")
    }
    @MainActor static func removal() async throws {
        let h = try Harness(); defer { h.clean() }
        let (a,b) = try await h.twoAccounts(); await h.controller.switchTo(a)
        await h.controller.remove(a)
        try check(h.controller.failed && h.runtime.logouts == 0 && h.controller.accounts.count == 2, "current removal blocked")
        await h.controller.remove(b)
        try check(!h.controller.failed && h.runtime.logouts == 1 && h.controller.accounts.count == 1, "non-current logged out")
        try check(h.vault.entries[b.uuidString] == nil && decode(try h.store.credential(h.store.home))?.0 == "a", "active login preserved")
    }
    @MainActor static func removalRecovery() async throws {
        let h = try Harness(); defer { h.clean() }
        let (a,b) = try await h.twoAccounts(); await h.controller.switchTo(a)
        h.runtime.logoutFails = true; await h.controller.remove(b)
        try check(h.controller.needsRecovery && h.controller.accounts.count == 2, "logout failure retains account")
        h.runtime.logoutFails = false
        h.runtime.beforeLogout = { try h.store.install(fixture("b"), in: h.store.home) }
        await h.controller.recover()
        try check(h.controller.failed && h.runtime.logouts == 0, "identity race blocked before logout")
        await h.controller.recover()
        try check(!h.controller.needsRecovery && h.controller.accounts.count == 2, "now-current target retained")
    }
    @MainActor static func removeLast() async throws {
        let h = try Harness(); defer { h.clean() }
        await h.controller.addAccount()
        let a = h.controller.accounts[0].id
        try h.store.install(fixture("unregistered"), in: h.store.home)
        h.runtime.presence = .running(pid: 2, home: h.store.home.path)
        await h.controller.refresh(); await h.controller.remove(a)
        try check(!h.controller.failed && h.controller.accounts.isEmpty && h.runtime.logouts == 1, "last non-current removed")
    }
    @MainActor static func privateStorage() async throws {
        let h = try Harness(); defer { h.clean() }
        var blocked = false
        do { _ = try RuntimeStore(root: h.root, vault: MemoryVault()) } catch { blocked = true }
        try check(blocked, "duplicate instance blocked")
        let outside = h.root.appendingPathComponent("untouched.json")
        try PrivateFile.write(fixture("outside"), to: outside)
        let auth = h.store.home.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(at: auth, withDestinationURL: outside)
        blocked = false
        do { try h.store.install(fixture("a"), in: h.store.home) } catch { blocked = true }
        try check(blocked && decode(try PrivateFile.read(outside))?.0 == "outside", "symlink rejected")
        try FileManager.default.removeItem(at: auth)
        try h.store.install(fixture("a"), in: h.store.home)
        let attrs = try FileManager.default.attributesOfItem(atPath: auth.path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "credential permissions")
    }
    @MainActor static func installedCLI(_ executable: URL) async throws {
        let h = try Harness(); defer { h.clean() }
        try await AuthBackend.validateConfiguration(executable: executable, home: h.store.home.path)
        let vault = KeychainVault(), name = "fixture-" + UUID().uuidString
        defer { try? vault.remove(name) }
        var projectBaseline: Data?
        do {
            let rpc = try RPCConnection(executable: executable, home: h.store.home.path, experimental: true)
            defer { rpc.close() }
            _ = try rpc.request("account/login/start", params: ["type": "apiKey", "apiKey": "sk-synthetic-preview-A-invalid"])
            _ = try rpc.request("project/create", params: ["idempotencyKey": UUID().uuidString,
                "name": "Synthetic preview project", "roots": [["path": h.store.home.path]]])
            projectBaseline = try JSONSerialization.data(withJSONObject: rpc.request("project/list"), options: [.sortedKeys])
        }
        guard let first = try h.store.credential(h.store.home) else { throw AccountFailure.storage }
        try vault.write(first, name: name)
        do {
            let rpc = try RPCConnection(executable: executable, home: h.store.home.path)
            defer { rpc.close() }
            _ = try rpc.request("account/login/start", params: ["type": "apiKey", "apiKey": "sk-synthetic-preview-B-invalid"])
            let result = try rpc.request("getAuthStatus", params: ["includeToken": true, "refreshToken": false])
            try check(result["authToken"] as? String == "sk-synthetic-preview-B-invalid", "CLI B login")
        }
        let saved = try vault.read(name)
        try check(saved == first, "Keychain preserved opaque fixture")
        try h.store.install(saved, in: h.store.home)
        do {
            let rpc = try RPCConnection(executable: executable, home: h.store.home.path, experimental: true)
            defer { rpc.close() }
            let result = try rpc.request("getAuthStatus", params: ["includeToken": true, "refreshToken": false])
            try check(result["authToken"] as? String == "sk-synthetic-preview-A-invalid", "CLI restored A login")
            let projects = try JSONSerialization.data(withJSONObject: rpc.request("project/list"), options: [.sortedKeys])
            try check(projects == projectBaseline, "CLI fixed project registry")
        }
    }
}
