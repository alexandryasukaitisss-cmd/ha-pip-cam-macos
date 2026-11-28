import Foundation
import Testing
@testable import HAPiPCam

/// Exercises the real swap script: success replaces the bundle, both failure branches restore it.
@Suite("Updater swap script")
struct UpdaterSwapScriptTests {
    private func sandbox() throws -> (root: URL, script: URL, newApp: URL, target: URL, backup: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swap-test-\(UUID().uuidString)", isDirectory: true)
        let newApp = root.appendingPathComponent("new/App.app", isDirectory: true)
        let target = root.appendingPathComponent("install/App.app", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        for dir in [newApp, target, staging] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "new".write(to: newApp.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        try "old".write(to: target.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        return (root, staging.appendingPathComponent("apply_update.sh"), newApp, target, URL(fileURLWithPath: target.path + ".previous-999999"))
    }

    private func stub(_ root: URL, named name: String, exitCode: Int) throws -> String {
        let url = root.appendingPathComponent(name)
        try "#!/bin/sh\nexit \(exitCode)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    private func run(script: URL, env: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func marker(_ app: URL) -> String {
        (try? String(contentsOf: app.appendingPathComponent("marker.txt"), encoding: .utf8)) ?? ""
    }

    private func script(_ s: (root: URL, script: URL, newApp: URL, target: URL, backup: URL)) -> String {
        GitHubCommitUpdater.applyUpdateScript(oldPID: 999999, newApp: s.newApp.path, targetApp: s.target.path, backupApp: s.backup.path, stagingDir: s.script.deletingLastPathComponent().path)
    }

    @Test func replacesTheBundleAndDropsTheBackup() throws {
        let s = try sandbox()
        let open = try stub(s.root, named: "open-ok.sh", exitCode: 0)
        try script(s).write(to: s.script, atomically: true, encoding: .utf8)
        let status = try run(script: s.script, env: ["UPDATE_OPEN_BIN": open])
        #expect(status == 0)
        #expect(marker(s.target) == "new")
        #expect(!FileManager.default.fileExists(atPath: s.backup.path))
    }

    @Test func restoresTheBackupWhenCopyFails() throws {
        let s = try sandbox()
        let open = try stub(s.root, named: "open-ok.sh", exitCode: 0)
        try script(s).write(to: s.script, atomically: true, encoding: .utf8)
        let status = try run(script: s.script, env: ["UPDATE_DITTO_BIN": "/usr/bin/false", "UPDATE_OPEN_BIN": open])
        #expect(status != 0)
        #expect(marker(s.target) == "old")
    }

    @Test func restoresTheBackupWhenRelaunchFails() throws {
        let s = try sandbox()
        let open = try stub(s.root, named: "open-fail.sh", exitCode: 1)
        try script(s).write(to: s.script, atomically: true, encoding: .utf8)
        let status = try run(script: s.script, env: ["UPDATE_OPEN_BIN": open])
        #expect(status != 0)
        #expect(marker(s.target) == "old")
    }
}
