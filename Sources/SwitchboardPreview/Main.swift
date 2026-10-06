import AppKit
import SwiftUI
import PreviewCore
import SwitchboardCore

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PreviewDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: PreviewController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let view: AnyView
        do {
            let controller = try PreviewController(); model = controller
            view = AnyView(PreviewView(model: controller))
        } catch {
            view = AnyView(VStack(alignment: .leading, spacing: 16) {
                Text("Preview could not start").font(.title2.bold())
                Text(error.localizedDescription)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.padding(28).frame(width: 480))
        }
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Codex Switchboard Preview"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PreviewView: View {
    @ObservedObject var model: PreviewController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Codex Switchboard").font(.title2.bold())
                Spacer()
                Text("0.4.0 Preview 1").font(.caption.bold()).padding(6)
                    .background(.yellow.opacity(0.25), in: Capsule())
            }
            Text("One test environment. Multiple accounts.").foregroundStyle(.secondary)
            Text("Sign in to both accounts. Switching restarts Codex and can interrupt tasks. Your existing account environments are not imported.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.accounts) { account in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(account.email).font(.headline).textSelection(.enabled)
                                Spacer()
                                if model.current == account.id {
                                    Label("Current", systemImage: "crown.fill").font(.caption.bold())
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .foregroundStyle(.black).background(.yellow, in: Capsule())
                                } else {
                                    Button("Open / Switch") { Task { await model.switchTo(account.id) } }
                                        .disabled(model.busy || model.needsRecovery || account.needsLogin)
                                }
                            }
                            Text(PlanLabel.text(account.plan)).foregroundStyle(.secondary)
                            if let usage = model.readings[account.id]?.usage {
                                ForEach(usage.quotas) { quota in
                                    HStack {
                                        Text(quota.title)
                                        Spacer()
                                        Text("\(Int(quota.remaining))% left")
                                        if let date = quota.resetsAt {
                                            Text("Resets \(date.formatted(date: .abbreviated, time: .shortened))")
                                                .foregroundStyle(.secondary)
                                        }
                                    }.font(.caption)
                                }
                            } else { Text("Usage unavailable").font(.caption).foregroundStyle(.secondary) }
                            if account.needsLogin || model.readings[account.id]?.needsLogin == true {
                                Button("Sign In Again") { Task { await model.addAccount(replacing: account.id) } }
                                    .disabled(model.busy || model.needsRecovery)
                            }
                        }
                        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                    }
                }
            }.frame(minHeight: 100, maxHeight: 330)
            HStack {
                Button("Add Account") { Task { await model.addAccount() } }
                Button("Refresh") { Task { await model.refresh() } }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }.disabled(model.busy || model.needsRecovery)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.failed ? "exclamationmark.circle" : "info.circle")
                Text(model.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(model.failed ? Color.red : Color.secondary)
            if model.signingIn { Button("Cancel Sign In") { model.cancelSignIn() } }
            if model.needsRecovery {
                Button("Recover Interrupted Operation") { Task { await model.recover() } }.disabled(model.busy)
            }
            Divider()
            Text("Test: A → B → A").font(.headline)
            Text("In Codex, add the Test Project folder once. Create a chat with A, continue it with B, then return to A. Check Codex's account menu each time. All local chats in this test environment are shared.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show Test Project") { NSWorkspace.shared.activateFileViewerSelecting([model.project]) }
                Spacer()
                Button("Return to Original Environment") { Task { await model.returnToOriginal() } }
                    .disabled(model.busy || model.needsRecovery || !model.canReturn)
            }
            Text("Test home: \(model.home.path)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .padding(24).frame(width: 620)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.cancelSignIn()
        }
    }
}
