import Darwin
import Foundation
import Security

public enum PreviewError: Error, LocalizedError {
    case storage, keychain, busy, recovery, identity, login, writers, legacyApp, environment, policy, renewCurrent
    public var errorDescription: String? {
        switch self {
        case .storage: return "Preview data could not be saved safely. Existing data was kept."
        case .keychain: return "The preview could not access its Keychain items. Allow access and retry."
        case .busy: return "Another preview operation is running."
        case .recovery: return "An interrupted operation needs recovery. Click Recover before continuing."
        case .identity: return "The expected account could not be verified. The switch was not accepted."
        case .login: return "Sign in again with this account before switching."
        case .writers: return "A Codex process is still using this preview environment. Close it and retry."
        case .legacyApp: return "Quit the regular Codex Switchboard from its menu before opening the test environment."
        case .environment: return "The current Codex environment could not be identified. Close Codex and retry."
        case .policy: return "This preview requires effective file-based login storage. Managed policy was not changed."
        case .renewCurrent: return "Return to the original environment first, then sign in to this account again."
        }
    }
}

public struct PreviewAccount: Codable, Identifiable, Equatable {
    public let id: UUID
    public var email: String
    public var plan: String?
    public var needsLogin: Bool = false
    public init(id: UUID = UUID(), email: String, plan: String?) {
        self.id = id; self.email = email; self.plan = plan
    }
}

struct WorkerJournal: Codable {
    let id: UUID
    let accountID: UUID?
    let login: Bool
    var materialized: Bool
    var completed = false
}

struct SwitchJournal: Codable {
    let target: UUID
    let previousAccount: UUID?
    let previousHome: String?
    let hadCredential: Bool
}

struct PreviewState: Codable {
    var version = 1
    var accounts: [PreviewAccount] = []
    // The active cache remains authoritative even when the desktop is closed.
    var active: UUID?
    var originalHome: String?
    var worker: WorkerJournal?
    var switching: SwitchJournal?
}

protocol CredentialVault {
    func read(_ name: String) throws -> Data?
    func write(_ data: Data, name: String) throws
    func remove(_ name: String) throws
}

struct KeychainVault: CredentialVault {
    private let service = "local.codex-switchboard.preview.credentials"
    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: name,
         kSecAttrSynchronizable as String: false]
    }
    func read(_ name: String) throws -> Data? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PreviewError.keychain }
        return data
    }
    func write(_ data: Data, name: String) throws {
        let q = query(name)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = q
            new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw PreviewError.keychain }
        } else if status != errSecSuccess { throw PreviewError.keychain }
    }
    func remove(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PreviewError.keychain }
    }
}

enum PrivateFile {
    static func directory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PreviewError.storage }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { throw PreviewError.storage }
    }
    static func read(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw PreviewError.storage }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 2_097_152,
              fchmod(fd, 0o600) == 0 else { throw PreviewError.storage }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { bytes in
            Darwin.read(fd, bytes.baseAddress!, bytes.count)
        }
        guard count == data.count else { throw PreviewError.storage }
        return data
    }
    static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        // Never follow a pre-existing symlink, including a dangling one.
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
                throw PreviewError.storage
            }
        } else if errno != ENOENT { throw PreviewError.storage }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PreviewError.storage }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PreviewError.storage }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw PreviewError.storage }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw PreviewError.storage }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw PreviewError.storage }
    }
    static func remove(_ url: URL) throws {
        if unlink(url.path) != 0 && errno != ENOENT { throw PreviewError.storage }
    }
}

final class PreviewStore {
    let root: URL
    let vault: CredentialVault
    var home: URL { root.appendingPathComponent("Work") }
    var project: URL { root.appendingPathComponent("Test Project") }
    private var lockFD: Int32 = -1
    private var stateURL: URL { root.appendingPathComponent("state.json") }

    init(root: URL, vault: CredentialVault = KeychainVault()) throws {
        self.root = root.standardizedFileURL; self.vault = vault
        try PrivateFile.directory(self.root)
        guard self.root.resolvingSymlinksInPath().path == self.root.path else { throw PreviewError.storage }
        lockFD = open(root.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            throw PreviewError.busy
        }
        try prepare(home)
        try PrivateFile.directory(project)
        let readme = project.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try PrivateFile.write(Data("# Switchboard validation\n\nCreate one chat here with account A. Continue that same chat with B, then A.\n".utf8), to: readme)
        }
    }
    deinit { if lockFD >= 0 { close(lockFD) } }
    func prepare(_ home: URL) throws {
        try PrivateFile.directory(home)
        let config = home.appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: config.path) {
            try PrivateFile.write(Data("cli_auth_credentials_store = \"file\"\n[analytics]\nenabled = false\n".utf8), to: config)
        }
    }
    func load() throws -> PreviewState {
        guard let data = try PrivateFile.read(stateURL) else { return PreviewState() }
        guard let state = try? JSONDecoder().decode(PreviewState.self, from: data), state.version == 1,
              Set(state.accounts.map(\.id)).count == state.accounts.count,
              Set(state.accounts.map { $0.email.lowercased() }).count == state.accounts.count,
              state.accounts.allSatisfy({ !$0.email.isEmpty }),
              state.active == nil || state.accounts.contains(where: { $0.id == state.active }) else { throw PreviewError.storage }
        return state
    }
    func save(_ state: PreviewState) throws { try PrivateFile.write(JSONEncoder().encode(state), to: stateURL) }
    func workerHome(_ worker: WorkerJournal) -> URL {
        root.appendingPathComponent("Workers").appendingPathComponent(worker.id.uuidString)
    }
    func credential(_ home: URL) throws -> Data? {
        guard let data = try PrivateFile.read(home.appendingPathComponent("auth.json")) else { return nil }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw PreviewError.storage }
        return data
    }
    func install(_ data: Data?, in home: URL) throws {
        if let data { try PrivateFile.write(data, to: home.appendingPathComponent("auth.json")) }
        else { try PrivateFile.remove(home.appendingPathComponent("auth.json")) }
    }
    func saveCredential(_ data: Data?, id: UUID) throws {
        if let data { try vault.write(data, name: id.uuidString) }
        else { try vault.remove(id.uuidString) }
    }
}
