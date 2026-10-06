import AppKit
import Combine
import OSLog
import SwiftUI
import SwitchboardCore
import AccountRuntime

enum PanelOperation: String {
    case prepareSwitch = "Prepare account switch"
    case switchAccount = "Switch account"
    case signIn = "Sign in"
    case removeAccount = "Remove account"
    case saveAccounts = "Save account details"
}

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
    @Published private(set) var needsRecovery = false
    private var recoverableNotice: String?
    private var currentIdentity: Identity?
    private var loaded = false
    private var storageReady = false
    private var runtime: AccountController?
    private var observer: AnyCancellable?
    private let logger = Logger(subsystem: "local.codex-switchboard.app", category: "operations")
    var canAct: Bool { loaded && storageReady && !refreshing && busyText == nil && !needsRecovery }
    var currentStatus: String {
        if presence == .stopped { return "Codex is not running" }
        return currentIdentity == nil ? "Current account unknown" : "Current account is not added"
    }

    init(loadRuntime: Bool = true) {
        guard loadRuntime else { return }
        do {
            let runtime = try AccountController(); self.runtime = runtime
            storageReady = true; loaded = true; synchronize()
            observer = runtime.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.synchronize() }
            }
        } catch { notice = error.localizedDescription; loaded = true }
    }

    private func synchronize() {
        guard let runtime else { return }
        accounts = runtime.accounts.map { SavedAccount(id: $0.id, home: runtime.home.path, email: $0.email, plan: $0.plan) }
        for account in runtime.accounts {
            if let reading = runtime.readings[account.id] {
                if reading.needsLogin || account.needsLogin { states[account.id] = .signIn }
                else if let identity = reading.identity, identity.matches(account.email), let usage = reading.usage { states[account.id] = .available(usage) }
                else { states[account.id] = .unavailable }
            } else if account.needsLogin { states[account.id] = .signIn }
            else if states[account.id] == nil { states[account.id] = .loading }
        }
        states = states.filter { id, _ in accounts.contains { $0.id == id } }
        currentID = runtime.current; presence = runtime.presence
        currentIdentity = runtime.currentEmail.map { Identity(email: $0, plan: nil) }
        signingIn = runtime.signingIn; needsRecovery = runtime.needsRecovery
        if !refreshing { busyText = runtime.busy ? (runtime.message.isEmpty ? "Working…" : runtime.message) : nil }
        if runtime.failed { notice = runtime.message }
    }

    func opened() { refreshClicked() }
    func refreshClicked() {
        guard !refreshing, busyText == nil, let runtime, !needsRecovery else { return }
        let previous = notice
        beginRefresh(observed: runtime.presence)
        Task {
            await runtime.refresh()
            refreshing = false; synchronize()
            if !runtime.failed, previous == notice, accounts.allSatisfy({ if case .available = states[$0.id] { return true }; return false }) {
                notice = nil; recoverableNotice = nil
            }
        }
    }
    private func beginRefresh(observed: DesktopPresence) {
        refreshing = true
        if observed != presence { currentID = nil; currentIdentity = nil }
        presence = observed
        for account in accounts where states[account.id] == nil { states[account.id] = .loading }
    }
    func switchAccount(_ account: SavedAccount) {
        guard canAct, let runtime else { return }
        busyText = "Switching account…"; notice = nil
        Task { await runtime.switchTo(account.id); synchronize() }
    }
    func signIn(_ account: SavedAccount? = nil) {
        guard canAct, let runtime else { return }
        busyText = "Waiting for sign-in…"; notice = nil
        Task {
            await runtime.addAccount(replacing: account?.id)
            if !runtime.failed { await runtime.refresh() }
            synchronize()
        }
    }
    func cancelSignIn() { runtime?.cancelSignIn() }
    func canRemove(_ account: SavedAccount) -> Bool { canAct && runtime?.canRemove(account.id) == true }
    func remove(_ account: SavedAccount) {
        guard canRemove(account), let runtime else { return }
        busyText = "Removing account…"; notice = nil
        Task { await runtime.remove(account.id); synchronize() }
    }
    func recover() {
        guard let runtime, !runtime.busy else { return }
        busyText = "Recovering…"; notice = nil
        Task { await runtime.recover(); synchronize(); if !runtime.failed { refreshClicked() } }
    }

    // Called only after a user-initiated refresh finishes. An action's own
    // follow-up refresh must not immediately erase its failure message.
    func clearRecoveredNotice(_ previous: String?) {
        guard let previous, previous == recoverableNotice, notice == previous,
              !accounts.isEmpty, accounts.allSatisfy({
                  if case .available = states[$0.id] { return true }; return false
              }) else { return }
        notice = nil; recoverableNotice = nil
    }

    func reportFailure(_ error: Error, operation: PanelOperation) {
        let message = operation.rawValue + " failed. " + friendly(error)
        var recoverable = false
        let category: String
        if let failure = error as? SwitchboardFailure {
            switch failure {
            case .unavailable, .timeout: recoverable = true
            case .protocolError(let code): recoverable = code != -32600 && code != -32601 && code != -32602
            default: break
            }
            category = String(describing: failure)
        } else if let failure = error as? AccountFailure { category = String(describing: failure) }
        else if let failure = error as? SharingFailure { category = String(describing: failure) }
        else if let failure = error as? ChatSharingFailure { category = String(describing: failure) }
        else { category = "unexpected-error" }
        // Only fixed operation labels, error cases, and numeric protocol codes.
        // Never log raw error descriptions, emails, paths, payloads, or tokens.
        logger.error("\(operation.rawValue, privacy: .public) failed: \(category, privacy: .public)")
        notice = message
        recoverableNotice = recoverable ? message : nil
    }

    private func friendly(_ error: Error) -> String {
        if let chat = error as? ChatSharingFailure { return chat.localizedDescription }
        if let sharing = error as? SharingFailure { return sharing.localizedDescription }
        if let runtime = error as? AccountFailure { return runtime.localizedDescription }
        return (error as? SwitchboardFailure)?.localizedDescription ?? "The operation could not be completed."
    }

    static func preview(accountCount: Int = 2, loading: Bool = false, refreshingCached: Bool = false) -> PanelModel {
        let model = PanelModel(loadRuntime: false)
        let a = SavedAccount(home: "/tmp/preview-a", email: "alex@example.com", plan: "pro")
        let b = SavedAccount(home: "/tmp/preview-b", email: "work@example.com", plan: "business")
        model.accounts = [a, b]; model.currentID = a.id
        model.presence = .running(pid: 1, home: a.home)
        model.currentIdentity = Identity(email: a.email, plan: a.plan)
        model.loaded = true; model.storageReady = true
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
