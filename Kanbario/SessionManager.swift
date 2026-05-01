import Foundation

/// Factory that builds a `TerminalSurface` configured to run an agent CLI
/// inside a worktree, with the env / PATH needed for GUI-launched Xcode builds
/// to still see Homebrew-installed `claude` / `codex` + node.
///
/// Milestone D refactor: libghostty now owns the PTY (see
/// `GhosttyTerminalView.swift`), so this file no longer spawns via
/// openpty + Foundation.Process. What's left is the "what command, where,
/// with what env" decision — everything else is libghostty's job.
enum ClaudeSessionFactory {

    enum Error: Swift.Error, CustomStringConvertible {
        case executableNotFound(AgentKind)

        var description: String {
            switch self {
            case .executableNotFound(let agent):
                return "\(agent.executableName) binary not found in PATH. Install \(agent.displayName) CLI or set PATH."
            }
        }
    }

    /// Build a `TerminalSurface` for the given task inside `worktreeURL`.
    /// The surface is not yet attached to a view — the SwiftUI wrapper will
    /// `attachToView` when the NSView materializes.
    ///
    /// `resume: true` で起動すると `claude --continue` を実行し、この worktree
    /// 内の最新会話を読み直す (task.body は使われない、既に会話履歴に入っている)。
    /// review ステージで「セッションが切れたタスクを開いた瞬間に会話を復帰」
    /// する用途。
    static func makeSurface(
        task: TaskCard,
        worktreeURL: URL,
        claudeExecutable: URL? = nil,
        resume: Bool = false,
        autoMode: Bool = false
    ) throws -> TerminalSurface {
        let agent = task.agentKind
        let executable = try resolveExecutable(
            for: agent,
            explicitClaudeExecutable: claudeExecutable
        )

        // Inherit launchd env, then augment what the agent / hook scripts need.
        var env = ProcessInfo.processInfo.environment
        env["KANBARIO_SURFACE_ID"] = task.id.uuidString
        env["KANBARIO_TASK_ID"] = task.id.uuidString
        env["KANBARIO_AGENT"] = agent.rawValue
        if agent == .claude {
            env["KANBARIO_SOCKET_PATH"] = AppState.defaultHookSocketPath()
            // shim が --settings JSON を組み立てる際、hook command として
            // この絶対パスを埋め込む。Bundle 外で動かすときは "kanbario" を
            // PATH 解決させるため未設定のまま (shim 側でフォールバック)。
            if let cli = Bundle.main.url(
                forResource: "kanbario", withExtension: nil, subdirectory: "bin"
            ) {
                env["KANBARIO_HOOK_CLI_PATH"] = cli.path
            }
        }
        // TERM は **常に xterm-ghostty を強制**する。
        // 理由: Xcode から debug run すると親 kanbario process に TERM=dumb が
        // 仕込まれ (Xcode 自身が terminal を持たないため)、それをそのまま子に
        // 継承すると lazygit が `terminal not cursor addressable` で落ちる。
        // kanbario の surface は libghostty が描画する別 terminal なので、
        // 親の TERM を継承する意味はなく、常に bundle 同梱の xterm-ghostty
        // を使わせるのが正しい。
        env["TERM"] = "xterm-ghostty"
        // TERMINFO_DIRS: app bundle 内の terminfo を最優先で検索させる。
        // system `/usr/share/terminfo` と user `~/.terminfo` も fallback に
        // 並べる (ssh 経由で別 terminfo ディレクトリを明示したい場合に備えて)。
        env["TERMINFO_DIRS"] = bundledTerminfoSearchPath(fallback: env["TERMINFO_DIRS"])
        // GUI-launched apps inherit launchd's thin PATH; prepend the user-local
        // bin locations so Claude Code's node-backed hooks / MCP clients work.
        env["PATH"] = augmentedPATH(current: env["PATH"])
        // LANG / LC_CTYPE: launchd-launched macOS apps don't inherit these,
        // which drops the child to the C locale and mangles UTF-8 input
        // (Japanese typed through IME arrives as Latin-1 bytes, claude /
        // node see them as mojibake). Default to en_US.UTF-8 only if the
        // user hasn't already configured something — respecting their
        // explicit choice is important for non-en users.
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["LC_CTYPE"] == nil { env["LC_CTYPE"] = "UTF-8" }

        // Pass task.body via argv, not libghostty's initial_input:
        // - initial_input round-trips through std.zig.stringEscape inside
        //   libghostty, which mangles non-ASCII UTF-8 bytes (user observed
        //   mojibake on Japanese prompts).
        // - initial_input also changes UX: it behaves like the user typed the
        //   prompt and is waiting to press Enter, not like `agent "body"`
        //   which executes immediately.
        //
        // ユーザの .zprofile / .zshenv で定義された PATH や環境変数
        // (mise / asdf / direnv / API key など) を agent から見えるように
        // するため、**login shell** (-l) 経由で起動する。
        //
        //   sh -c → $SHELL -l -c 'exec <claude ...>'
        //
        // - -l: login shell → .zprofile / .zshenv / /etc/zprofile を読ませる
        // - -i は **意図的に外している**: interactive shell は PS1 を描画し、
        //   job control を enable し、readline モードに TTY を持っていくので
        //   直後の exec claude と競合して「入力できない」「ターミナルが止まる」
        //   などの不安定を引き起こす (cmux も surface command では interactive
        //   shell を直接起動しない)。.zshrc が読めない分は、ClaudeSessionFactory
        //   の augmentedPATH が mise/asdf 等の shim パスを補填している。
        // - exec: agent で shell を置換して PID を 1 段減らし、Stop ボタンの
        //   SIGHUP 伝播経路を変えない
        let agentInvocation = invocation(
            for: agent,
            executable: executable,
            prompt: task.body,
            workingDirectory: worktreeURL.path,
            resume: resume,
            autoMode: autoMode
        )
        let userShell = env["SHELL"] ?? "/bin/zsh"
        let commandLine = "\(shellQuote(userShell)) -l -c \(shellQuote("exec " + agentInvocation))"

        return TerminalSurface(
            id: task.id,
            command: commandLine,
            workingDirectory: worktreeURL.path,
            initialInput: nil,
            environment: env
        )
    }

    private static func resolveExecutable(
        for agent: AgentKind,
        explicitClaudeExecutable: URL?
    ) throws -> URL {
        switch agent {
        case .claude:
            // Bundle 同梱の shim (Resources/bin/claude) を最優先で起動する。
            // shim が --settings で hook を注入し、内部で real claude を exec
            // する設計 (cmux 流。spec.md §6.1)。
            // explicitClaudeExecutable 引数は test/CLI 上書き、locateExecutable は
            // Bundle なしで起動された場合 (xcodebuild test 等) のフォールバック。
            if let explicit = explicitClaudeExecutable {
                return explicit
            }
            if let shim = Bundle.main.url(
                forResource: "claude", withExtension: nil, subdirectory: "bin"
            ), FileManager.default.isExecutableFile(atPath: shim.path) {
                return shim
            }
            if let found = locateExecutable(agent.executableName) {
                return found
            }
            throw Error.executableNotFound(agent)

        case .codex:
            if let found = locateExecutable(agent.executableName) {
                return found
            }
            throw Error.executableNotFound(agent)
        }
    }

    private static func invocation(
        for agent: AgentKind,
        executable: URL,
        prompt: String,
        workingDirectory: String,
        resume: Bool,
        autoMode: Bool
    ) -> String {
        switch agent {
        case .claude:
            // autoMode = true の場合、claude に `--permission-mode bypassPermissions`
            // を付けて tool 承認プロンプトを全スキップする。kanbario 内で動かす
            // 前提の運用想定で、承認ダイアログで止まる UX を避ける。
            let permissionFlag = autoMode ? " --permission-mode bypassPermissions" : ""
            if resume {
                // --continue はこの cwd (= worktree) の最新会話を読み直す。
                // kanbario は task 1 つに worktree 1 つなので session-id を
                // 引数で指定する必要はない (--resume <id> ではなく --continue)。
                return "\(shellQuote(executable.path))\(permissionFlag) --continue"
            }
            if prompt.isEmpty {
                return "\(shellQuote(executable.path))\(permissionFlag)"
            }
            return "\(shellQuote(executable.path))\(permissionFlag) \(shellQuote(prompt))"

        case .codex:
            // Codex CLI は `codex [PROMPT]` が interactive TUI、`codex resume
            // --last` が直近セッション復元。Claude の hook 互換は無いので、
            // Kanbario 側の live activity は process close でのみ確定する。
            // autoMode では承認プロンプトだけを飛ばし、sandbox は worktree 書き込み
            // に留める。権限が足りない操作は Codex 側で失敗として扱わせる。
            let bypassFlag = autoMode ? " --ask-for-approval never --sandbox workspace-write" : ""
            let cdFlag = " --cd \(shellQuote(workingDirectory))"
            if resume {
                return "\(shellQuote(executable.path))\(bypassFlag)\(cdFlag) resume --last"
            }
            if prompt.isEmpty {
                return "\(shellQuote(executable.path))\(bypassFlag)\(cdFlag)"
            }
            return "\(shellQuote(executable.path))\(bypassFlag)\(cdFlag) \(shellQuote(prompt))"
        }
    }

    /// Single-quote shell escaping. Any `'` in the input is rewritten as
    /// `'\''` (close single-quote, escaped single-quote, reopen). Robust for
    /// everything except control characters, which neither claude nor our
    /// task body should carry.
    static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - PATH / executable helpers (unchanged from pre-Milestone-D)

    /// Augment the child process PATH with typical user-local dev toolchain
    /// locations so claude / its node hooks / MCP clients resolve. Covers:
    ///   - Direct installs: ~/.local/bin, /opt/homebrew, /usr/local
    ///   - Per-user toolchain managers: volta, cargo, bun, deno
    ///   - node version managers: asdf shims, mise shims, fnm default, nvm
    ///     (nvm's current version is dynamically selected so we best-effort
    ///     glob the newest `versions/node/v*/bin` at lookup time)
    static func augmentedPATH(current: String?) -> String {
        let home = NSHomeDirectory()
        let fm = FileManager.default

        var additions: [String] = [
            "\(home)/.local/bin",
            "\(home)/.volta/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
            // node version managers
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/.fnm/aliases/default/bin",
            "\(home)/.nodebrew/current/bin",
            "\(home)/.nodenv/shims",
            // Homebrew
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ]

        // nvm: pick the most recently modified `versions/node/v*/bin`.
        // We can't read the user's `default` alias file reliably, but the
        // newest install is a reasonable default for "just make it work".
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            let sorted = versions
                .map { "\(nvmRoot)/\($0)" }
                .sorted(by: {
                    let lhs = (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast
                    let rhs = (try? fm.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast
                    return lhs > rhs
                })
            if let newest = sorted.first {
                additions.insert("\(newest)/bin", at: 0)
            }
        }

        let existing = (current ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        var ordered: [String] = []
        for p in additions + existing where !p.isEmpty {
            if seen.insert(p).inserted { ordered.append(p) }
        }
        return ordered.joined(separator: ":")
    }

    /// 子プロセス用の `TERMINFO_DIRS` を構築する。
    /// 優先順: app bundle 同梱の terminfo → user `~/.terminfo` →
    /// system `/usr/share/terminfo` → 呼び出し側が既に持っていた fallback。
    /// 先頭に来たパスが最優先なので、bundle 同梱の xterm-ghostty が
    /// 確実に引かれる。
    static func bundledTerminfoSearchPath(fallback: String?) -> String {
        var paths: [String] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("terminfo").path,
           FileManager.default.fileExists(atPath: bundled) {
            paths.append(bundled)
        }
        let home = NSHomeDirectory()
        let userTerminfo = "\(home)/.terminfo"
        if FileManager.default.fileExists(atPath: userTerminfo) {
            paths.append(userTerminfo)
        }
        paths.append("/usr/share/terminfo")
        if let fallback, !fallback.isEmpty {
            for segment in fallback.split(separator: ":").map(String.init)
            where !paths.contains(segment) {
                paths.append(segment)
            }
        }
        return paths.joined(separator: ":")
    }

    /// Look up an executable name from PATH + Homebrew fallbacks.
    static func locateExecutable(_ name: String) -> URL? {
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let fallbacks = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Users/\(NSUserName())/.local/bin",
        ]
        var seen = Set<String>()
        for dir in envPaths + fallbacks where seen.insert(dir).inserted {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - ShellTabFactory

/// expanded モード中に ⌘T で開く「普通のシェル」用の TerminalSurface を組み立てる。
/// claude と違い task / worktree / hook には紐付かない — ユーザー作業専用スクラッチ。
///
/// - KANBARIO_SURFACE_ID / KANBARIO_HOOK_CLI_PATH は **敢えて設定しない**。
///   shim の hook 注入が走ると kanbario CLI に意味不明 event が飛んできて
///   Kanban のカラム遷移を誤爆させる可能性がある。
/// - PATH / LANG / LC_CTYPE は claude 側と同じく augment する (user の
///   .zshrc が読めるようにするが、PATH fallback が無いと .zshrc 自体に
///   辿り着けないケースもあるため)。
enum ShellTabFactory {
    static func makeSurface(
        id: UUID,
        workingDirectory: String?
    ) -> TerminalSurface {
        var env = ProcessInfo.processInfo.environment
        // TERM は常に強制 (理由は ClaudeSessionFactory 参照、TERM=dumb 継承回避)。
        env["TERM"] = "xterm-ghostty"
        env["TERMINFO_DIRS"] = ClaudeSessionFactory.bundledTerminfoSearchPath(
            fallback: env["TERMINFO_DIRS"]
        )
        env["PATH"] = ClaudeSessionFactory.augmentedPATH(current: env["PATH"])
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["LC_CTYPE"] == nil { env["LC_CTYPE"] = "UTF-8" }

        // login + interactive で .zprofile / .zshrc を読ませる。claude と
        // 違って続くコマンドは無いので `-c` ではなく shell を素のまま走らせる。
        let userShell = env["SHELL"] ?? "/bin/zsh"
        let commandLine = "\(ClaudeSessionFactory.shellQuote(userShell)) -l -i"

        return TerminalSurface(
            id: id,
            command: commandLine,
            workingDirectory: workingDirectory,
            initialInput: nil,
            environment: env
        )
    }
}
