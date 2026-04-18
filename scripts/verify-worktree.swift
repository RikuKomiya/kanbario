#!/usr/bin/env swift
// WorktreeService の動作検証スクリプト。
// Xcode テストと違い sandbox 外なので、実際のエラーが見える。
//
// 実行: swift scripts/verify-worktree.swift

import Foundation

func runCommand(_ executable: String, _ args: [String], at url: URL? = nil) throws -> (exit: Int32, stdout: String, stderr: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    if let url { p.currentDirectoryURL = url }
    let out = Pipe(); let err = Pipe()
    p.standardOutput = out
    p.standardError  = err
    try p.run()
    p.waitUntilExit()
    let oData = out.fileHandleForReading.readDataToEndOfFile()
    let eData = err.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus,
            String(data: oData, encoding: .utf8) ?? "",
            String(data: eData, encoding: .utf8) ?? "")
}

func locateWT() -> URL? {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for dir in paths + ["/opt/homebrew/bin", "/usr/local/bin"] {
        let c = URL(fileURLWithPath: dir).appendingPathComponent("wt")
        if FileManager.default.isExecutableFile(atPath: c.path) { return c }
    }
    return nil
}

// 1. Temp repo 作成
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("kanbario-verify-\(UUID().uuidString.prefix(8))")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
print("[1] temp repo: \(tmp.path)")

let git = "/usr/bin/git"
defer {
    print("[cleanup] removing \(tmp.path) and siblings")
    let parent = tmp.deletingLastPathComponent()
    if let entries = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
        for e in entries where e.lastPathComponent.hasPrefix(tmp.lastPathComponent) {
            try? FileManager.default.removeItem(at: e)
        }
    }
}

for args in [["init", "-q", "-b", "main"],
             ["config", "user.email", "test@example.com"],
             ["config", "user.name", "Test"],
             ["commit", "--allow-empty", "-q", "-m", "initial"]] {
    let r = try runCommand(git, args, at: tmp)
    print("[git] \(args.joined(separator: " ")): exit=\(r.exit)")
    if r.exit != 0 { print("  stderr: \(r.stderr)"); exit(1) }
}

// 2. wt を探す
guard let wtURL = locateWT() else { print("[FAIL] wt not found"); exit(1) }
print("[2] wt located: \(wtURL.path)")

// 3. wt list を実行
let listRes = try runCommand(wtURL.path, ["list", "--format=json"], at: tmp)
print("[3] wt list: exit=\(listRes.exit)")
print("    stdout: \(listRes.stdout.prefix(500))")
print("    stderr: \(listRes.stderr.prefix(500))")

// 4. wt switch -c
let branch = "kanbario/verify-\(UUID().uuidString.prefix(6))"
let createRes = try runCommand(wtURL.path, ["switch", "-c", branch, "--no-cd"], at: tmp)
print("[4] wt switch -c \(branch): exit=\(createRes.exit)")
print("    stdout: \(createRes.stdout.prefix(500))")
print("    stderr: \(createRes.stderr.prefix(500))")

// 5. wt list 再度
let list2 = try runCommand(wtURL.path, ["list", "--format=json"], at: tmp)
print("[5] wt list (after create): exit=\(list2.exit)")
print("    stdout: \(list2.stdout.prefix(600))")

print("[DONE]")
