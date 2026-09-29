import Foundation

public struct CodexService: Sendable {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public func identity(home: String) async throws -> Identity? {
        try await Task.detached {
            let rpc = try RPCConnection(executable: executable, home: home)
            defer { rpc.close() }
            return try Self.identity(rpc)
        }.value
    }

    public func read(home: String) async -> Reading {
        await Task.detached {
            do {
                let rpc = try RPCConnection(executable: executable, home: home)
                defer { rpc.close() }
                guard let before = try Self.identity(rpc) else { return Reading(identity: nil, usage: nil, needsLogin: true) }
                let usage: Usage?
                var needsLogin = false
                do {
                    let result = try rpc.request("account/rateLimits/read")
                    usage = try UsageDecoder.decode(JSONSerialization.data(withJSONObject: result))
                } catch SwitchboardFailure.signedOut { usage = nil; needsLogin = true }
                catch { usage = nil }
                guard let after = try Self.identity(rpc), after.matches(before.email) else {
                    return Reading(identity: nil, usage: nil)
                }
                return Reading(identity: after, usage: usage, needsLogin: needsLogin)
            } catch SwitchboardFailure.signedOut { return Reading(identity: nil, usage: nil, needsLogin: true) }
            catch { return Reading(identity: nil, usage: nil) }
        }.value
    }

    public func login(home: String, cancellation: CancellationFlag,
                      openURL: @escaping @Sendable (URL) -> Void) async throws -> Identity {
        try await Task.detached {
            let rpc = try RPCConnection(executable: executable, home: home, cancellation: cancellation)
            defer { rpc.close() }
            let result = try rpc.request("account/login/start", params: ["type": "chatgpt"])
            guard let raw = result["authUrl"] as? String, let url = URL(string: raw),
                  url.scheme == "https", let host = url.host,
                  ["openai.com", "chatgpt.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  let loginID = result["loginId"] as? String else { throw SwitchboardFailure.unavailable }
            openURL(url)
            try rpc.waitForLogin(loginID)
            guard let identity = try Self.identity(rpc) else { throw SwitchboardFailure.signedOut }
            return identity
        }.value
    }

    public func logout(_ account: SavedAccount, stillNonCurrent: @escaping @Sendable () -> Bool) async throws {
        try await Task.detached {
            let rpc = try RPCConnection(executable: executable, home: account.home)
            defer { rpc.close() }
            let identity = try Self.identity(rpc)
            if let identity, !identity.matches(account.email) { throw SwitchboardFailure.identityChanged }
            guard stillNonCurrent() else { throw SwitchboardFailure.currentUnknown }
            _ = try rpc.request("account/logout")
            guard try Self.identity(rpc) == nil else { throw SwitchboardFailure.unavailable }
        }.value
    }

    private static func identity(_ rpc: RPCConnection) throws -> Identity? {
        let result = try rpc.request("account/read", params: ["refreshToken": false])
        guard let account = result["account"] as? [String: Any] else { return nil }
        guard account["type"] as? String == "chatgpt",
              let email = account["email"] as? String, !email.isEmpty else { throw SwitchboardFailure.unavailable }
        return Identity(email: email, plan: account["planType"] as? String)
    }
}
