import SwiftUI
import Foundation

struct ContentView: View {
    @State private var output: String = "Push 'Run Demo' to test worktree + bash spawn"
    @State private var isRunning = false

    // 3 コンポーネントのインスタンスを ContentView が保持する (MVP 向けの簡易構成、
    // 将来は AppState / @Observable に切り出す)
    @State private var sessionManager = SessionManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Run Demo") {
                    Task { await runDemo() }
                }
                .disabled(isRunning)
                if isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            ScrollView {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color(.textBackgroundColor))
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }

    /// ボタン押下時に走るデモフロー。
    /// 1. temp git repo 作成 → 2. worktree 作成 → 3. bash 起動 →
    /// 4. PTY 出力を UI に流す → 5. exit 取得 → 6. 後片付け。
    private func runDemo() async {
        isRunning = true
        defer { isRunning = false }
        output = "=== Demo start ===\n"

        // 1) 一時 git repo のパスを決める。
        //    FileManager.default.temporaryDirectory は書き込み可能な一時領域 (/var/folders/.../T/)。
        //    appendingPathComponent はパス文字列を組み立てるだけで、実体は作らない。
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanbario-demo-\(UUID().uuidString.prefix(8))")
        let branch = "kanbario/demo-\(UUID().uuidString.prefix(6))"

        do {
            // 2) ディレクトリを実際に作る。throws なので try。
            try FileManager.default.createDirectory(
                at: repoURL, withIntermediateDirectories: true
            )
            output += "Created repo dir: \(repoURL.path)\n"

            // 3) git init + config + 空コミット 1 個。
            //    worktrunk は「main に少なくとも 1 コミット」を前提にするので必須。
            for args in [
                ["init", "-q", "-b", "main"],
                ["config", "user.email", "demo@kanbario.test"],
                ["config", "user.name", "Kanbario Demo"],
                ["commit", "--allow-empty", "-q", "-m", "initial"],
            ] {
                try await runGit(args, at: repoURL)
            }
            output += "git init + initial commit done.\n"

            // 4) WorktreeService 経由で `wt switch -c` → worktree 作成。
            let worktreeService = try WorktreeService(repoURL: repoURL)
            let worktreeURL = try await worktreeService.create(branch: branch)
            output += "Created worktree: \(worktreeURL.path)\n"

            // 5) SessionManager で PTY つきで bash を起動。
            //    `-c "echo ... && pwd"` を実行後 exit。
            let session = try await sessionManager.start(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", "echo hello from kanbario && pwd"],
                cwd: worktreeURL
            )
            output += "--- bash output ---\n"

            // 6) PTY 出力を UI に流す。for await は bytes ストリームが finish() されるまで
            //    待ち続け、EOF で自動的に抜ける。
            for await chunk in session.bytes {
                if let text = String(data: chunk, encoding: .utf8) {
                    output += text
                }
            }

            // 7) 終了コードを受け取る (termination は 1 値流して close)。
            for await exit in session.termination {
                output += "--- bash exit: \(exit) ---\n"
            }

            // 8) 後片付け: worktree 削除 → temp repo 削除 → wt の兄弟ディレクトリも掃除。
            try await worktreeService.remove(branch: branch, force: true)
            try? FileManager.default.removeItem(at: repoURL)
            let parent = repoURL.deletingLastPathComponent()
            let base = repoURL.lastPathComponent
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil
            ) {
                for e in entries where e.lastPathComponent.hasPrefix(base) {
                    try? FileManager.default.removeItem(at: e)
                }
            }
            output += "Cleaned up.\n=== Demo end ===\n"
        } catch {
            output += "\nERROR: \(error)\n"
        }
    }

    /// git コマンドを async に包む。`waitUntilExit()` は同期ブロッキングで main thread を固まらせるので
    /// `terminationHandler` + `CheckedContinuation` パターンで await 化する。
    private func runGit(_ args: [String], at url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = url
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: NSError(
                        domain: "runGit", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey:
                            "git \(args.joined(separator: " ")) failed"]))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

#Preview {
    ContentView()
}
