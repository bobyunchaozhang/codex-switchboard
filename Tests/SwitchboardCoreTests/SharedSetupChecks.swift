import Foundation
@testable import SwitchboardCore

enum SharedSetupChecks {
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "SharedSetupChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func merging() throws {
        let one = try SharedEntry(kind: .mcp, name: "example", object: ["url": "https://one.example/mcp"])
        let two = try SharedEntry(kind: .mcp, name: "example", object: ["url": "https://two.example/mcp"])
        func snapshot(_ home: String, _ entry: SharedEntry?) -> HomeSetup {
            HomeSetup(home: home, label: home, entries: entry.map { ["mcp:example": $0] } ?? [:], servers: [:],
                      projectIDs: [:], configVersion: nil, oauthStore: nil)
        }
        let initial = SetupMerge.plan(document: SharedDocument(), snapshots: [snapshot("a", one), snapshot("b", two)], currentHome: "a", fingerprint: nil)
        try check(initial.conflicts.count == 1, "Initial conflicts must not be silently overwritten")
        let chosen = try initial.resolved([:])
        try check(chosen.entries["mcp:example"] == one, "The current account must be the initial default")
        let unvisited = SetupMerge.plan(document: chosen, snapshots: [snapshot("a", one), snapshot("b", two)], currentHome: "a", fingerprint: nil)
        try check(unvisited.conflicts.isEmpty, "An acknowledged unchanged conflict must not repeat")

        var document = SharedDocument()
        document.entries = ["mcp:example": one]
        document.baselines = ["a": ["mcp:example": one.fingerprint], "b": ["mcp:example": one.fingerprint]]
        let removal = SetupMerge.plan(document: document, snapshots: [snapshot("a", nil), snapshot("b", one)], currentHome: "a", fingerprint: nil)
        try check(removal.document.entries.isEmpty && removal.conflicts.isEmpty, "An unchanged stale account must not resurrect a deletion")
        let editVsDelete = SetupMerge.plan(document: document, snapshots: [snapshot("a", nil), snapshot("b", two)], currentHome: "a", fingerprint: nil)
        try check(editVsDelete.conflicts.count == 1, "Concurrent deletion and edit must be reviewed")
        let newAccount = SetupMerge.plan(document: document, snapshots: [snapshot("new", nil)], currentHome: nil, fingerprint: nil)
        try check(newAccount.document.entries["mcp:example"] == one, "An empty new account must inherit shared settings")
        try check(SharedSetupService.isDesktopManaged(name: "node_repl", object: [:]), "Keep built-in runtime settings local")
        try check(SharedSetupService.isDesktopManaged(name: "custom", object: ["env": ["CODEX_HOME": "/a"]]), "Keep home-bound runtime settings local")
        try check(!SharedSetupService.isDesktopManaged(name: "custom", object: ["env": ["TOKEN": "synthetic"]]), "User MCP settings must remain shareable")
    }

    // Optional installed-CLI integration: only synthetic homes, projects, and an empty thread.
    static func integration(executable: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let aHome = root.appendingPathComponent("a"), bHome = root.appendingPathComponent("b")
        let projectA = root.appendingPathComponent("project-a"), projectB = root.appendingPathComponent("project-b")
        for path in [aHome, bHome, projectA, projectB] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let base = "cli_auth_credentials_store = \"file\"\n[analytics]\nenabled = false\n"
        try (base + "[mcp_servers.sample]\nurl = \"http://127.0.0.1:1/mcp\"\nenabled = false\n[mcp_servers.node_repl]\ncommand = \"/usr/bin/false\"\nenabled = false\n[mcp_servers.node_repl.env]\nCODEX_HOME = \"\(aHome.path)\"\n").write(to: aHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try (base + "[mcp_servers.node_repl]\ncommand = \"/usr/bin/false\"\nenabled = false\n[mcp_servers.node_repl.env]\nCODEX_HOME = \"\(bHome.path)\"\n").write(to: bHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let a = SavedAccount(home: aHome.path, email: "a@example.test"), b = SavedAccount(home: bHome.path, email: "b@example.test")
        func rpc(_ home: String) throws -> RPCConnection { try RPCConnection(executable: executable, home: home, experimental: true) }
        func create(_ home: String, _ path: URL) throws -> String {
            let r = try rpc(home); defer { r.close() }
            let result = try r.request("project/create", params: ["idempotencyKey": UUID().uuidString, "name": path.lastPathComponent, "roots": [["path": path.path]]])
            return (result["project"] as! [String: Any])["id"] as! String
        }
        _ = try create(a.home, projectA)
        let originalB = try create(b.home, projectB)
        let start = try rpc(b.home)
        let thread = try start.request("thread/start", params: ["cwd": projectB.path, "projectId": originalB, "ephemeral": false])
        let threadID = (thread["thread"] as! [String: Any])["id"] as! String
        _ = try start.request("thread/name/set", params: ["threadId": threadID, "name": "Synthetic sharing check"])
        start.close()

        // Reproduce 0.2.0: both backends already contain both folders, while each
        // desktop sidebar still only contains its original local project.
        let originalA = try rpc(a.home)
        let backendA = try originalA.request("project/list")["data"] as! [[String: Any]]
        let originalAID = backendA[0]["id"] as! String
        originalA.close()
        _ = try create(a.home, projectB)
        _ = try create(b.home, projectA)
        func seedDesktop(_ home: URL, path: URL, id: String, serverID: String) throws {
            let state: [String: Any] = [
                "local-projects": [id: ["id": id, "name": path.lastPathComponent, "rootPaths": [path.path], "createdAt": 1, "updatedAt": 1]],
                "project-order": [id], "selected-project": ["type": "local", "projectId": id],
                DesktopProjects.mappingKey: ["local:" + home.path: [id: serverID]],
                "thread-project-assignments": ["synthetic-chat": ["projectId": id, "projectKind": "local"]],
                "unrelated-setting": "preserve"
            ]
            try JSONSerialization.data(withJSONObject: state).write(to: home.appendingPathComponent(DesktopProjects.filename))
        }
        try seedDesktop(aHome, path: projectA, id: "desktop-a", serverID: originalAID)
        try seedDesktop(bHome, path: projectB, id: "desktop-b", serverID: originalB)
        let service = SharedSetupService(executable: executable, directory: root.appendingPathComponent("shared"))
        // Migration must union visible folders, not interpret the old backend
        // baselines as removals by the user.
        var legacy = SharedDocument()
        legacy.version = 1
        for path in [projectA, projectB] {
            let key = try DesktopProjects.key(paths: [path.path])
            legacy.entries[key] = try SharedEntry(kind: .project, name: path.lastPathComponent,
                                                 object: ["name": path.lastPathComponent, "roots": [["path": path.path]]])
        }
        legacy.baselines = [a.home: legacy.entries.mapValues(\.fingerprint), b.home: legacy.entries.mapValues(\.fingerprint)]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("shared/setup.json"))
        let plan = try await service.prepare(accounts: [a, b], currentHome: a.home)
        try check(plan.conflicts.isEmpty && plan.document.entries.count == 3, "Merge two projects and one custom MCP")
        try await service.apply(plan, choices: [:], target: b)
        let r = try rpc(b.home)
        let config = try r.request("config/read", params: ["includeLayers": false])["config"] as! [String: Any]
        let servers = config["mcp_servers"] as! [String: Any]
        let local = servers["node_repl"] as! [String: Any]
        try check((local["env"] as! [String: String])["CODEX_HOME"] == b.home, "Target runtime must still point to its own home")
        try check(servers["sample"] != nil, "Custom MCP must arrive")
        try check(!String(contentsOf: bHome.appendingPathComponent("config.toml")).contains("sqlite_home"), "No shared chat database")
        let projects = try r.request("project/list")["data"] as! [[String: Any]]
        try check(projects.count == 2, "Both project registrations must appear")
        try check(projects.contains { $0["id"] as? String == originalB }, "Existing project IDs must remain")
        _ = try r.request("thread/read", params: ["threadId": threadID, "includeTurns": false])
        var sidebar = try DesktopProjects.read(home: b.home)
        let localProjects = try DesktopProjects.projects(sidebar)!
        let currentBackendIDs = Dictionary(uniqueKeysWithValues: try projects.map { project in
            (try DesktopProjects.key(paths: (project["roots"] as! [[String: String]]).map { $0["path"]! }), project["id"] as! String)
        })
        try check(DesktopProjects.isLinked(sidebar, home: b.home, serverIDs: currentBackendIDs), "Every visible project must map to its backend registration")
        try check(localProjects.count == 2, "Both projects must appear in the actual desktop sidebar registry")
        try check(localProjects["desktop-b"] != nil, "Preserve existing desktop project IDs and chat references")
        try check((sidebar["selected-project"] as! [String: String])["projectId"] == "desktop-b", "Preserve the selected project")
        try check(sidebar["unrelated-setting"] as? String == "preserve", "Do not replace unrelated desktop state")
        try check((sidebar["thread-project-assignments"] as! [String: [String: String]])["synthetic-chat"]?["projectId"] == "desktop-b", "Keep chat associations local")
        // Mimic removal through the desktop, leaving a backend registration behind
        // as the desktop does during its undo window.
        sidebar["local-projects"] = localProjects.filter { $0.key != "desktop-b" }
        try JSONSerialization.data(withJSONObject: sidebar).write(to: bHome.appendingPathComponent(DesktopProjects.filename))
        _ = try r.request("config/value/write", params: ["keyPath": "mcp_servers", "value": ["node_repl": ["command": "/usr/bin/false", "enabled": false, "env": ["CODEX_HOME": b.home]]], "mergeStrategy": "replace"])
        r.close()

        let second = try await service.prepare(accounts: [a, b], currentHome: b.home)
        try check(second.conflicts.isEmpty, "Stale original settings must not resurrect removed items")
        try await service.apply(second, choices: [:], target: a)
        let ra = try rpc(a.home)
        let ac = try ra.request("config/read", params: ["includeLayers": false])["config"] as! [String: Any]
        try check((ac["mcp_servers"] as! [String: Any])["sample"] == nil, "MCP removal must propagate")
        try check((try ra.request("project/list")["data"] as! [[String: Any]]).count == 1, "Project removal must propagate")
        try check((try DesktopProjects.projects(DesktopProjects.read(home: a.home)))?.count == 1, "Sidebar removal must propagate")
        let aThreads = try ra.request("thread/list", params: ["limit": 100])["data"] as! [[String: Any]]
        try check(!aThreads.contains { $0["id"] as? String == threadID }, "B's thread must not appear in A")
        ra.close()
        let rb = try rpc(b.home)
        _ = try rb.request("thread/read", params: ["threadId": threadID, "includeTurns": false])
        rb.close()

        let cHome = root.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: cHome, withIntermediateDirectories: true)
        let c = SavedAccount(home: cHome.path, email: "c@example.test")
        let third = try await service.prepare(accounts: [a, b, c], currentHome: a.home)
        try check(third.conflicts.isEmpty, "A new account must not conflict with existing shared setup")
        try await service.apply(third, choices: [:], target: c)
        let rc = try rpc(c.home)
        try check((try rc.request("project/list")["data"] as! [[String: Any]]).count == 1, "A new account must inherit projects")
        try check((try rc.request("thread/list", params: ["limit": 100])["data"] as! [[String: Any]]).isEmpty, "A new account must not inherit chats")
        rc.close()

        let stale = try await service.prepare(accounts: [a, b], currentHome: a.home)
        let edit = try rpc(b.home)
        _ = try edit.request("config/value/write", params: ["keyPath": "model_verbosity", "value": "low", "mergeStrategy": "replace"])
        edit.close()
        var rejected = false
        do { try await service.apply(stale, choices: [:], target: b) } catch SharingFailure.changed { rejected = true }
        try check(rejected, "Settings edited after preview must be protected")
        let pending = try await service.prepare(accounts: [a, b], currentHome: a.home)
        var changedSidebar = try DesktopProjects.read(home: b.home)
        var changedProjects = try DesktopProjects.projects(changedSidebar)!
        let changedID = changedProjects.keys.first!
        changedProjects[changedID]?["name"] = "Changed after review"
        changedSidebar["local-projects"] = changedProjects
        try JSONSerialization.data(withJSONObject: changedSidebar).write(to: bHome.appendingPathComponent(DesktopProjects.filename))
        var sidebarRejected = false
        do { try await service.apply(pending, choices: [:], target: b) } catch SharingFailure.changed { sidebarRejected = true }
        try check(sidebarRejected, "Protect sidebar edits made after preparation")
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("shared/setup.json").path)[.posixPermissions] as! NSNumber
        try check(permissions.intValue == 0o600, "Shared settings must be private")
    }
}
