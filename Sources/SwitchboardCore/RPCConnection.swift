import Darwin
import Foundation

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct JSONLines {
    private var data = Data()
    mutating func append(_ chunk: Data) throws {
        guard data.count + chunk.count <= 8_388_608 else { throw SwitchboardFailure.unavailable }
        data.append(chunk)
    }
    mutating func next() -> Data? {
        guard let newline = data.firstIndex(of: 10) else { return nil }
        let line = Data(data[..<newline])
        data.removeSubrange(...newline)
        return line
    }
}

final class RPCConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var lines = JSONLines()
    private var nextID = 0
    private var notifications: [[String: Any]] = []
    private var closed = false
    private let cancellation: CancellationFlag

    init(executable: URL, home: String, cancellation: CancellationFlag = CancellationFlag(), experimental: Bool = false) throws {
        self.cancellation = cancellation
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let allowed = Set(["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "SSL_CERT_FILE"])
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        environment["CODEX_HOME"] = home
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            _ = try request("initialize", params: ["clientInfo": [
                "name": "codex_switchboard", "title": "Codex Switchboard", "version": "0.3.1"
            ], "capabilities": ["experimentalApi": experimental]])
            try send(["method": "initialized", "params": [:]])
        } catch { close(); throw error }
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let until = Date().addingTimeInterval(1)
            while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
    }

    func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 20) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let message = try receive(until: deadline)
            guard message["id"] as? Int == id else { try handle(message); continue }
            if let error = message["error"] as? [String: Any] {
                let description = (error["message"] as? String ?? "").lowercased()
                if description.contains("401") || description.contains("not authenticated") || description.contains("not logged in") {
                    throw SwitchboardFailure.signedOut
                }
                throw SwitchboardFailure.protocolError(error["code"] as? Int ?? -1)
            }
            guard let result = message["result"] as? [String: Any] else { throw SwitchboardFailure.unavailable }
            return result
        }
    }

    func waitForLogin(_ loginID: String) throws {
        let deadline = Date().addingTimeInterval(300)
        while true {
            let message: [String: Any]
            if !notifications.isEmpty { message = notifications.removeFirst() }
            else { message = try receive(until: deadline) }
            if message["method"] as? String == "account/login/completed",
               let params = message["params"] as? [String: Any],
               params["loginId"] as? String == loginID {
                guard params["success"] as? Bool == true else { throw SwitchboardFailure.unavailable }
                return
            }
            if message["id"] != nil { try handle(message) }
        }
    }

    private func handle(_ message: [String: Any]) throws {
        if let id = message["id"], message["method"] != nil {
            try send(["id": id, "error": ["code": -32601, "message": "Unsupported client request"]])
        } else if message["method"] != nil {
            if notifications.count < 128 { notifications.append(message) }
        }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(until deadline: Date) throws -> [String: Any] {
        while true {
            if cancellation.isCancelled { throw SwitchboardFailure.loginCancelled }
            if let line = lines.next() {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw SwitchboardFailure.unavailable
                }
                return object
            }
            guard Date() < deadline else { throw SwitchboardFailure.timeout }
            var pollDescriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pollDescriptor, 1, 200)
            if ready < 0 { if errno == EINTR { continue }; throw SwitchboardFailure.unavailable }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(pollDescriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw SwitchboardFailure.unavailable }
            try lines.append(Data(bytes.prefix(count)))
        }
    }
}
