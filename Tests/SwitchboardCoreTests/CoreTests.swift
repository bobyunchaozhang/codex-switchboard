import Foundation
@testable import SwitchboardCore

struct CoreChecks {
    func testResetCreditExpiriesAndPartialDetails() throws {
        let json = #"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":4,"credits":[{"title":"Later","status":"available","expiresAt":2000},{"title":"Used","status":"redeemed","expiresAt":1200},{"title":"Earlier","status":"available","expiresAt":1500},{"status":"available","expiresAt":null},{"status":"available"}]}}"#
        let usage = try UsageDecoder.decode(Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1000)
        try expectEqual(usage.resetCredits?.count, 5)
        try expectEqual(usage.nextCreditExpiry(at: now), Date(timeIntervalSince1970: 1500))
        try expectEqual(usage.nextCreditExpiry(at: Date(timeIntervalSince1970: 1600)), Date(timeIntervalSince1970: 2000))
        try expectTrue(usage.hasIncompleteCreditDetails(at: now))
        try expectEqual(usage.resetCredits?.last?.expiry, .unknown)
        try expectEqual(usage.resetCredits?[3].expiry, .never)
        let partial = try UsageDecoder.decode(Data(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":3,"credits":[{"status":"available","expiresAt":2000}]}}"#.utf8))
        try expectTrue(partial.hasIncompleteCreditDetails(at: now))
        let never = try UsageDecoder.decode(Data(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":1,"credits":[{"status":"available","expiresAt":null}]}}"#.utf8))
        try expectFalse(never.hasIncompleteCreditDetails(at: now))
        try expectNil(never.nextCreditExpiry(at: now))
        let malformed = try UsageDecoder.decode(Data(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":1,"credits":[{"status":"available","expiresAt":"bad"}]}}"#.utf8))
        try expectEqual(malformed.resetCredits?.first?.expiry, .unknown)
        try expectEqual(malformed.resetCount, 1)
    }

    func testEveryBucketAndWindowIsKept() throws {
        let json = #"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12.5,"windowDurationMins":300},"secondary":{"usedPercent":101,"windowDurationMins":10080}},"other":{"primary":{"usedPercent":-1}}},"rateLimitResetCredits":{"availableCount":5,"credits":[]}}"#
        let usage = try UsageDecoder.decode(Data(json.utf8))
        try expectEqual(usage.quotas.count, 3)
        try expectEqual(usage.quotas.map(\.remaining), [87.5, 0, 100])
        try expectEqual(usage.resetCount, 5)
        try expectNil(usage.quotas[0].resetsAt)
    }

    func testUnavailableCreditCountIsNotZero() throws {
        let usage = try UsageDecoder.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":50}},"rateLimitResetCredits":null}"#.utf8))
        try expectNil(usage.resetCount)
        try expectEqual(usage.quotas.first?.title, "Primary window")
    }

    func testLegacyFallbackAndZeroCredits() throws {
        let usage = try UsageDecoder.decode(Data(#"{"rateLimits":{"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1800000000}},"rateLimitsByLimitId":{},"rateLimitResetCredits":{"availableCount":0}}"#.utf8))
        try expectEqual(usage.quotas.first?.title, "Weekly")
        try expectEqual(usage.quotas.first?.remaining, 100)
        try expectEqual(usage.resetCount, 0)
    }

    func testCurrentAccountCannotBeRemovedEvenThroughAnotherProfile() throws {
        let account = SavedAccount(home: "/tmp/b", email: "Person@example.com")
        let same = Identity(email: "person@example.com", plan: nil)
        try expectFalse(RemovalPolicy.allows(account, desktop: .running(pid: 1, home: "/tmp/a"), identity: same))
        try expectFalse(RemovalPolicy.allows(account, desktop: .unknown, identity: nil))
        try expectFalse(RemovalPolicy.allows(account, desktop: .stopped, identity: nil))
        try expectFalse(RemovalPolicy.allows(account, desktop: .running(pid: 1, home: account.home), identity: same))
    }

    func testLastNonCurrentAccountCanBeRemoved() throws {
        let account = SavedAccount(home: "/tmp/b", email: "other@example.com")
        try expectTrue(RemovalPolicy.allows(account, desktop: .running(pid: 1, home: "/tmp/a"),
                                           identity: Identity(email: "current@example.com", plan: nil)))
    }

    func testEmptyRegistryStaysEmptyAndCorruptionIsNotOverwritten() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = AccountStore(directory: temp)
        try expectNil(try store.load())
        try store.save([])
        try expectEqual(try store.load(), [])
        let broken = Data("broken registry".utf8)
        try broken.write(to: store.file)
        try expectThrows(try store.load())
        try expectEqual(try Data(contentsOf: store.file), broken)
    }

    func testDuplicateEmailIsRejected() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try expectThrows(try AccountStore(directory: temp).save([
            SavedAccount(home: "/tmp/a", email: "User@example.com"),
            SavedAccount(home: "/tmp/b", email: "user@example.com")
        ]))
    }

    func testLineBufferPreservesPartialAndCoalescedMessages() throws {
        var lines = JSONLines()
        try lines.append(Data("{\"id\":".utf8))
        try expectNil(lines.next())
        try lines.append(Data("1}\n{\"id\":2}\n".utf8))
        try expectEqual(String(data: try require(lines.next()), encoding: .utf8), "{\"id\":1}")
        try expectEqual(String(data: try require(lines.next()), encoding: .utf8), "{\"id\":2}")
        try expectNil(lines.next())
    }

    func testProcessHomePreservesSpaces() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--hold-process"]
        process.environment = ["HOME": NSHomeDirectory(), "CODEX_HOME": "/tmp/Switchboard Test/Profile B"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        try expectEqual(ProcessHome.read(pid: process.processIdentifier), normalizedHome("/tmp/Switchboard Test/Profile B"))
    }

    func testRPCReadsReplyAlreadyBufferedBehindNotification() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let script = temp.appendingPathComponent("fake-server")
        let source = """
        #!/usr/bin/python3
        import json,sys,time
        for line in sys.stdin:
            q=json.loads(line)
            if 'id' not in q: continue
            if q['method']=='timeout': time.sleep(10); continue
            sys.stdout.write(json.dumps({'method':'account/updated','params':{}})+'\\n')
            sys.stdout.write(json.dumps({'id':q['id'],'result':{'ok':True}})+'\\n')
            sys.stdout.flush()
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let rpc = try RPCConnection(executable: script, home: temp.path)
        defer { rpc.close() }
        try expectEqual(try rpc.request("test")["ok"] as? Bool, true)
        let started = Date()
        try expectThrows(try rpc.request("timeout", timeout: 0.2))
        try expectLess(Date().timeIntervalSince(started), 2)
    }

    func testLogoutChecksGuardBeforeSendingCommand() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let script = temp.appendingPathComponent("fake-server")
        let source = """
        #!/usr/bin/python3
        import json,sys,os
        for line in sys.stdin:
            q=json.loads(line)
            if 'id' not in q: continue
            with open(os.path.join(os.environ['CODEX_HOME'],'calls'),'a') as f: f.write(q['method']+'\\n')
            result={'account':{'type':'chatgpt','email':'other@example.com','planType':'plus'}} if q['method']=='account/read' else {}
            print(json.dumps({'id':q['id'],'result':result}),flush=True)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let service = CodexService(executable: script)
        var rejected = false
        do {
            try await service.logout(SavedAccount(home: temp.path, email: "other@example.com"), stillNonCurrent: { false })
        } catch { rejected = true }
        try expectTrue(rejected)
        let calls = try String(contentsOf: temp.appendingPathComponent("calls"), encoding: .utf8)
        try expectTrue(calls.contains("account/read"))
        try expectFalse(calls.contains("account/logout"))
    }
}

private struct CheckFailure: Error { let message: String }
private func expectEqual<T: Equatable>(_ a: T, _ b: T) throws {
    if a != b { throw CheckFailure(message: "Values differ") }
}
private func expectNil<T>(_ value: T?) throws {
    if value != nil { throw CheckFailure(message: "Expected nil") }
}
private func expectTrue(_ value: Bool) throws {
    if !value { throw CheckFailure(message: "Expected true") }
}
private func expectFalse(_ value: Bool) throws { try expectTrue(!value) }
private func expectLess(_ a: Double, _ b: Double) throws { try expectTrue(a < b) }
private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckFailure(message: "Missing value") }; return value
}
private func expectThrows<T>(_ expression: @autoclosure () throws -> T) throws {
    do { _ = try expression() } catch { return }
    throw CheckFailure(message: "Expected an error")
}

@main
struct CheckRunner {
    static func main() async {
        if CommandLine.arguments.contains("--hold-process") { try? await Task.sleep(nanoseconds: 5_000_000_000); return }
        if let index = CommandLine.arguments.firstIndex(of: "--chat-fixture"), CommandLine.arguments.count == index + 4 {
            do {
                let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                guard root.lastPathComponent.hasPrefix("switchboard-chat-check-"),
                      FileManager.default.fileExists(atPath: root.appendingPathComponent("synthetic-only").path) else { throw ChatSharingFailure.storage }
                let accounts = ["a", "b", "c"].map { SavedAccount(home: root.appendingPathComponent($0).path, email: $0 + "@example.test") }
                let target = accounts.first { URL(fileURLWithPath: $0.home).lastPathComponent == CommandLine.arguments[index + 3] }!
                let service = SharedSetupService(executable: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"), directory: root.appendingPathComponent("shared"))
                let plan = try await service.prepare(accounts: accounts, currentHome: root.appendingPathComponent(CommandLine.arguments[index + 2]).path)
                guard plan.conflicts.isEmpty else { throw ChatSharingFailure.conflict }
                try await service.apply(plan, choices: [:], target: target)
                print("PASS: Shared project chats applied to synthetic target")
                exit(0)
            } catch { print("FAIL: Synthetic sharing: \(String(describing: error))"); exit(1) }
        }
        let tests = CoreChecks()
        let checks: [(String, () throws -> Void)] = [
            ("Reset credit expiries and partial details", tests.testResetCreditExpiriesAndPartialDetails),
            ("All usage windows", tests.testEveryBucketAndWindowIsKept),
            ("Missing credits", tests.testUnavailableCreditCountIsNotZero),
            ("Legacy usage and zero credits", tests.testLegacyFallbackAndZeroCredits),
            ("Current-account removal protection", tests.testCurrentAccountCannotBeRemovedEvenThroughAnotherProfile),
            ("Last non-current account removal", tests.testLastNonCurrentAccountCanBeRemoved),
            ("Empty and corrupt registry", tests.testEmptyRegistryStaysEmptyAndCorruptionIsNotOverwritten),
            ("Duplicate email protection", tests.testDuplicateEmailIsRejected),
            ("Fragmented JSON protocol", tests.testLineBufferPreservesPartialAndCoalescedMessages),
            ("Process home with spaces", tests.testProcessHomePreservesSpaces),
            ("Buffered notifications and timeout", tests.testRPCReadsReplyAlreadyBufferedBehindNotification),
            ("Shared setup conflicts, deletions and new accounts", SharedSetupChecks.merging)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try check(); print("PASS: " + name) }
            catch { failures += 1; print("FAIL: " + name + " (" + String(describing: error) + ")") }
        }
        do { try await tests.testLogoutChecksGuardBeforeSendingCommand(); print("PASS: Logout guard precedes command") }
        catch { failures += 1; print("FAIL: Logout guard precedes command") }
        print("\(checks.count + 1 - failures)/\(checks.count + 1) checks passed")
        if let index = CommandLine.arguments.firstIndex(of: "--integration-cli"), CommandLine.arguments.count > index + 1 {
            do {
                try await SharedSetupChecks.integration(executable: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                print("PASS: Installed CLI shares setup and preserves chats after project removal")
            } catch { failures += 1; print("FAIL: Shared setup integration (\(error.localizedDescription))") }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
