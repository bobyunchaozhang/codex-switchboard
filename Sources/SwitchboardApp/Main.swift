import AppKit
import Darwin
import SwiftUI
import SwitchboardCore
import AccountRuntime

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--check-localization") {
            PanelLayoutChecks.checkLocalization()
            return
        }
        if CommandLine.arguments.contains("--check-layout") {
            Task { await PanelLayoutChecks.run(); app.terminate(nil) }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--migrate") || CommandLine.arguments.contains("--verify-runtime") {
            Task {
                do {
                    let runtime = try AccountController()
                    if CommandLine.arguments.contains("--migrate") {
                        await runtime.migrateLegacy()
                        print(runtime.message)
                    } else {
                        let before = runtime.presence
                        await runtime.refresh()
                        print("Accounts: \(runtime.accounts.count), available usage: \(runtime.readings.values.filter { $0.usage != nil }.count), current verified: \(runtime.current != nil), desktop unchanged: \(runtime.presence == before)")
                        if runtime.failed { print(runtime.message) }
                    }
                    exit(runtime.failed ? 1 : 0)
                } catch { print(error.localizedDescription); exit(1) }
            }
            app.run(); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            renderPreview(path: CommandLine.arguments[index + 1]); return
        }
        let delegate = StatusBarDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor private static func renderPreview(path: String) {
        let model = PanelModel.preview()
        if let index = CommandLine.arguments.firstIndex(of: "--language"), CommandLine.arguments.count > index + 1 {
            model.language = AppLanguage(rawValue: CommandLine.arguments[index + 1]) ?? .english
        }
        let view = CardPreview(model: model, expandedCredits: CommandLine.arguments.contains("--expanded-credits"))
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, CommandLine.arguments.contains("--dark") ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 380, height: nil)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}

@MainActor
final class StatusBarDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let model = PanelModel()
    private var instanceLock: Int32 = -1
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let directory = AccountStore().directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        instanceLock = open(directory.appendingPathComponent(".instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
            NSApplication.shared.terminate(nil); return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.thumbsUp()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView(model: model) { NSApplication.shared.terminate(nil) })
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            model.opened()
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        stopMonitoringOutsideClicks()
        // Global mouse events cover clicks in other apps and on the desktop.
        // Local menu clicks stay with AppKit so account actions are not interrupted.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopMonitoringOutsideClicks()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if popover.isShown { popover.performClose(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMonitoringOutsideClicks()
    }

    private func stopMonitoringOutsideClicks() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}
