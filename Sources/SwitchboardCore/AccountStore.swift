import Foundation

public struct AccountStore: Sendable {
    private struct Document: Codable { let version: Int; let accounts: [SavedAccount] }
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("accounts.json") }

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Switchboard")) {
        self.directory = directory
    }

    public func load() throws -> [SavedAccount]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1 else { throw SwitchboardFailure.storage }
            try Self.validate(document.accounts)
            return document.accounts
        } catch { throw SwitchboardFailure.storage }
    }

    public func save(_ accounts: [SavedAccount]) throws {
        do {
            try Self.validate(accounts)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Document(version: 1, accounts: accounts))
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { throw SwitchboardFailure.storage }
    }

    public func newHome() throws -> String {
        let home = directory.appendingPathComponent("Accounts").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return home.path
    }

    private static func validate(_ accounts: [SavedAccount]) throws {
        guard Set(accounts.map(\.id)).count == accounts.count,
              Set(accounts.map { normalizedHome($0.home) }).count == accounts.count,
              Set(accounts.map { $0.email.lowercased() }).count == accounts.count,
              accounts.allSatisfy({ $0.home.hasPrefix("/") && !$0.email.isEmpty }) else {
            throw SwitchboardFailure.storage
        }
    }
}
