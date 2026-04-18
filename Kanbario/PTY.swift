import Foundation
import Darwin

/// Pseudo-terminal (PTY) のユーティリティ。
///
/// `openpty(3)` を Swift から直接呼ぶ薄いラッパー。`<util.h>` は Darwin module に
/// 含まれないため、`@_silgen_name` でリンカシンボルを直接参照している。
enum PTY {
    /// PTY の file descriptor ペア。`master` は親プロセス (kanbario) 側、
    /// `slave` は子プロセス (claude 等) の stdin/stdout/stderr に繋ぐ。
    struct Handles {
        let master: Int32
        let slave: Int32
    }

    enum Error: Swift.Error {
        case openptyFailed(errno: Int32, message: String)
    }

    /// PTY を新規に開く。
    /// - Parameters:
    ///   - cols: 列数 (デフォルト 120)
    ///   - rows: 行数 (デフォルト 40)
    /// - Returns: 親側 master と子側 slave の fd
    /// - Throws: `Error.openptyFailed` on failure
    nonisolated static func openpty(cols: UInt16 = 120, rows: UInt16 = 40) throws -> Handles {
        var master: Int32 = -1
        var slave: Int32 = -1
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        let result = withUnsafePointer(to: &ws) { wsPtr in
            c_openpty(&master, &slave, nil, nil, wsPtr)
        }

        guard result == 0 else {
            let e = errno
            let msg = String(cString: strerror(e))
            throw Error.openptyFailed(errno: e, message: msg)
        }

        return Handles(master: master, slave: slave)
    }
}

@_silgen_name("openpty")
private func c_openpty(_ amaster: UnsafeMutablePointer<Int32>,
                       _ aslave: UnsafeMutablePointer<Int32>,
                       _ name: UnsafeMutablePointer<CChar>?,
                       _ termp: UnsafePointer<termios>?,
                       _ winp: UnsafePointer<winsize>?) -> Int32
