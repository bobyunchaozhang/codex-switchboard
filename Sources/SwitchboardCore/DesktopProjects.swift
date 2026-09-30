import Foundation

// The desktop sidebar reads this registry, not App Server's project/list alone.
// Patch only project fields while the desktop is stopped; never copy whole home state.
struct DesktopProjects {
    static let filename = ".codex-global-state.json"
    static let localKey = "local-projects"
    static let mappingKey = "app-server-project-id-by-legacy-project-id-by-host"
    static let pendingKey = "app-server-pending-project-deletions-by-host"

    static func read(home: String) throws -> [String: Any] {
        let file = URL(fileURLWithPath: home).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let state = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw SharingFailure.invalidState
        }
        return state
    }

    static func projects(_ state: [String: Any]) throws -> [String: [String: Any]]? {
        guard let value = state[localKey] else { return nil }
        guard let projects = value as? [String: [String: Any]] else { throw SharingFailure.invalidState }
        return projects
    }

    static func key(paths: [String]) throws -> String {
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else { throw SharingFailure.invalidState }
        return "project:" + digest(try JSONEncoder().encode(paths.map(normalizedHome).sorted()))
    }

    static func entries(_ state: [String: Any]) throws -> [String: SharedEntry]? {
        guard let projects = try projects(state) else { return nil }
        var result: [String: SharedEntry] = [:]
        for (id, project) in projects {
            guard project["id"] as? String == id, let name = project["name"] as? String,
                  let paths = project["rootPaths"] as? [String] else { throw SharingFailure.invalidState }
            // Folderless ChatGPT-backed projects are account-local, not shared folders.
            if paths.isEmpty { continue }
            let key = try key(paths: paths)
            guard result[key] == nil else { throw SharingFailure.duplicateProjects }
            result[key] = try SharedEntry(kind: .project, name: name,
                object: ["name": name, "roots": paths.map { ["path": normalizedHome($0)] }])
        }
        return result
    }

    static func isLinked(_ state: [String: Any], home: String, serverIDs: [String: String]) throws -> Bool {
        guard let local = try projects(state) else { return false }
        let mapping = (state[mappingKey] as? [String: [String: String]])?["local:" + home] ?? [:]
        for (id, project) in local {
            guard let paths = project["rootPaths"] as? [String] else { throw SharingFailure.invalidState }
            if paths.isEmpty { continue }
            guard let serverID = serverIDs[try key(paths: paths)], mapping[id] == serverID else { return false }
        }
        return true
    }

    static func fingerprint(_ state: [String: Any], home: String) throws -> String {
        let host = "local:" + home
        let projection: [String: Any] = [
            localKey: state[localKey] ?? NSNull(),
            mappingKey: (state[mappingKey] as? [String: Any])?[host] ?? NSNull(),
            pendingKey: (state[pendingKey] as? [String: Any])?[host] ?? NSNull()
        ]
        return digest(try JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys]))
    }

    static func backupFields(_ state: [String: Any]) throws -> Data {
        let keys = Set([localKey, mappingKey, pendingKey, "project-order", "selected-project"])
        return try JSONSerialization.data(withJSONObject: state.filter { keys.contains($0.key) }, options: [.sortedKeys])
    }

    static func updated(_ state: [String: Any], home: String, entries: [String: SharedEntry], serverIDs: [String: String]) throws -> [String: Any] {
        let existing = try projects(state) ?? [:]
        var byRoots: [String: String] = [:]
        var local: [String: [String: Any]] = [:]
        for (id, project) in existing {
            guard let paths = project["rootPaths"] as? [String] else { throw SharingFailure.invalidState }
            if paths.isEmpty { local[id] = project; continue }
            byRoots[try key(paths: paths)] = id
        }
        var allMappings = state[mappingKey] as? [String: Any] ?? [:]
        let host = "local:" + home
        var mapping = allMappings[host] as? [String: String] ?? [:]
        var allPending = state[pendingKey] as? [String: Any] ?? [:]
        var pending = allPending[host] as? [String: Any] ?? [:]
        let now = Date().timeIntervalSince1970 * 1000
        for (key, entry) in entries.sorted(by: { $0.key < $1.key }) where entry.kind == .project {
            let object = try entry.object()
            guard let roots = object["roots"] as? [[String: String]], let serverID = serverIDs[key] else { throw SharingFailure.verification }
            let paths = try roots.map { root -> String in
                guard let path = root["path"] else { throw SharingFailure.invalidState }; return path
            }
            let id = byRoots[key] ?? UUID().uuidString.lowercased()
            var project = existing[id] ?? ["id": id, "createdAt": now]
            if project["name"] as? String != entry.name || project["rootPaths"] as? [String] != paths {
                project["updatedAt"] = now
            }
            project["name"] = entry.name; project["rootPaths"] = paths
            local[id] = project; mapping[id] = serverID
            // An explicitly restored folder must not be removed by a pending undo timer.
            pending = pending.filter { key, value in
                key != id && (value as? [String: Any])?["projectId"] as? String != serverID
            }
        }
        var result = state
        result[localKey] = local
        allMappings[host] = mapping; result[mappingKey] = allMappings
        if state[pendingKey] != nil { allPending[host] = pending; result[pendingKey] = allPending }
        let removed = Set(existing.keys).subtracting(local.keys)
        var order = (state["project-order"] as? [String] ?? []).filter { !removed.contains($0) }
        for id in local.keys.sorted() where !order.contains(id) { order.append(id) }
        result["project-order"] = order
        if let selected = state["selected-project"] as? [String: Any],
           selected["type"] as? String == "local", let id = selected["projectId"] as? String, removed.contains(id) {
            result["selected-project"] = NSNull()
        }
        return result
    }
}
