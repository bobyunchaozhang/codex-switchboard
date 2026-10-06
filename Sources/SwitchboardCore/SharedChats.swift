import Darwin
import Foundation

public enum ChatSharingFailure: Error, LocalizedError {
    case conflict, storage, unsupportedLocation, verification, lineage
    public var errorDescription: String? {
        switch self {
        case .lineage: return "Earlier project chat history is missing or invalid. Switching was stopped; original chats have been kept."
        case .conflict: return "A project chat has conflicting local copies. Switching was stopped; no chat was overwritten."
        case .storage: return "Project chats could not be shared. Your original chats have been kept."
        case .unsupportedLocation: return "Shared project chats require regular session files on the same local disk."
        case .verification: return "Project chats could not be verified. Please try switching again."
        }
    }
}

struct SharedChat: Codable {
    let id: String
    var projectKey: String
    var title: String?
    var archived: Bool
    var relativePath: String
}
struct ChatManifest: Codable {
    var version = 1
    var homes: [String] = []
    var chats: [String: SharedChat] = [:]
}
struct ObservedChat {
    let chat: SharedChat
    let home: String
    let path: URL
}

// Called under SharedSetup's lock, after the desktop has fully exited.
// Databases remain separate. Only project-owned rollout files share storage;
// official resume/metadata requests rebuild each destination's own indexes.
struct SharedChats {
    let executable: URL
    let directory: URL
    var manifestURL: URL { directory.appendingPathComponent("chats.json") }

    func collect(_ home: HomeSetup) throws -> [ObservedChat] {
        let rpc = try RPCConnection(executable: executable, home: home.home, experimental: true)
        defer { rpc.close() }
        let state = try DesktopProjects.read(home: home.home)
        let local = try DesktopProjects.projects(state) ?? [:]
        var localKeys: [String: String] = [:]
        for (id, project) in local {
            if let paths = project["rootPaths"] as? [String], !paths.isEmpty {
                localKeys[id] = try DesktopProjects.key(paths: paths)
            }
        }
        let assignments = state["thread-project-assignments"] as? [String: [String: Any]] ?? [:]
        let explicitProjectless = Set(state["projectless-thread-ids"] as? [String] ?? [])
        let serverKeys = Dictionary(uniqueKeysWithValues: home.projectIDs.map { ($0.value, $0.key) })
        var result: [ObservedChat] = []
        for archived in [false, true] {
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var params: [String: Any] = ["limit": 100, "archived": archived, "modelProviders": [], "useStateDbOnly": true]
                if let cursor { params["cursor"] = cursor }
                let page = try rpc.request("thread/list", params: params)
                guard let values = page["data"] as? [[String: Any]] else { throw ChatSharingFailure.verification }
                for value in values {
                    guard let id = value["id"] as? String, UUID(uuidString: id) != nil else { throw ChatSharingFailure.verification }
                    if explicitProjectless.contains(id) { continue }
                    let assignment = assignments[id]
                    let key: String?
                    if let assignment {
                        // A desktop assignment takes precedence over a stale backend mapping.
                        key = assignment["projectKind"] as? String == "local"
                            ? (assignment["projectId"] as? String).flatMap { localKeys[$0] } : nil
                    } else {
                        key = (value["projectId"] as? String).flatMap { serverKeys[$0] }
                    }
                    guard let key, home.entries[key]?.kind == .project else { continue }
                    // An empty unsaved draft has no rollout yet and is not a durable chat.
                    guard let path = value["path"] as? String else { continue }
                    let url = URL(fileURLWithPath: path)
                    if !FileManager.default.fileExists(atPath: path) { throw ChatSharingFailure.storage }
                    let relative = try Self.relativePath(url, home: home.home, id: id)
                    try Self.requireThreadID(url, id: id)
                    let chat = SharedChat(id: id, projectKey: key, title: value["name"] as? String,
                                          archived: archived, relativePath: relative)
                    result.append(ObservedChat(chat: chat, home: home.home, path: url))
                }
                cursor = page["nextCursor"] as? String
                if let cursor, !seen.insert(cursor).inserted { throw ChatSharingFailure.verification }
            } while cursor != nil
        }
        return result
    }

    func apply(homes: [HomeSetup], target: HomeSetup, currentHome: String?) throws {
        let observed = try homes.flatMap(collect)
        var manifest = try load()
        manifest.homes = Array(Set(manifest.homes + homes.map(\.home))).sorted()
        let groups = Dictionary(grouping: observed, by: { $0.chat.id })
        let targetProjects = target.entries.filter { $0.value.kind == .project }
        // Validate every candidate before creating links or changing any index.
        for (id, values) in groups {
            let preferred = values.first(where: { $0.home == currentHome }) ?? values.first!
            guard targetProjects[preferred.chat.projectKey] != nil else { continue }
            if Set(values.map { $0.chat.projectKey }).count > 1 { throw ChatSharingFailure.conflict }
            let canonical = canonicalURL(id)
            let baseline = FileManager.default.fileExists(atPath: canonical.path) ? canonical : preferred.path
            for value in values { try Self.requireSameContents(baseline, value.path) }
            var selected = preferred.chat
            // An inactive account must not roll back a rename or archived state.
            if !values.contains(where: { $0.home == currentHome }), let previous = manifest.chats[id] {
                selected = previous
            }
            // Recover the original continuation filename from any identical source.
            if let continuation = values.first(where: { $0.path.lastPathComponent.contains("_") }) {
                selected.relativePath = continuation.chat.relativePath
            }
            manifest.chats[id] = selected
        }
        let selected = manifest.chats.values.filter { targetProjects[$0.projectKey] != nil }.sorted { $0.id < $1.id }
        var dependencies: [String: [ChatLineage.Dependency]] = [:]
        for chat in selected {
            let canonical = canonicalURL(chat.id)
            let source = groups[chat.id]?.first?.path ?? canonical
            try Self.requireThreadID(source, id: chat.id)
            dependencies[chat.id] = try ChatLineage.dependencies(of: source, homes: homes.map(\.home))
            let destination = try targetPath(chat, observed: observed, target: target.home)
            if FileManager.default.fileExists(atPath: destination.path) { try Self.requireSameContents(source, destination) }
            let device = try FileManager.default.attributesOfItem(atPath: source.path)[.systemNumber] as? NSNumber
            let targetDevice = try FileManager.default.attributesOfItem(atPath: target.home)[.systemNumber] as? NSNumber
            guard device == targetDevice else { throw ChatSharingFailure.unsupportedLocation }
        }
        try privateDirectory(directory)
        try privateDirectory(directory.appendingPathComponent("Sessions"))
        try privateDirectory(directory.appendingPathComponent("Backups"))
        for chat in selected {
            let canonical = canonicalURL(chat.id)
            if !FileManager.default.fileExists(atPath: canonical.path) {
                guard let source = groups[chat.id]?.first?.path else { throw ChatSharingFailure.storage }
                // A real copy is retained once, before sharing; a hard link is not a backup.
                let backup = directory.appendingPathComponent("Backups").appendingPathComponent(chat.id + ".jsonl")
                if !FileManager.default.fileExists(atPath: backup.path) { try privateCopy(source, to: backup) }
                try Self.link(source, to: canonical)
            }
            try ChatLineage.install(dependencies[chat.id] ?? [], target: target.home)
            // Equal independent files are backed up before linking. Differing copies never overwrite.
            for value in groups[chat.id] ?? [] { try attach(canonical, to: value.path, id: chat.id, home: value.home) }
            let destination = try targetPath(chat, observed: observed, target: target.home)
            try attach(canonical, to: destination, id: chat.id, home: target.home)
            try ChatLineage.retireLegacyAlias(continuation: destination,
                backupDirectory: directory.appendingPathComponent("Backups/LegacyAliases"), home: target.home)
        }
        try privateWrite(JSONEncoder().encode(manifest), to: manifestURL)
        guard !selected.isEmpty else { return }
        try refreshIndexes(selected, observed: observed, target: target)
    }

    private func refreshIndexes(_ chats: [SharedChat], observed: [ObservedChat], target: HomeSetup) throws {
        let state = try DesktopProjects.read(home: target.home)
        let local = try DesktopProjects.projects(state) ?? [:]
        var localIDs: [String: String] = [:]
        for (id, project) in local {
            if let paths = project["rootPaths"] as? [String], !paths.isEmpty { localIDs[try DesktopProjects.key(paths: paths)] = id }
        }
        let rpc = try RPCConnection(executable: executable, home: target.home, experimental: true)
        defer { rpc.close() }
        for chat in chats {
            guard let serverID = target.projectIDs[chat.projectKey], localIDs[chat.projectKey] != nil else { throw ChatSharingFailure.verification }
            if observed.contains(where: { $0.home == target.home && $0.chat.id == chat.id && $0.chat.archived }) {
                _ = try rpc.request("thread/unarchive", params: ["threadId": chat.id])
            }
            // Loading the shared rollout rebuilds stale per-home turn/item indexes.
            let response = try rpc.request("thread/resume", params: ["threadId": chat.id, "path": URL(fileURLWithPath: target.home).appendingPathComponent(chat.relativePath).path, "excludeTurns": true], timeout: 60)
            guard let thread = response["thread"] as? [String: Any], thread["id"] as? String == chat.id else { throw ChatSharingFailure.verification }
            _ = try rpc.request("thread/metadata/update", params: ["threadId": chat.id, "projectId": serverID])
            if let title = chat.title, !title.isEmpty { _ = try rpc.request("thread/name/set", params: ["threadId": chat.id, "name": title]) }
            _ = try rpc.request("thread/unsubscribe", params: ["threadId": chat.id])
            if chat.archived { _ = try rpc.request("thread/archive", params: ["threadId": chat.id]) }
            let read = try rpc.request("thread/read", params: ["threadId": chat.id, "includeTurns": false])
            guard let saved = read["thread"] as? [String: Any], saved["projectId"] as? String == serverID,
                  let path = saved["path"] as? String,
                  try Self.sameFile(URL(fileURLWithPath: path), canonicalURL(chat.id)) else { throw ChatSharingFailure.verification }
        }
        // Preserve all unrelated UI state; assign only the imported project chats.
        var latest = try DesktopProjects.read(home: target.home)
        let fields = ["thread-project-assignments", "thread-project-membership-host-ids", "projectless-thread-ids"]
        let backup = directory.appendingPathComponent("Backups").appendingPathComponent(digest(Data(target.home.utf8)) + "-desktop.json")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try privateWrite(JSONSerialization.data(withJSONObject: latest.filter { fields.contains($0.key) }), to: backup)
        }
        var assignments = latest["thread-project-assignments"] as? [String: [String: Any]] ?? [:]
        var hosts = latest["thread-project-membership-host-ids"] as? [String: String] ?? [:]
        let ids = Set(chats.map(\.id))
        for chat in chats {
            assignments[chat.id] = ["projectKind": "local", "projectId": localIDs[chat.projectKey]!]
            hosts[chat.id] = "local"
        }
        latest["thread-project-assignments"] = assignments
        latest["thread-project-membership-host-ids"] = hosts
        if let projectless = latest["projectless-thread-ids"] as? [String] { latest["projectless-thread-ids"] = projectless.filter { !ids.contains($0) } }
        try privateWrite(JSONSerialization.data(withJSONObject: latest, options: [.sortedKeys]),
                         to: URL(fileURLWithPath: target.home).appendingPathComponent(DesktopProjects.filename))
    }

    private func load() throws -> ChatManifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return ChatManifest() }
        let result = try JSONDecoder().decode(ChatManifest.self, from: Data(contentsOf: manifestURL))
        guard result.version == 1, result.chats.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.key == $0.value.id }) else { throw ChatSharingFailure.storage }
        return result
    }
    private func canonicalURL(_ id: String) -> URL { directory.appendingPathComponent("Sessions").appendingPathComponent(id + ".jsonl") }
    private func targetPath(_ chat: SharedChat, observed: [ObservedChat], target: String) throws -> URL {
        if let existing = observed.first(where: { $0.home == target && $0.chat.id == chat.id }),
           existing.path.lastPathComponent == URL(fileURLWithPath: chat.relativePath).lastPathComponent {
            return existing.path
        }

        // New imports start active so App Server can index them, then archive if needed.
        let path = URL(fileURLWithPath: target).appendingPathComponent(chat.relativePath)
        _ = try Self.relativePath(path, home: target, id: chat.id)
        return path
    }
    static func relativePath(_ path: URL, home: String, id: String) throws -> String {
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/"
        let full = path.standardizedFileURL.path
        let resolved = path.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root), path.lastPathComponent.hasPrefix("rollout-"), path.lastPathComponent.contains(id), path.pathExtension == "jsonl" else {
            throw ChatSharingFailure.unsupportedLocation
        }
        let relative = String(resolved.dropFirst(root.count))
        guard relative.hasPrefix("sessions/") || relative.hasPrefix("archived_sessions/") else { throw ChatSharingFailure.unsupportedLocation }
        // Retain the standard rollout date layout even when the source is archived.
        let date = String(path.lastPathComponent.dropFirst(8).prefix(10)).split(separator: "-")
        guard date.count == 3, date.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), !full.isEmpty else { throw ChatSharingFailure.unsupportedLocation }
        // The suffix identifies a continuation; removing it can make its base
        // reference resolve to itself. Resume by explicit path instead.
        return "sessions/" + date.joined(separator: "/") + "/" + path.lastPathComponent
    }
    static func requireThreadID(_ path: URL, id: String) throws {
        try requireRegular(path)
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var header = Data()
        while header.count <= 8_388_608 {
            guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else { throw ChatSharingFailure.verification }
            header.append(chunk)
            if let end = header.firstIndex(of: 10) {
                guard let record = try JSONSerialization.jsonObject(with: header[..<end]) as? [String: Any],
                      record["type"] as? String == "session_meta",
                      (record["payload"] as? [String: Any])?["id"] as? String == id else { throw ChatSharingFailure.verification }
                return
            }
        }
        throw ChatSharingFailure.verification
    }

    static func requireRegular(_ path: URL) throws {
        let info = try FileManager.default.attributesOfItem(atPath: path.path)
        guard info[.type] as? FileAttributeType == .typeRegular else { throw ChatSharingFailure.unsupportedLocation }
    }
    static func sameFile(_ a: URL, _ b: URL) throws -> Bool {
        let x = try FileManager.default.attributesOfItem(atPath: a.path), y = try FileManager.default.attributesOfItem(atPath: b.path)
        return x[.systemNumber] as? NSNumber == y[.systemNumber] as? NSNumber && x[.systemFileNumber] as? NSNumber == y[.systemFileNumber] as? NSNumber
    }
    static func requireSameContents(_ a: URL, _ b: URL) throws {
        try requireRegular(a); try requireRegular(b)
        if try sameFile(a, b) { return }
        guard FileManager.default.contentsEqual(atPath: a.path, andPath: b.path) else { throw ChatSharingFailure.conflict }
    }
    private static func link(_ source: URL, to destination: URL) throws {
        guard Darwin.link(source.path, destination.path) == 0 else { throw ChatSharingFailure.unsupportedLocation }
    }
    private func attach(_ source: URL, to destination: URL, id: String, home: String) throws {
        try privateDirectory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            try Self.requireSameContents(source, destination)
            if try Self.sameFile(source, destination) { return }
            let backup = directory.appendingPathComponent("Backups").appendingPathComponent(id + "-" + digest(Data(home.utf8)) + ".jsonl")
            if !FileManager.default.fileExists(atPath: backup.path) { try privateCopy(destination, to: backup) }
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".sharing-" + UUID().uuidString)
            try Self.link(source, to: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            guard Darwin.rename(staging.path, destination.path) == 0 else { throw ChatSharingFailure.storage }
        } else { try Self.link(source, to: destination) }
    }
}
