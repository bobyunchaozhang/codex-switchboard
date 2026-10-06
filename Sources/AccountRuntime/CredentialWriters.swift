import Foundation
import SwitchboardCore

/// Only desktop and CLI processes own Codex login state. Plugins, crash
/// reporters, and rendering helpers can inherit CODEX_HOME without owning it.
struct CredentialWriters {
    struct Entry: Equatable {
        let pid: Int32
        let executable: String
    }

    static func inventory() throws -> [Entry] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-U", String(getuid()), "-o", "pid=,comm="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
            throw AccountFailure.writers
        }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]) else { return nil }
            return Entry(pid: pid, executable: String(fields[1]))
        }
    }

    static func ownsCredentials(_ entry: Entry, application: URL, cli: URL) -> Bool {
        let path = URL(fileURLWithPath: entry.executable).standardizedFileURL
        let name = path.lastPathComponent.lowercased()
        // Include independently launched Codex CLIs, not just desktop children.
        if name == "codex" || name == "codex-cli" { return true }
        if path == cli.standardizedFileURL || path == cli.resolvingSymlinksInPath() { return true }
        return path.deletingLastPathComponent() == application.appendingPathComponent("Contents/MacOS").standardizedFileURL
    }

    static func blockers(in entries: [Entry], home: String, application: URL, cli: URL,
                         ownPID: Int32 = getpid(),
                         readHome: (Int32) -> String? = ProcessHome.read,
                         isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> [Entry] {
        let target = normalizedHome(home)
        return entries.filter { entry in
            guard entry.pid != ownPID, ownsCredentials(entry, application: application, cli: cli) else { return false }
            guard let observed = readHome(entry.pid) else { return isAlive(entry.pid) }
            return observed == target && isAlive(entry.pid)
        }
    }
}

struct CredentialWriterBusy: LocalizedError {
    let pids: [Int32]
    var errorDescription: String? {
        "Codex is still using this environment (PID " + pids.map(String.init).joined(separator: ", ")
            + "). Close Codex or its CLI and retry."
    }
}
