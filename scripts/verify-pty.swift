#!/usr/bin/env swift
// PTY wrapper の動作検証スクリプト
// Xcode プロジェクトに取り込む前に、@_silgen_name での openpty 呼び出しが
// 動くかを確認するための単独スクリプト。
//
// 実行: swift scripts/verify-pty.swift

import Foundation
import Darwin

@_silgen_name("openpty")
private func c_openpty(_ amaster: UnsafeMutablePointer<Int32>,
                       _ aslave: UnsafeMutablePointer<Int32>,
                       _ name: UnsafeMutablePointer<CChar>?,
                       _ termp: UnsafePointer<termios>?,
                       _ winp: UnsafePointer<winsize>?) -> Int32

func main() {
    var master: Int32 = -1
    var slave: Int32 = -1
    var ws = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)

    let result = withUnsafePointer(to: &ws) { wsPtr in
        c_openpty(&master, &slave, nil, nil, wsPtr)
    }

    guard result == 0 else {
        let e = errno
        let msg = String(cString: strerror(e))
        print("[FAIL] openpty failed: errno=\(e) (\(msg))")
        exit(1)
    }
    print("[OK] openpty: master=\(master) slave=\(slave)")

    // echo "hello" を PTY 経由で実行して出力を読む
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/echo")
    process.arguments = ["hello from pty"]

    let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    process.standardInput = slaveHandle
    process.standardOutput = slaveHandle
    process.standardError = slaveHandle

    do {
        try process.run()
    } catch {
        print("[FAIL] process.run: \(error)")
        close(master); close(slave)
        exit(1)
    }

    close(slave)  // 親側の slave を閉じる (子のみが保持)

    let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)

    // PTY 出力を非同期で読む (子が終わると EOF)
    DispatchQueue.global().async {
        while true {
            let data = masterHandle.availableData
            if data.isEmpty { break }
            if let text = String(data: data, encoding: .utf8) {
                print("[read] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    process.waitUntilExit()
    print("[OK] exit code: \(process.terminationStatus)")
    Thread.sleep(forTimeInterval: 0.1) // 最後のバイト読み切り

    print("[OK] PTY wrapper verified")
    exit(0)
}

main()
