import Foundation

/// Switchboard uses official requests; it never implements token refresh itself.
public enum AuthBackend {
    public static func ensureFileConfiguration(executable: URL, home: String) async throws {
        try await Task.detached {
            let rpc = try RPCConnection(executable: executable, home: home)
            defer { rpc.close() }
            let result = try rpc.request("config/read", params: ["includeLayers": false])
            guard let config = result["config"] as? [String: Any] else { throw SwitchboardFailure.storage }
            if let mode = config["cli_auth_credentials_store"] as? String, mode != "file" { throw SwitchboardFailure.storage }
            _ = try rpc.request("config/value/write", params: ["keyPath": "cli_auth_credentials_store", "value": "file", "mergeStrategy": "replace"])
        }.value
        try await validateConfiguration(executable: executable, home: home)
    }
    public static func validateConfiguration(executable: URL, home: String) async throws {
        try await Task.detached {
            let rpc = try RPCConnection(executable: executable, home: home)
            defer { rpc.close() }
            let result = try rpc.request("config/read", params: ["includeLayers": false])
            guard let config = result["config"] as? [String: Any],
                  config["cli_auth_credentials_store"] as? String == "file" else {
                throw SwitchboardFailure.storage
            }
        }.value
    }
}
