import AppKit
import SwiftUI
import SwitchboardCore

enum CardState { case loading, available(Usage), unavailable, signIn }

@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var accounts: [SavedAccount] = []
    @Published private(set) var states: [UUID: CardState] = [:]
    @Published private(set) var currentID: UUID?
    @Published private(set) var presence: DesktopPresence = .unknown
    @Published private(set) var busyText: String?
    @Published private(set) var refreshing = false
    @Published var notice: String?
    @Published private(set) var signingIn = false
    private var currentIdentity: Identity?
    private var cancellation: CancellationFlag?
    private let store: AccountStore
    private let desktop: Desktop?
    private let service: CodexService?
    private var loaded = false
    private var storageReady = true
    var canAct: Bool { loaded && storageReady && !refreshing && busyText == nil && service != nil }
    var currentStatus: String {
        if presence == .stopped { return "Codex is not running" }
        return currentIdentity == nil ? "Current account unknown" : "Current account is not added"
    }

    init() {
        store = AccountStore()
        desktop = try? Desktop()
        service = desktop.map { CodexService(executable: $0.executable) }
        if desktop == nil { notice = SwitchboardFailure.desktopMissing.localizedDescription }
    }

    func opened() {
        guard busyText == nil, !refreshing else { return }
        Task {
            if !loaded { await load() }
            await refresh()
        }
    }

    func refreshClicked() {
        guard busyText == nil, !refreshing else { return }
        Task { if !loaded { await load() }; await refresh() }
    }

    private func load() async {
        guard let service else { loaded = true; return }
        refreshing = true
        defer { refreshing = false; loaded = true }
        do {
            if let saved = try store.load() { accounts = saved; return }
            let home = desktop?.observe().home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            if let identity = try await service.identity(home: home) {
                let account = SavedAccount(home: home, email: identity.email, plan: identity.plan)
                try store.save([account]); accounts = [account]
            } else { try store.save([]) }
        } catch {
            storageReady = false
            notice = "Could not load accounts. Existing account data has been kept."
        }
    }

    private func refresh() async {
        guard !refreshing, let service, let desktop, storageReady else { return }
        beginRefresh(observed: desktop.observe())
        defer { refreshing = false }
        let before = presence
        let saved = accounts
        var readings: [UUID: Reading] = [:]
        await withTaskGroup(of: (UUID, Reading).self) { group in
            var iterator = saved.makeIterator()
            for _ in 0..<min(3, saved.count) {
                if let account = iterator.next() {
                    group.addTask { (account.id, await service.read(home: account.home)) }
                }
            }
            while let (id, reading) = await group.next() {
                readings[id] = reading
                if let account = iterator.next() {
                    group.addTask { (account.id, await service.read(home: account.home)) }
                }
            }
        }
        var updated = accounts
        for index in updated.indices {
            let account = updated[index]
            guard let reading = readings[account.id] else { states[account.id] = .unavailable; continue }
            if reading.needsLogin { states[account.id] = .signIn }
            else if let identity = reading.identity, !identity.matches(account.email) { states[account.id] = .signIn }
            else if let identity = reading.identity, let usage = reading.usage {
                updated[index].plan = identity.plan
                states[account.id] = .available(usage)
            } else { states[account.id] = .unavailable }
        }
        if updated != accounts {
            do { try store.save(updated); accounts = updated }
            catch { notice = SwitchboardFailure.storage.localizedDescription }
        }
        // Keep the previous identity during loading only; the completed read must confirm it again.
        currentID = nil; currentIdentity = nil
        if let home = before.home {
            if let match = accounts.first(where: { $0.home == home }), let reading = readings[match.id],
               !reading.needsLogin, let identity = reading.identity, identity.matches(match.email) {
                currentIdentity = identity; currentID = match.id
            } else if !accounts.contains(where: { $0.home == home }) {
                currentIdentity = try? await service.identity(home: home)
                if let identity = currentIdentity { currentID = accounts.first(where: { identity.matches($0.email) })?.id }
            }
        }
        let after = desktop.observe()
        presence = after
        if after != before { currentID = nil; currentIdentity = nil }
    }

    private func beginRefresh(observed: DesktopPresence) {
        refreshing = true
        if observed != presence { currentID = nil; currentIdentity = nil }
        presence = observed
        // Preserve the last result until its replacement arrives. Only new cards need a placeholder.
        for account in accounts where states[account.id] == nil { states[account.id] = .loading }
    }

    func switchAccount(_ account: SavedAccount) {
        guard canAct, let service, let desktop else { return }
        busyText = "Switching account…"; notice = nil
        Task {
            defer { busyText = nil }
            do {
                guard let identity = try await service.identity(home: account.home), identity.matches(account.email) else {
                    states[account.id] = .signIn; throw SwitchboardFailure.signedOut
                }
                currentID = nil; currentIdentity = nil
                try await desktop.activate(home: account.home)
                let observed = desktop.observe()
                guard observed.home == account.home,
                      let identity = try await service.identity(home: account.home), identity.matches(account.email),
                      desktop.observe() == observed else { throw SwitchboardFailure.currentUnknown }
                presence = observed; currentID = account.id; currentIdentity = identity
                await refresh()
            } catch {
                notice = friendly(error)
                await refresh()
            }
        }
    }

    func signIn(_ account: SavedAccount? = nil) {
        guard canAct, let service else { return }
        notice = nil; busyText = "Finish signing in in your browser…"; signingIn = true
        let flag = CancellationFlag(); cancellation = flag
        Task {
            defer { signingIn = false; busyText = nil; cancellation = nil }
            do {
                let home = try account?.home ?? store.newHome()
                let identity = try await service.login(home: home, cancellation: flag) { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                if let account, !identity.matches(account.email) { throw SwitchboardFailure.identityChanged }
                if accounts.contains(where: { $0.id != account?.id && identity.matches($0.email) }) {
                    throw SwitchboardFailure.duplicateAccount
                }
                var updated = accounts
                if let account, let index = updated.firstIndex(where: { $0.id == account.id }) {
                    updated[index].plan = identity.plan
                } else { updated.append(SavedAccount(home: home, email: identity.email, plan: identity.plan)) }
                try store.save(updated); accounts = updated
                if let account, desktop?.observe().home == account.home { try await desktop?.activate(home: account.home) }
                await refresh()
            } catch {
                notice = friendly(error)
                await refresh()
            }
        }
    }

    func cancelSignIn() { cancellation?.cancel() }

    func canRemove(_ account: SavedAccount) -> Bool {
        canAct && RemovalPolicy.allows(account, desktop: presence, identity: currentIdentity)
    }

    func remove(_ account: SavedAccount) {
        guard canRemove(account), let service, let desktop else { return }
        busyText = "Removing account…"; notice = nil
        Task {
            defer { busyText = nil }
            do {
                let observed = desktop.observe()
                let identity: Identity?
                if let home = observed.home { identity = try await service.identity(home: home) }
                else { identity = nil }
                guard observed == desktop.observe(), RemovalPolicy.allows(account, desktop: observed, identity: identity) else {
                    throw SwitchboardFailure.currentUnknown
                }
                try await service.logout(account) {
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            desktop.observe() == observed && RemovalPolicy.allows(account, desktop: observed, identity: identity)
                        }
                    }
                }
                let updated = accounts.filter { $0.id != account.id }
                try store.save(updated)
                accounts = updated; states.removeValue(forKey: account.id)
                await refresh()
            } catch { notice = friendly(error); await refresh() }
        }
    }

    private func friendly(_ error: Error) -> String {
        (error as? SwitchboardFailure)?.localizedDescription ?? "The operation could not be completed."
    }

    static func preview(accountCount: Int = 2, loading: Bool = false, refreshingCached: Bool = false) -> PanelModel {
        let model = PanelModel()
        let a = SavedAccount(home: "/tmp/preview-a", email: "alex@example.com", plan: "pro")
        let b = SavedAccount(home: "/tmp/preview-b", email: "work@example.com", plan: "business")
        model.accounts = [a, b]; model.currentID = a.id
        model.presence = .running(pid: 1, home: a.home)
        model.currentIdentity = Identity(email: a.email, plan: a.plan)
        model.loaded = true
        let data = Data("""
        {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":1893459600},"secondary":{"usedPercent":54,"windowDurationMins":10080,"resetsAt":1893718800}}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"title":"Weekly reset","status":"available","expiresAt":1893546000},{"title":"Bonus reset","status":"available","expiresAt":1893805200}]}}
        """.utf8)
        let low = Data("""
        {"rateLimits":{"primary":{"usedPercent":88,"windowDurationMins":10080,"resetsAt":1893459600}},"rateLimitResetCredits":{"availableCount":0}}
        """.utf8)
        model.states[a.id] = .available(try! UsageDecoder.decode(data))
        model.states[b.id] = .available(try! UsageDecoder.decode(low))
        if accountCount == 0 {
            model.accounts = []; model.currentID = nil
        } else if accountCount > 2 {
            for index in 3...accountCount {
                let extra = SavedAccount(home: "/tmp/preview-\(index)", email: "account\(index)@example.com", plan: "plus")
                model.accounts.append(extra)
                model.states[extra.id] = model.states[a.id]
            }
        }
        if loading {
            model.refreshing = true; model.currentID = nil
            for account in model.accounts { model.states[account.id] = .loading }
        }
        if refreshingCached { model.beginRefresh(observed: model.presence) }
        return model
    }
}
