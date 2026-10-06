import Foundation
import SQLite3

/// A paginated rollout can refer to an earlier file with the same thread ID.
/// Keep that file separate from the current continuation and never edit either.
enum ChatLineage {
    struct Dependency {
        let source: URL
        let relativePath: String
    }

    static func metadata(_ path: URL) throws -> [String: Any] {
        try SharedChats.requireRegular(path)
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        var data = Data()
        while data.count < 8_388_608 {
            guard let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty else { break }
            data.append(chunk)
            if let end = data.firstIndex(of: 10) {
                guard let record = try JSONSerialization.jsonObject(with: data[..<end]) as? [String: Any],
                      record["type"] as? String == "session_meta",
                      let payload = record["payload"] as? [String: Any] else { throw ChatSharingFailure.verification }
                return payload
            }
        }
        throw ChatSharingFailure.verification
    }

    static func dependencies(of path: URL, homes: [String]) throws -> [Dependency] {
        var result: [Dependency] = []
        var visited = Set<String>()
        func visit(_ file: URL) throws {
            let meta = try metadata(file)
            guard let base = meta["history_base"] as? [String: Any] else { return }
            guard let id = base["thread_id"] as? String, UUID(uuidString: id) != nil,
                  let offset = base["end_byte_offset"] as? Int, offset > 0 else { throw ChatSharingFailure.lineage }
            let key = file.resolvingSymlinksInPath().path
            guard visited.insert(key).inserted else { throw ChatSharingFailure.lineage }
            var candidates: [Dependency] = []
            for home in homes {
                for folder in ["sessions", "archived_sessions"] {
                    let root = URL(fileURLWithPath: home).appendingPathComponent(folder)
                    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
                    for case let url as URL in files where url.lastPathComponent.hasSuffix("-" + id + ".jsonl") {
                        guard try !SharedChats.sameFile(url, file) else { continue }
                        try SharedChats.requireThreadID(url, id: id)
                        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                        guard size?.intValue ?? 0 >= offset else { continue }
                        // A rewritten continuation is not its own base.
                        let candidateMeta = try metadata(url)
                        if let candidateBase = candidateMeta["history_base"] as? [String: Any],
                           candidateBase["thread_id"] as? String == id { continue }
                        candidates.append(Dependency(source: url, relativePath: try SharedChats.relativePath(url, home: home, id: id)))
                    }
                }
            }
            guard let first = candidates.first else { throw ChatSharingFailure.lineage }
            for other in candidates.dropFirst() {
                try requirePrefix(first.source, other.source, count: offset)
            }
            try visit(first.source)
            if !result.contains(where: { $0.relativePath == first.relativePath }) { result.append(first) }
        }
        try visit(path)
        return result
    }

    static func requirePrefix(_ a: URL, _ b: URL, count: Int) throws {
        let left = try FileHandle(forReadingFrom: a), right = try FileHandle(forReadingFrom: b)
        defer { try? left.close(); try? right.close() }
        var remaining = count
        while remaining > 0 {
            let size = min(remaining, 65_536)
            guard let x = try left.read(upToCount: size), let y = try right.read(upToCount: size),
                  x.count == size, x == y else { throw ChatSharingFailure.conflict }
            remaining -= size
        }
    }

    /// Retire only the exact truncated alias produced by older Switchboard versions.
    /// Codex's base-history discovery can pick this alias even with an explicit resume path.
    static func retireLegacyAlias(continuation: URL, backupDirectory: URL, home: String? = nil) throws {
        let filename = continuation.lastPathComponent
        guard let separator = filename.firstIndex(of: "_") else { return }
        let legacy = continuation.deletingLastPathComponent()
            .appendingPathComponent(String(filename[..<separator]) + ".jsonl")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let meta = try metadata(continuation)
        guard let id = meta["id"] as? String,
              let base = meta["history_base"] as? [String: Any],
              base["thread_id"] as? String == id else { return }
        try SharedChats.requireRegular(legacy)
        try SharedChats.requireSameContents(continuation, legacy)
        try privateDirectory(backupDirectory)
        let backup = backupDirectory.appendingPathComponent(UUID().uuidString + "-" + legacy.lastPathComponent)
        // Only a stopped desktop may call this with a real home. Repair exactly
        // the stale filename reference; official resume rebuilds content indexes.
        if let home {
            try repairPath(home: home, id: id, legacy: legacy, continuation: continuation, backup: backup)
        } else {
            try FileManager.default.moveItem(at: legacy, to: backup)
        }
    }

    private static func repairPath(home: String, id: String, legacy: URL, continuation: URL, backup: URL) throws {
        let databases = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: home),
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
        guard databases.count == 1, let database = databases.first else { throw ChatSharingFailure.verification }
        try SharedChats.requireRegular(database)
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw ChatSharingFailure.storage
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ChatSharingFailure.storage }
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        try execute("BEGIN IMMEDIATE")
        var committed = false
        var moved = false
        defer {
            if !committed {
                try? execute("ROLLBACK")
                if moved { try? FileManager.default.moveItem(at: backup, to: legacy) }
            }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE id = " + quote(id), -1, &statement, nil) == SQLITE_OK else { throw ChatSharingFailure.verification }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        var oldPath: String?
        if step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) { oldPath = String(cString: text) }
        else if step != SQLITE_DONE { throw ChatSharingFailure.verification }
        // A different indexed file is not ours to repair.
        guard oldPath == nil || oldPath.map(normalizedHome) == normalizedHome(legacy.path) || oldPath.map(normalizedHome) == normalizedHome(continuation.path) else { throw ChatSharingFailure.conflict }
        if let oldPath, normalizedHome(oldPath) == normalizedHome(legacy.path) {
            try privateWrite(JSONSerialization.data(withJSONObject: [
                "threadId": id, "previousPath": oldPath, "replacementPath": continuation.path,
                "database": database.lastPathComponent
            ]), to: backup.appendingPathExtension("index.json"))
            try execute("UPDATE threads SET rollout_path = " + quote(continuation.path)
                + " WHERE id = " + quote(id) + " AND rollout_path = " + quote(oldPath))
            guard sqlite3_changes(db) == 1 else { throw ChatSharingFailure.verification }
        }
        try FileManager.default.moveItem(at: legacy, to: backup)
        moved = true
        try execute("COMMIT")
        committed = true
    }

    static func install(_ dependencies: [Dependency], target: String) throws {
        for dependency in dependencies {
            let destination = URL(fileURLWithPath: target).appendingPathComponent(dependency.relativePath)
            if FileManager.default.fileExists(atPath: destination.path) {
                try SharedChats.requireSameContents(dependency.source, destination)
            } else {
                try privateDirectory(destination.deletingLastPathComponent())
                try privateCopy(dependency.source, to: destination)
            }
        }
    }
}
