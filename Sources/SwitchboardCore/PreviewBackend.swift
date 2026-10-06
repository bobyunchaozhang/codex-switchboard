import Foundation

/// The preview uses official requests; it never implements token refresh itself.
public enum PreviewBackend {
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
