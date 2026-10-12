import AppKit
import SwiftUI
import SwitchboardCore

/// Exercises the real hosted panel, including its native scroll view.
@MainActor
enum PanelLayoutChecks {
    static func run() async {
        checkLocalization()
        checkNoticeRecovery()
        checkStatusTiming()
        let model = PanelModel.preview()
        let host = NSHostingController(rootView: AnyView(PanelView(model: model, quit: {})))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        let cases: [(String, PanelModel, String?)] = [
            ("Empty", .preview(accountCount: 0), nil),
            ("Loading", .preview(loading: true), nil),
            ("Accounts", model, nil),
            ("Refreshing cached accounts", .preview(refreshingCached: true), nil),
            ("Checking target", .preview(checkingAccount: true, currentVerified: false), nil),
            ("Interrupted operation", .preview(interrupted: true), nil),
            ("Recovery running", .preview(checkingAccount: true, interrupted: true), nil),
            ("Duplicate login", model, "This account has already been added."),
            ("Dismissed notice", model, nil),
            ("Expanded reset credits", .preview(), nil),
            ("Six accounts", .preview(accountCount: 6), nil),
            ("Reopened", model, nil),
            ("Chinese accounts", .preview(language: .simplifiedChinese), nil),
            ("Chinese empty", .preview(accountCount: 0, language: .simplifiedChinese), nil),
            ("Chinese refreshing", .preview(refreshingCached: true, language: .simplifiedChinese), nil),
            ("Chinese credits", .preview(language: .simplifiedChinese), nil),
            ("Chinese failure", .preview(language: .simplifiedChinese), "Switch account failed. Codex did not respond in time.")
        ]
        for (name, fixture, notice) in cases {
            if name == "Refreshing cached accounts" {
                precondition(fixture.refreshing && fixture.currentID != nil)
                precondition(fixture.accounts.allSatisfy {
                    if case .available = fixture.states[$0.id] { return true }
                    return false
                }, "Cached quotas must stay visible while refreshing")
            }
            fixture.notice = notice
            host.rootView = AnyView(PanelView(model: fixture, quit: {}, initiallyExpandedCredits: name == "Expanded reset credits" || name == "Chinese credits").id(name))
            for _ in 0..<5 {
                host.view.layoutSubtreeIfNeeded()
                window.setContentSize(host.view.fittingSize)
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard let scroll = findScroll(in: host.view),
                  scroll.frame.height >= 100, scroll.frame.height <= 491,
                  let document = scroll.documentView, document.frame.height > 80,
                  abs(scroll.frame.height - min(max(document.frame.height, 100), 490)) < 2 else {
                fatalError("\(name): account overview collapsed")
            }
            print("\(name): viewport=\(Int(scroll.frame.height)), content=\(Int(document.frame.height)), panel=\(Int(host.view.frame.height))")
        }
        window.contentViewController = nil
        print("Hosted panel layout checks passed")
    }

    static func checkLocalization() {
        let suite = "local.codex-switchboard.language-check.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = PanelModel(loadRuntime: false, preferences: preferences)
        precondition(first.language == .english, "First launch defaults to English")
        first.language = .simplifiedChinese
        let reopened = PanelModel(loadRuntime: false, preferences: UserDefaults(suiteName: suite)!)
        precondition(reopened.language == .simplifiedChinese, "Language survives a new model and defaults instance")
        reopened.language = .english
        precondition(PanelModel(loadRuntime: false, preferences: preferences).language == .english)
        preferences.set("unsupported", forKey: AppLanguage.preferenceKey)
        precondition(PanelModel(loadRuntime: false, preferences: preferences).language == .english)

        let cached = PanelModel.preview(refreshingCached: true)
        let current = cached.currentID
        let accounts = cached.accounts.map(\.id)
        cached.notice = "Switch account failed. Codex did not respond in time."
        cached.language = .simplifiedChinese
        precondition(cached.currentID == current && cached.accounts.map(\.id) == accounts && cached.refreshing,
                     "Changing language must preserve cached accounts and the in-flight refresh")
        precondition(cached.language.message(cached.notice!) == "切换账号失败。Codex 响应超时。")
        precondition(cached.language.quotaTitle("Model A · 5-hour") == "Model A · 5 小时")
        precondition(cached.language.format("%@%% left", "39") == "剩余 39%")
        precondition(cached.language.message("Codex is still using this environment (PID 12, 34). Close Codex or its CLI and retry.").contains("PID 12, 34"))
        cached.language = .english
        precondition(cached.language.message(cached.notice!) == cached.notice)
        print("Language defaults, persistence, cached-state and dynamic-copy checks passed")
    }

    private static func checkStatusTiming() {
        precondition(PanelModel.preview().currentStatus == nil)
        precondition(PanelModel.preview(loading: true).currentStatus == nil)
        precondition(PanelModel.preview(checkingAccount: true, currentVerified: false).currentStatus == nil,
                     "Preflight must not claim that the current account is missing")
        precondition(PanelModel.preview(currentVerified: false).currentStatus == "Current account unknown",
                     "An added account without a Current badge is not an unregistered account")
        precondition(PanelModel.preview(accountCount: 0).currentStatus == "Current account is not added")
        precondition(!PanelModel.preview(checkingAccount: true, interrupted: true).showRecovery,
                     "No recovery action while work is running")
        precondition(PanelModel.preview(interrupted: true).showRecovery,
                     "An idle unfinished operation still offers recovery")
        print("Status timing checks passed")
    }

    private static func checkNoticeRecovery() {
        let model = PanelModel.preview()
        model.reportFailure(SwitchboardFailure.unavailable, operation: .prepareSwitch)
        let old = model.notice
        precondition(old?.contains("Prepare account switch failed") == true)
        model.clearRecoveredNotice(nil)
        precondition(model.notice == old, "An action's own refresh must keep its error visible")
        model.clearRecoveredNotice(old)
        precondition(model.notice == nil, "A later successful user refresh must clear stale transient errors")

        let loading = PanelModel.preview(loading: true)
        loading.reportFailure(SwitchboardFailure.timeout, operation: .switchAccount)
        let waiting = loading.notice
        loading.clearRecoveredNotice(waiting)
        precondition(loading.notice == waiting, "Loading must not be treated as recovery")

        model.reportFailure(ChatSharingFailure.conflict, operation: .switchAccount)
        let conflict = model.notice
        model.clearRecoveredNotice(conflict)
        precondition(model.notice == conflict, "Quota availability does not resolve a chat conflict")
        model.reportFailure(SwitchboardFailure.protocolError(-32601), operation: .prepareSwitch)
        let incompatible = model.notice
        model.clearRecoveredNotice(incompatible)
        precondition(model.notice == incompatible, "Compatibility failures must remain visible")
        model.reportFailure(SwitchboardFailure.unavailable, operation: .signIn)
        let oldSignIn = model.notice
        model.notice = "New storage error"
        model.clearRecoveredNotice(oldSignIn)
        precondition(model.notice == "New storage error", "A refresh cannot erase a newer error")
        print("Notice recovery checks passed")
    }

    private static func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap { findScroll(in: $0) }.first
    }
}
