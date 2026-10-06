import Foundation

/// One-time, additive import. Existing IDs and files in the primary home win.
/// No desktop-state or database files are rewritten by this importer.
public enum LocalHistoryMigration {
    public static func importMissing(executable: URL, target: String, sources: [String], backup: URL) async throws -> Int {
        try await Task.detached {
            let destination = try RPCConnection(executable: executable, home: target, experimental: true)
            defer { destination.close() }
            var known = Set(try threads(destination).compactMap { $0["id"] as? String })
            let receipt = backup.appendingPathComponent("history-import.json")
            var recorded = ((try? Data(contentsOf: receipt)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["importedThreadIDs"] as? [String] ?? []
            var imported: [String] = []
            for source in sources where normalizedHome(source) != normalizedHome(target) {
                let rpc = try RPCConnection(executable: executable, home: source, experimental: true)
                defer { rpc.close() }
                for record in try threads(rpc) {
                    guard let id = record["id"] as? String, !known.contains(id),
                          let raw = record["path"] as? String else { continue }
                    let original = URL(fileURLWithPath: raw)
                    try SharedChats.requireThreadID(original, id: id)
                    // This release's existing project chats are already present in
                    // the primary home. Do not guess an absent project's ownership.
                    guard record["projectId"] == nil || record["projectId"] is NSNull else { throw ChatSharingFailure.verification }
                    let relative = try SharedChats.relativePath(original, home: source, id: id)
                    let path = URL(fileURLWithPath: target).appendingPathComponent(relative)
                    let dependencies = try ChatLineage.dependencies(of: original, homes: [source, target])
                    try ChatLineage.install(dependencies, target: target)
                    if FileManager.default.fileExists(atPath: path.path) {
                        try SharedChats.requireSameContents(original, path)
                    } else {
                        try privateDirectory(path.deletingLastPathComponent())
                        try privateCopy(original, to: path)
                    }
                    let response = try destination.request("thread/resume", params: ["threadId": id, "path": path.path, "excludeTurns": true], timeout: 60)
                    guard let thread = response["thread"] as? [String: Any], thread["id"] as? String == id else { throw ChatSharingFailure.verification }
                    guard thread["projectId"] == nil || thread["projectId"] is NSNull else { throw ChatSharingFailure.verification }
                    if let name = record["name"] as? String, !name.isEmpty {
                        _ = try destination.request("thread/name/set", params: ["threadId": id, "name": name])
                    }
                    _ = try destination.request("thread/unsubscribe", params: ["threadId": id])
                    if record["_archived"] as? Bool == true { _ = try destination.request("thread/archive", params: ["threadId": id]) }
                    let verified = try destination.request("thread/read", params: ["threadId": id, "includeTurns": false])
                    guard (verified["thread"] as? [String: Any])?["id"] as? String == id else { throw ChatSharingFailure.verification }
                    known.insert(id); imported.append(id)
                    if !recorded.contains(id) { recorded.append(id) }
                    try privateDirectory(backup)
                    try privateWrite(JSONSerialization.data(withJSONObject: ["targetHome": target, "sourceHomes": sources, "importedThreadIDs": recorded]), to: receipt)
                }
            }
            try privateDirectory(backup)
            try privateWrite(JSONSerialization.data(withJSONObject: ["targetHome": target, "sourceHomes": sources, "importedThreadIDs": recorded]),
                             to: backup.appendingPathComponent("history-import.json"))
            return imported.count
        }.value
    }

    private static func threads(_ rpc: RPCConnection) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for archived in [false, true] {
            var cursor: String?, seen = Set<String>()
            repeat {
                var params: [String: Any] = ["limit": 100, "archived": archived, "modelProviders": [], "useStateDbOnly": true]
                if let cursor { params["cursor"] = cursor }
                let page = try rpc.request("thread/list", params: params)
                guard let data = page["data"] as? [[String: Any]] else { throw ChatSharingFailure.verification }
                for var record in data { record["_archived"] = archived; result.append(record) }
                cursor = page["nextCursor"] as? String
                if let cursor, !seen.insert(cursor).inserted { throw ChatSharingFailure.verification }
            } while cursor != nil
        }
        return result
    }
}
