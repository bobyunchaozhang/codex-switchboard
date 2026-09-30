import CryptoKit
import Darwin
import Foundation

public enum SharingFailure: Error, LocalizedError {
    case changed, invalidState, duplicateProjects, legacyOAuth, verification, busy, managedCollision
    public var errorDescription: String? {
        switch self {
        case .changed: return "Settings changed during preparation. Please try switching again."
        case .invalidState: return "Shared setup could not be read. Existing settings have been kept."
        case .duplicateProjects: return "Multiple project registrations use the same folders. Resolve the duplicates in Codex before switching."
        case .legacyOAuth: return "This account uses an OAuth credential file. Shared authorization needs a separate migration before switching."
        case .verification: return "Shared setup could not be verified. Please try again; your chats have been kept."
        case .busy: return "Shared setup is being updated. Please try again."
        case .managedCollision: return "A shared MCP name conflicts with an account-specific runtime service. Rename the custom MCP before switching."
        }
    }
}

// Payloads may contain MCP API keys. Persist only in the private application data directory;
// never include payloads in UI, diagnostics, or errors.
struct SharedEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case mcp, project }
    let kind: Kind
    let name: String
    let payload: Data
    var fingerprint: String { digest(payload) }
    init(kind: Kind, name: String, object: [String: Any]) throws {
        self.kind = kind; self.name = name
        payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func object() throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw SharingFailure.invalidState
        }
        return result
    }
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

struct SharedDocument: Codable, Sendable {
    var version = 2
    var entries: [String: SharedEntry] = [:]
    var baselines: [String: [String: String]] = [:]
}

struct HomeSetup: Sendable {
    let home: String
    let label: String
    let entries: [String: SharedEntry]
    let servers: [String: SharedEntry]
    let projectIDs: [String: String]
    let configVersion: String?
    let oauthStore: String?
    var desktopProjectCount: Int? = nil
    var desktopReady = false
    var desktopVersion: String? = nil
    var backendEntries: [String: SharedEntry] = [:]
}

public struct SetupChoice: Identifiable, Sendable {
    public let id: Int
    public let label: String
    let entry: SharedEntry?
}
public struct SetupConflict: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let choices: [SetupChoice]
    public let defaultChoice: Int
}

public struct SharedSetupPlan: Sendable {
    public let conflicts: [SetupConflict]
    public var serverCount: Int { document.entries.values.filter { $0.kind == .mcp }.count }
    public var desktopProjectCounts: [Int?] { snapshots.map(\.desktopProjectCount) }
    public var backendProjectCounts: [Int] { snapshots.map { $0.backendEntries.count } }
    public var projectCount: Int { document.entries.values.filter { $0.kind == .project }.count }
    var document: SharedDocument
    let snapshots: [HomeSetup]
    let registryFingerprint: String?
    var currentHome: String? = nil

    func resolved(_ choices: [String: Int]) throws -> SharedDocument {
        var result = document
        for conflict in conflicts {
            let selection = choices[conflict.id] ?? conflict.defaultChoice
            guard let choice = conflict.choices.first(where: { $0.id == selection }) else { throw SharingFailure.invalidState }
            result.entries[conflict.id] = choice.entry
        }
        return result
    }
}

enum SetupMerge {
    static func plan(document: SharedDocument, snapshots: [HomeSetup], currentHome: String?, fingerprint: String?) -> SharedSetupPlan {
        var result = document
        var conflicts: [SetupConflict] = []
        let keys = Set(document.entries.keys).union(snapshots.flatMap { $0.entries.keys })
            .union(snapshots.flatMap { document.baselines[$0.home]?.keys.map { $0 } ?? [] })
        for key in keys.sorted() {
            let shared = document.entries[key]
            var candidates: [(String, SharedEntry?, String?)] = []
            for snapshot in snapshots {
                let local = snapshot.entries[key]
                let baseline = document.baselines[snapshot.home]
                let previous = baseline?[key]
                let changed = baseline == nil ? local != nil : local?.fingerprint != previous
                guard changed, local != shared else { continue }
                // Retain a newer shared value when this home was edited from an older baseline.
                if shared?.fingerprint != previous, !candidates.contains(where: { $0.1 == shared }) {
                    candidates.append(("Shared setup", shared, nil))
                }
                candidates.append((snapshot.label, local, snapshot.home))
            }
            var unique: [(String, SharedEntry?, String?)] = []
            for candidate in candidates {
                if let index = unique.firstIndex(where: { $0.1 == candidate.1 }) {
                    if candidate.2 == currentHome { unique[index] = candidate }
                } else { unique.append(candidate) }
            }
            if unique.count == 1 { result.entries[key] = unique[0].1 }
            else if unique.count > 1 {
                let example = unique.compactMap { $0.1 }.first ?? shared
                conflicts.append(SetupConflict(id: key, name: example?.name ?? key,
                    kind: example?.kind == .project ? "Project" : "MCP server",
                    choices: unique.enumerated().map { SetupChoice(id: $0.offset,
                        label: $0.element.1 == nil ? "Removed — " + $0.element.0 : $0.element.0, entry: $0.element.1) },
                    defaultChoice: unique.firstIndex(where: { $0.2 == currentHome }) ?? 0))
            }
        }
        // Record what was actually observed, not the shared result that a home has not received yet.
        for snapshot in snapshots { result.baselines[snapshot.home] = snapshot.entries.mapValues(\.fingerprint) }
        return SharedSetupPlan(conflicts: conflicts, document: result, snapshots: snapshots, registryFingerprint: fingerprint, currentHome: currentHome)
    }
}

public struct SharedSetupService: Sendable {
    let executable: URL
    let directory: URL
    var file: URL { directory.appendingPathComponent("setup.json") }

    public init(executable: URL, directory: URL = AccountStore().directory.appendingPathComponent("Shared")) {
        self.executable = executable; self.directory = directory
    }

    public func prepare(accounts: [SavedAccount], currentHome: String?) async throws -> SharedSetupPlan {
        try await Task.detached {
            let (document, fingerprint) = try load()
            let snapshots = try accounts.map { try read(home: $0.home, label: $0.email) }
            return SetupMerge.plan(document: document, snapshots: snapshots, currentHome: currentHome, fingerprint: fingerprint)
        }.value
    }

    public func chatPreflight(_ plan: SharedSetupPlan) async throws -> (perHome: [Int], unique: Int, bytes: Int64) {
        try await Task.detached {
            let service = SharedChats(executable: executable, directory: directory.appendingPathComponent("Chats"))
            let lists = try plan.snapshots.map(service.collect)
            var ids = Set<String>()
            var bytes: Int64 = 0
            for chat in lists.flatMap({ $0 }) where ids.insert(chat.chat.id).inserted {
                try SharedChats.requireRegular(chat.path)
                let attributes = try FileManager.default.attributesOfItem(atPath: chat.path.path)
                bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
            return (lists.map(\.count), ids.count, bytes)
        }.value
    }

    // Called only after Desktop has exited and before the destination is launched.
    public func apply(_ plan: SharedSetupPlan, choices: [String: Int], target: SavedAccount) async throws {
        try await Task.detached {
            try privateDirectory(directory)
            let lock = Darwin.open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw SharingFailure.busy }
            defer { Darwin.close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SharingFailure.busy }
            guard try load().1 == plan.registryFingerprint else { throw SharingFailure.changed }
            guard let before = plan.snapshots.first(where: { $0.home == target.home }) else { throw SharingFailure.invalidState }
            var fresh = before
            for snapshot in plan.snapshots {
                let latest = try read(home: snapshot.home, label: snapshot.label)
                guard latest.entries == snapshot.entries, latest.configVersion == snapshot.configVersion,
                      latest.desktopVersion == snapshot.desktopVersion, latest.backendEntries == snapshot.backendEntries else { throw SharingFailure.changed }
                if snapshot.home == target.home { fresh = latest }
            }
            var document = try plan.resolved(choices)
            let needsWrite = !fresh.desktopReady || fresh.entries != document.entries || fresh.oauthStore != "keyring" || fresh.backendEntries != document.entries.filter { $0.value.kind == .project }
            if needsWrite {
                guard !FileManager.default.fileExists(atPath: URL(fileURLWithPath: fresh.home).appendingPathComponent(".credentials.json").path) else { throw SharingFailure.legacyOAuth }
                for (name, server) in fresh.servers where document.entries["mcp:" + name] != nil {
                    guard !Self.isDesktopManaged(name: name, object: try server.object()) else { throw SharingFailure.managedCollision }
                }
                try backup(fresh)
            }
            // Saving the desired result first makes partially completed operations retryable.
            try save(document)
            if needsWrite { try write(document.entries, to: fresh) }
            let after = try read(home: target.home, label: target.email)
            guard after.desktopReady, after.entries == document.entries,
                  after.backendEntries == document.entries.filter({ $0.value.kind == .project }) else { throw SharingFailure.verification }
            try SharedChats(executable: executable, directory: directory.appendingPathComponent("Chats"))
                .apply(homes: plan.snapshots.filter { $0.home != target.home } + [after], target: after, currentHome: plan.currentHome)
            document.baselines[target.home] = after.entries.mapValues(\.fingerprint)
            try save(document)
        }.value
    }

    private func load() throws -> (SharedDocument, String?) {
        guard FileManager.default.fileExists(atPath: file.path) else { return (SharedDocument(), nil) }
        do {
            let data = try Data(contentsOf: file)
            var value = try JSONDecoder().decode(SharedDocument.self, from: data)
            if value.version == 1 {
                // v1 observed backend-only registrations. Recollect visible desktop folders
                // once, rather than mistaking unsynchronized sidebar items for user deletions.
                value.entries = value.entries.filter { $0.value.kind != .project }
                value.baselines = value.baselines.mapValues { $0.filter { !$0.key.hasPrefix("project:") } }
                value.version = 2
            }
            guard value.version == 2 else { throw SharingFailure.invalidState }
            return (value, digest(data))
        } catch { throw SharingFailure.invalidState }
    }

    private func save(_ document: SharedDocument) throws {
        try privateDirectory(directory)
        try privateWrite(JSONEncoder().encode(document), to: file)
    }

    private func read(home: String, label: String) throws -> HomeSetup {
        let rpc = try RPCConnection(executable: executable, home: home, experimental: true)
        defer { rpc.close() }
        let response = try rpc.request("config/read", params: ["includeLayers": true, "cwd": home])
        let layers = response["layers"] as? [[String: Any]] ?? []
        let user = layers.first { ($0["name"] as? [String: Any])?["type"] as? String == "user" }
        if FileManager.default.fileExists(atPath: URL(fileURLWithPath: home).appendingPathComponent("config.toml").path), user == nil {
            throw SharingFailure.invalidState
        }
        let config = user?["config"] as? [String: Any] ?? [:]
        let rawServers = config["mcp_servers"] as? [String: [String: Any]] ?? [:]
        var servers: [String: SharedEntry] = [:]
        var entries: [String: SharedEntry] = [:]
        for (name, object) in rawServers {
            let entry = try SharedEntry(kind: .mcp, name: name, object: object)
            servers[name] = entry
            if !Self.isDesktopManaged(name: name, object: object) { entries["mcp:" + name] = entry }
        }
        var projects: [String: String] = [:]
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let page = try rpc.request("project/list", params: params)
            guard let values = page["data"] as? [[String: Any]] else { throw SharingFailure.invalidState }
            for value in values {
                guard let id = value["id"] as? String, let name = value["name"] as? String,
                      let roots = value["roots"] as? [[String: Any]], !roots.isEmpty else { throw SharingFailure.invalidState }
                let paths = try roots.map { root -> String in
                    guard let path = root["path"] as? String, path.hasPrefix("/") else { throw SharingFailure.invalidState }
                    return normalizedHome(path)
                }
                let key = try DesktopProjects.key(paths: paths)
                guard projects[key] == nil else { throw SharingFailure.duplicateProjects }
                entries[key] = try SharedEntry(kind: .project, name: name,
                    object: ["name": name, "roots": paths.map { ["path": $0] }])
                projects[key] = id
            }
            cursor = page["nextCursor"] as? String
            if let cursor, !seenCursors.insert(cursor).inserted { throw SharingFailure.invalidState }
        } while cursor != nil
        let backend = entries.filter { $0.value.kind == .project }
        let state = try DesktopProjects.read(home: home)
        let visible = try DesktopProjects.entries(state)
        if let visible {
            entries = entries.filter { $0.value.kind != .project }.merging(visible) { _, new in new }
        }
        return HomeSetup(home: home, label: label, entries: entries, servers: servers, projectIDs: projects,
                         configVersion: user?["version"] as? String, oauthStore: config["mcp_oauth_credentials_store"] as? String,
                         desktopProjectCount: visible?.count,
                         desktopReady: try DesktopProjects.isLinked(state, home: home, serverIDs: projects),
                         desktopVersion: try DesktopProjects.fingerprint(state, home: home), backendEntries: backend)
    }

    static func isDesktopManaged(name: String, object: [String: Any]) -> Bool {
        // These services are generated by the desktop and carry per-home runtime settings.
        if ["node_repl", "cua_repl"].contains(name) { return true }
        return (object["env"] as? [String: Any])?["CODEX_HOME"] != nil
    }

    private func write(_ entries: [String: SharedEntry], to snapshot: HomeSetup) throws {
        let credentialFile = URL(fileURLWithPath: snapshot.home).appendingPathComponent(".credentials.json")
        guard !FileManager.default.fileExists(atPath: credentialFile.path) else { throw SharingFailure.legacyOAuth }
        let desktopState = try DesktopProjects.read(home: snapshot.home)
        guard try DesktopProjects.fingerprint(desktopState, home: snapshot.home) == snapshot.desktopVersion else { throw SharingFailure.changed }
        let rpc = try RPCConnection(executable: executable, home: snapshot.home, experimental: true)
        defer { rpc.close() }
        var servers: [String: Any] = [:]
        for (name, entry) in snapshot.servers {
            let object = try entry.object()
            if Self.isDesktopManaged(name: name, object: object) { servers[name] = object }
        }
        for entry in entries.values where entry.kind == .mcp { servers[entry.name] = try entry.object() }
        let edits: [[String: Any]] = [
            ["keyPath": "mcp_servers", "mergeStrategy": "replace", "value": servers],
            ["keyPath": "mcp_oauth_credentials_store", "mergeStrategy": "replace", "value": "keyring"]
        ]
        var params: [String: Any] = ["edits": edits]
        if let version = snapshot.configVersion { params["expectedVersion"] = version }
        _ = try rpc.request("config/batchWrite", params: params)
        var serverIDs = snapshot.projectIDs
        // Modify project registrations only. These API calls do not migrate or remove chats.
        for (key, entry) in entries.sorted(by: { $0.key < $1.key }) where entry.kind == .project {
            var value = try entry.object()
            if let id = snapshot.projectIDs[key] {
                if snapshot.backendEntries[key] != entry {
                    value["projectId"] = id
                    _ = try rpc.request("project/update", params: value)
                }
            } else {
                value["idempotencyKey"] = "switchboard-" + UUID().uuidString
                let response = try rpc.request("project/create", params: value)
                guard let id = (response["project"] as? [String: Any])?["id"] as? String else { throw SharingFailure.verification }
                serverIDs[key] = id
            }
        }
        for (key, id) in snapshot.projectIDs where entries[key] == nil {
            _ = try rpc.request("project/delete", params: ["projectId": id])
        }
        // Re-read to preserve unrelated UI state; only project fields may change here.
        let latest = try DesktopProjects.read(home: snapshot.home)
        guard try DesktopProjects.fingerprint(latest, home: snapshot.home) == snapshot.desktopVersion else { throw SharingFailure.changed }
        let updated = try DesktopProjects.updated(latest, home: snapshot.home, entries: entries, serverIDs: serverIDs)
        try privateWrite(JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]),
                         to: URL(fileURLWithPath: snapshot.home).appendingPathComponent(DesktopProjects.filename))
    }

    private func backup(_ snapshot: HomeSetup) throws {
        let folder = directory.appendingPathComponent("Backups").appendingPathComponent(digest(Data(snapshot.home.utf8)))
        try privateDirectory(folder)
        try privateWrite(Data(snapshot.home.utf8), to: folder.appendingPathComponent("home.txt"))
        let source = URL(fileURLWithPath: snapshot.home).appendingPathComponent("config.toml")
        let original = folder.appendingPathComponent("original-config.toml")
        if FileManager.default.fileExists(atPath: source.path) {
            let data = try Data(contentsOf: source)
            if !FileManager.default.fileExists(atPath: original.path) { try privateWrite(data, to: original) }
            try privateWrite(data, to: folder.appendingPathComponent("previous-config.toml"))
        }
        let desktopData = try DesktopProjects.backupFields(DesktopProjects.read(home: snapshot.home))
        let originalDesktop = folder.appendingPathComponent("original-desktop-project-fields.json")
        if !FileManager.default.fileExists(atPath: originalDesktop.path) { try privateWrite(desktopData, to: originalDesktop) }
        try privateWrite(desktopData, to: folder.appendingPathComponent("previous-desktop-project-fields.json"))
        let projects = snapshot.entries.filter { $0.value.kind == .project }
        let projectData = try JSONEncoder().encode(projects)
        let originalProjects = folder.appendingPathComponent("original-projects.json")
        if !FileManager.default.fileExists(atPath: originalProjects.path) { try privateWrite(projectData, to: originalProjects) }
        try privateWrite(projectData, to: folder.appendingPathComponent("previous-projects.json"))
    }
}

func privateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

func privateWrite(_ data: Data, to url: URL) throws {
    // Set permissions before writing potentially sensitive MCP settings to disk.
    let staging = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
    let fd = Darwin.open(staging.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw SharingFailure.invalidState }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close(); try? FileManager.default.removeItem(at: staging) }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    guard Darwin.rename(staging.path, url.path) == 0 else { throw SharingFailure.invalidState }
}

// Stream potentially large chat backups without loading complete histories into RAM.
func privateCopy(_ source: URL, to destination: URL) throws {
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".copy-" + UUID().uuidString)
    let fd = Darwin.open(staging.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw ChatSharingFailure.storage }
    let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? output.close(); try? FileManager.default.removeItem(at: staging) }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { try output.write(contentsOf: chunk) }
    try output.synchronize()
    guard Darwin.rename(staging.path, destination.path) == 0 else { throw ChatSharingFailure.storage }
}
