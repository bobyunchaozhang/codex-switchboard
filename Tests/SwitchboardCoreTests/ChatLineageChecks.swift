import Foundation
@testable import SwitchboardCore

enum ChatLineageChecks {
    static func regression() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-lineage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        let id = UUID().uuidString.lowercased()
        let folder = a.appendingPathComponent("sessions/2026/10/06")
        try privateDirectory(folder)
        let base = folder.appendingPathComponent("rollout-2026-10-06T01-00-00-" + id + ".jsonl")
        let continuation = folder.appendingPathComponent("rollout-2026-10-06T02-00-00-" + id + "_" + UUID().uuidString + ".jsonl")
        func data(_ meta: [String: Any]) throws -> Data {
            var value = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": meta])
            value.append(10)
            return value
        }
        let original = try data(["id": id, "history_mode": "paginated"])
        try original.write(to: base)
        let current = try data(["id": id, "history_mode": "paginated",
                                "history_base": ["thread_id": id, "end_byte_offset": original.count, "end_ordinal_exclusive": 1]])
        try current.write(to: continuation)
        let relative = try SharedChats.relativePath(continuation, home: a.path, id: id)
        try expectTrue(relative.hasSuffix(continuation.lastPathComponent))
        let deps = try ChatLineage.dependencies(of: continuation, homes: [a.path])
        try expectEqual(deps.count, 1)
        try ChatLineage.install(deps, target: b.path)
        try expectEqual(try Data(contentsOf: b.appendingPathComponent(deps[0].relativePath)), original)
        try expectEqual(try Data(contentsOf: continuation), current)
        // Missing history must fail, never be silently discarded.
        try FileManager.default.removeItem(at: base)
        try expectThrows(try ChatLineage.dependencies(of: continuation, homes: [a.path]))
        try original.write(to: base)
        try Data("conflict".utf8).write(to: b.appendingPathComponent(deps[0].relativePath))
        try expectThrows(try ChatLineage.install(deps, target: b.path))
    }

    /// Read-only source inspection; all resumes and archival operations use temporary copies.
    static func installedCLI(executable: URL, sourceHome: String, rollout: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-lineage-integration-" + UUID().uuidString)
        try privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try ChatLineage.metadata(rollout)
        guard let id = metadata["id"] as? String else { throw ChatSharingFailure.verification }
        let relative = try SharedChats.relativePath(rollout, home: sourceHome, id: id)
        let dependencies = try ChatLineage.dependencies(of: rollout, homes: [sourceHome])
        try expectTrue(!dependencies.isEmpty)
        for name in ["a", "b"] {
            let home = root.appendingPathComponent(name)
            try privateDirectory(home)
            try "cli_auth_credentials_store = \"file\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            try ChatLineage.install(dependencies, target: home.path)
            let destination = home.appendingPathComponent(relative)
            try privateDirectory(destination.deletingLastPathComponent())
            try privateCopy(rollout, to: destination)
            let rpc = try RPCConnection(executable: executable, home: home.path, experimental: true)
            defer { rpc.close() }
            let response = try rpc.request("thread/resume", params: ["threadId": id, "path": destination.path, "excludeTurns": true], timeout: 60)
            try expectEqual((response["thread"] as? [String: Any])?["id"] as? String, id)
            _ = try rpc.request("thread/unsubscribe", params: ["threadId": id])
            _ = try rpc.request("thread/archive", params: ["threadId": id])
            _ = try rpc.request("thread/unarchive", params: ["threadId": id])
            _ = try rpc.request("thread/resume", params: ["threadId": id, "path": destination.path, "excludeTurns": true], timeout: 60)
            _ = try rpc.request("thread/unsubscribe", params: ["threadId": id])
        }
        let a = SavedAccount(home: root.appendingPathComponent("a").path, email: "a@example.test")
        let c = SavedAccount(home: root.appendingPathComponent("c").path, email: "c@example.test")
        try privateDirectory(URL(fileURLWithPath: c.home))
        try "cli_auth_credentials_store = \"file\"\n".write(to: URL(fileURLWithPath: c.home).appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let rpc = try RPCConnection(executable: executable, home: a.home, experimental: true)
        let project = try rpc.request("project/create", params: ["idempotencyKey": UUID().uuidString,
            "name": "Synthetic project", "roots": [["path": root.path]]])
        let projectID = (project["project"] as! [String: Any])["id"] as! String
        _ = try rpc.request("thread/metadata/update", params: ["threadId": id, "projectId": projectID])
        rpc.close()
        let state: [String: Any] = ["local-projects": ["synthetic-project": ["id": "synthetic-project",
            "name": "Synthetic project", "rootPaths": [root.path]]],
            DesktopProjects.mappingKey: ["local:" + a.home: ["synthetic-project": projectID]],
            "thread-project-assignments": [id: ["projectKind": "local", "projectId": "synthetic-project"]]]
        try privateWrite(JSONSerialization.data(withJSONObject: state),
                         to: URL(fileURLWithPath: a.home).appendingPathComponent(DesktopProjects.filename))
        let service = SharedSetupService(executable: executable, directory: root.appendingPathComponent("shared"))
        for (source, target) in [(a, c), (c, a)] {
            let plan = try await service.prepare(accounts: [a, c], currentHome: source.home)
            try expectTrue(plan.conflicts.isEmpty)
            try await service.apply(plan, choices: [:], target: target)
            let verify = try RPCConnection(executable: executable, home: target.home, experimental: true)
            let read = try verify.request("thread/read", params: ["threadId": id, "includeTurns": false])
            let path = (read["thread"] as! [String: Any])["path"] as! String
            try expectTrue(path.hasSuffix(rollout.lastPathComponent))
            _ = try verify.request("thread/resume", params: ["threadId": id, "excludeTurns": true], timeout: 60)
            _ = try verify.request("thread/unsubscribe", params: ["threadId": id])
            verify.close()
        }
        print("PASS: Full shared-setup round trip preserves paginated history and explicit continuation path")
        print("PASS: Paginated history resumes in two isolated homes and survives archive/unarchive")
    }
}
