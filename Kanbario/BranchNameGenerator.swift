import Foundation

/// タスク title / body からローカルの `claude` CLI を呼び出して英数字の短い
/// branch slug を生成するユーティリティ。
///
/// **設計方針 (API 直叩きからの切替):**
/// - 以前は Anthropic API を直接 POST していたが、ANTHROPIC_API_KEY 設定が
///   必要で Pro/Max プランのユーザーは重複支払いになる問題があった。
/// - 現在は `claude -p <prompt>` を subprocess で実行して stdout を受ける。
///   ユーザーが既に `claude` CLI にログインしていれば追加設定ゼロで動く。
/// - shim (Resources/bin/claude) は **使わない**: KANBARIO_SURFACE_ID 環境
///   変数の有無で hook を注入するため、branch 生成目的には不適。PATH 解決で
///   実体の claude を直接起動し、kanbario 関連 env も明示的に除去する。
///
/// **呼び出しは fire-and-forget ではない:** NewTaskSheet の ✨ AI ボタンから
/// 同期的に await されるので、結果を caller が取得して UI に反映する構造。
enum BranchNameGenerator {

    enum GenerationError: Error, CustomStringConvertible {
        case claudeNotFound
        case processFailed(exitCode: Int32, stderr: String)
        case emptyResponse
        case sanitizeYieldedEmpty(raw: String)

        var description: String {
            switch self {
            case .claudeNotFound:
                return "claude CLI が見つかりません (PATH に無い)。brew install claude-code 等で導入してください。"
            case .processFailed(let code, let stderr):
                let snippet = stderr.count > 200 ? String(stderr.prefix(200)) + "…" : stderr
                return "claude exit \(code): \(snippet)"
            case .emptyResponse:
                return "claude が空応答を返しました"
            case .sanitizeYieldedEmpty(let raw):
                let snippet = raw.count > 80 ? String(raw.prefix(80)) + "…" : raw
                return "生成結果が sanitize 後に空になりました (raw: \(snippet))"
            }
        }
    }

    /// branch slug を生成する。成功時は ASCII kebab-case string を返す。
    /// 失敗時は GenerationError を throw (caller が UI に表示する前提)。
    static func generate(title: String, body: String) async throws -> String {
        guard let executable = ClaudeSessionFactory.locateExecutable("claude") else {
            throw GenerationError.claudeNotFound
        }

        let prompt = buildPrompt(title: title, body: body)
        let raw = try await runClaude(executable: executable, prompt: prompt)
        let slug = sanitize(raw)
        if slug.isEmpty {
            // 空の場合は sanitize 前の生テキストも含めてエラー化 (デバッグしやすく)。
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw GenerationError.emptyResponse
            }
            throw GenerationError.sanitizeYieldedEmpty(raw: raw)
        }
        return slug
    }

    // MARK: - Prompt

    /// claude -p に渡すプロンプト。system と user を区別する機能は -p には無い
    /// ので、単一テキストにルール + 例 + 入力をまとめて詰める。
    /// 返答はスラッグ本体のみ 1 行で返させる (extra なレスポンスを削る)。
    private static func buildPrompt(title: String, body: String) -> String {
        """
        Generate ONE short git branch slug for the task below.

        Rules (hard constraints):
        - Output ONLY the slug. No prefix, no quotes, no commentary, no code fences.
        - 2 to 5 words, lowercase, hyphen-separated (kebab-case).
        - Start with a technical verb when natural: add, fix, refactor, remove, update, support, improve.
        - ASCII only. Non-English input (e.g. Japanese) must be translated to English INTENT.
        - Maximum 40 characters.

        Examples:
        - "認証フローの統合テスト追加" -> add-auth-integration-tests
        - "ログインバグを直す" -> fix-login-bug
        - "Refactor session manager" -> refactor-session-manager

        Task:
        Title: \(title)
        Body: \(body.isEmpty ? "(empty)" : body)
        """
    }

    // MARK: - Subprocess

    /// `claude -p <prompt>` を起動して stdout を返す。
    /// - 環境変数から KANBARIO_* を除去 (shim の hook 注入経路を完全に迂回)
    /// - PATH は ClaudeSessionFactory.augmentedPATH で GUI launch 環境でも
    ///   Homebrew / node 系の実体が見える形に補強
    /// - stderr は failure 時のデバッグ用に捕捉
    private static func runClaude(executable: URL, prompt: String) async throws -> String {
        let process = Process()
        process.executableURL = executable
        // 単発 print mode。--print の短縮形。タスク 1 つ作って exit。
        process.arguments = ["-p", prompt]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeSessionFactory.augmentedPATH(current: env["PATH"])
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["LC_CTYPE"] == nil { env["LC_CTYPE"] = "UTF-8" }
        // branch 生成に hook 注入や socket 通信は不要。shim がこれらを読んで
        // 誤動作するのを避けるため、明示的に除去する。
        env.removeValue(forKey: "KANBARIO_SURFACE_ID")
        env.removeValue(forKey: "KANBARIO_TASK_ID")
        env.removeValue(forKey: "KANBARIO_SOCKET_PATH")
        env.removeValue(forKey: "KANBARIO_HOOK_CLI_PATH")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw GenerationError.processFailed(exitCode: -1, stderr: "\(error)")
        }

        // Foundation.Process の waitUntilExit は同期。continuation で
        // async に wrap する (別 thread に blocking wait を逃す)。
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw GenerationError.processFailed(
                exitCode: process.terminationStatus,
                stderr: stderr
            )
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    // MARK: - Sanitization

    /// claude 出力を git branch 名に適した形に整形する。
    /// - lowercase 化
    /// - 英数字 + ハイフン以外は全て `-` に
    /// - 連続ハイフン畳み込み
    /// - 先頭末尾 `-` 除去
    /// - 40 文字打ち切り
    ///
    /// claude が prompt を守って単独 slug を返せば 1 行 slug そのまま。
    /// 守らずに前置きを付けても「最後の slug 相当の部分」が残る確率が高い
    /// (記号スペース → hyphen 化 → 長すぎたら先頭 40 文字で切られる)。
    static func sanitize(_ raw: String) -> String {
        // 複数行返された場合は最初の非空行を採用。
        let firstLine = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String($0) }
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? raw

        let lowered = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var mapped = ""
        mapped.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            let v = scalar.value
            let isLower = (0x61...0x7A).contains(v)
            let isDigit = (0x30...0x39).contains(v)
            let isDash = v == 0x2D
            if isLower || isDigit || isDash {
                mapped.unicodeScalars.append(scalar)
            } else {
                mapped.append("-")
            }
        }
        while mapped.contains("--") {
            mapped = mapped.replacingOccurrences(of: "--", with: "-")
        }
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var capped = String(trimmed.prefix(40))
        capped = capped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return capped
    }
}
