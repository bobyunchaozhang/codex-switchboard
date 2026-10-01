import AppKit
import SwiftUI
import SwitchboardCore

/// Exercises the real hosted panel, including its native scroll view.
@MainActor
enum PanelLayoutChecks {
    static func run() async {
        checkNoticeRecovery()
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
            ("Duplicate login", model, "This account has already been added."),
            ("Dismissed notice", model, nil),
            ("Expanded reset credits", .preview(), nil),
            ("Six accounts", .preview(accountCount: 6), nil),
            ("Reopened", model, nil)
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
            host.rootView = AnyView(PanelView(model: fixture, quit: {}, initiallyExpandedCredits: name == "Expanded reset credits").id(name))
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
