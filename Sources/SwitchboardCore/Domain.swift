import Foundation

public func normalizedHome(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

public struct SavedAccount: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let home: String
    public var email: String
    public var plan: String?

    public init(id: UUID = UUID(), home: String, email: String, plan: String? = nil) {
        self.id = id
        self.home = normalizedHome(home)
        self.email = email
        self.plan = plan
    }
}

public struct Identity: Decodable, Equatable, Sendable {
    public let email: String
    public let plan: String?
    public init(email: String, plan: String?) { self.email = email; self.plan = plan }
    public func matches(_ email: String) -> Bool { self.email.caseInsensitiveCompare(email) == .orderedSame }
}

public struct Quota: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let remaining: Double
    public let resetsAt: Date?
}

public struct Usage: Equatable, Sendable {
    public let quotas: [Quota]
    public let resetCount: Int?
    public let resetCredits: [ResetCredit]?
}

public struct ResetCredit: Identifiable, Equatable, Sendable {
    public enum Expiry: Equatable, Sendable { case at(Date), never, unknown }
    public let id: Int
    public let title: String?
    public let expiry: Expiry
    public let status: String?

    public func available(at date: Date) -> Bool {
        guard status == "available" else { return false }
        if case .at(let expiry) = expiry { return expiry > date }
        return true
    }
}

extension Usage {
    public func nextCreditExpiry(at date: Date) -> Date? {
        resetCredits?.filter { $0.available(at: date) }.compactMap {
            if case .at(let expiry) = $0.expiry { return expiry }
            return nil
        }.min()
    }

    public func hasIncompleteCreditDetails(at date: Date) -> Bool {
        guard let resetCount, let resetCredits else { return true }
        let available = resetCredits.filter { $0.available(at: date) }
        return available.count < resetCount || available.contains { $0.expiry == .unknown }
    }
}

public struct Reading: Sendable {
    public let identity: Identity?
    public let usage: Usage?
    public let needsLogin: Bool
    public init(identity: Identity?, usage: Usage?, needsLogin: Bool = false) {
        self.identity = identity; self.usage = usage; self.needsLogin = needsLogin
    }
}

public enum DesktopPresence: Equatable, Sendable {
    case stopped
    case running(pid: Int32, home: String)
    case unknown
    public var home: String? {
        if case .running(_, let home) = self { return home }
        return nil
    }
}

public enum RemovalPolicy {
    public static func allows(_ account: SavedAccount, desktop: DesktopPresence, identity: Identity?) -> Bool {
        switch desktop {
        case .stopped, .unknown: return false
        case .running(_, let home):
            guard normalizedHome(home) != normalizedHome(account.home), let identity else { return false }
            return !identity.matches(account.email)
        }
    }
}

public enum SwitchboardFailure: Error, LocalizedError, Sendable {
    case unavailable, timeout, signedOut, identityChanged, currentAccount, currentUnknown
    case desktopMissing, quitFailed, launchFailed, loginCancelled, duplicateAccount, storage
    case protocolError(Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable, .protocolError: return "Unavailable"
        case .timeout: return "Codex did not respond in time."
        case .signedOut: return "Sign in required."
        case .identityChanged: return "The account identity has changed. Sign in with the saved email."
        case .currentAccount: return "The current account cannot be removed."
        case .currentUnknown: return "The current account could not be confirmed."
        case .desktopMissing: return "Codex desktop could not be found."
        case .quitFailed: return "Codex did not finish quitting. Try again after it closes."
        case .launchFailed: return "Codex could not be started."
        case .loginCancelled: return "Sign in cancelled."
        case .duplicateAccount: return "This account has already been added."
        case .storage: return "Account changes could not be saved."
        }
    }
}

public enum PlanLabel {
    public static func text(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Plan unavailable" }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "free": return "Free"
        case "team", "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "self_serve_business_prolite": return "Business Pro Lite"
        case "self_serve_business_pro": return "Business Pro"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
