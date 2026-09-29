import AppKit
import Darwin
import SwiftUI
import SwitchboardCore

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--check-layout") {
            Task { await PanelLayoutChecks.run(); app.terminate(nil) }
            app.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check") {
            let homes = Array(CommandLine.arguments.dropFirst(index + 1))
            Task { await check(homes: homes); app.terminate(nil) }
            app.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            renderPreview(path: CommandLine.arguments[index + 1]); return
        }
        let delegate = StatusBarDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor private static func check(homes: [String]) async {
        do {
            let desktop = try Desktop()
            let service = CodexService(executable: desktop.executable)
            let before = desktop.observe()
            print("Desktop environment readable: \(before.home != nil)")
            let targets = homes.isEmpty ? (try AccountStore().load() ?? []).map(\.home) : homes
            var emails = Set<String>()
            for (index, home) in targets.enumerated() {
                let reading = await service.read(home: home)
                if let identity = reading.identity { emails.insert(identity.email.lowercased()) }
                let expiryCount = reading.usage?.resetCredits?.filter { if case .at = $0.expiry { return true }; return false }.count ?? 0
                print("Account \(index + 1): identity=\(reading.identity != nil), usage=\(reading.usage != nil), windows=\(reading.usage?.quotas.count ?? 0), resetCount=\(reading.usage?.resetCount != nil), resetDetails=\(reading.usage?.resetCredits?.count ?? 0), datedCredits=\(expiryCount), loginRequired=\(reading.needsLogin)")
            }
            print("Distinct identities: \(emails.count)")
            print("Desktop unchanged: \(desktop.observe() == before)")
        } catch { print("Read-only check failed: \(error.localizedDescription)") }
    }

    @MainActor private static func renderPreview(path: String) {
        let model = PanelModel.preview()
        let view = CardPreview(model: model, expandedCredits: CommandLine.arguments.contains("--expanded-credits")).environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor))
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
