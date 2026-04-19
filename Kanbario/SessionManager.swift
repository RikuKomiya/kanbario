import Foundation

/// Factory that builds a `TerminalSurface` configured to run Claude Code
/// inside a worktree, with the env / PATH needed for GUI-launched Xcode builds
/// to still see Homebrew-installed `claude` + node.
///
/// Milestone D refactor: libghostty now owns the PTY (see
/// `GhosttyTerminalView.swift`), so this file no longer spawns via
/// openpty + Foundation.Process. What's left is the "what command, where,
/// with what env" decision — everything else is libghostty's job.
enum ClaudeSessionFactory {

    enum Error: Swift.Error, CustomStringConvertible {
        case claudeNotFound

        var description: String {
            switch self {
            case .claudeNotFound:
                return "claude binary not found in PATH. `brew install claude` or set explicit path."
            }
        }
    }

    /// Build a `TerminalSurface` for the given task inside `worktreeURL`.
    /// The surface is not yet attached to a view — the SwiftUI wrapper will
    /// `attachToView` when the NSView materializes.
    static func makeSurface(
        task: TaskCard,
        worktreeURL: URL,
        claudeExecutable: URL? = nil
    ) throws -> TerminalSurface {
        let executable: URL
        if let explicit = claudeExecutable {
            executable = explicit
        } else if let found = locateExecutable("claude") {
            executable = found
        } else {
            throw Error.claudeNotFound
        }

        // Inherit launchd env, then augment what claude / hook scripts need.
        var env = ProcessInfo.processInfo.environment
        env["KANBARIO_SURFACE_ID"] = task.id.uuidString
        env["KANBARIO_TASK_ID"] = task.id.uuidString
        env["TERM"] = env["TERM"] ?? "xterm-256color"
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
        //   prompt and is waiting to press Enter, not like `claude "body"`
        //   which executes immediately.
        // Instead: let ghostty's `.shell` command mode hand the string to
        //   /bin/sh -c, with task.body shell-quoted.
        let commandLine: String
        if task.body.isEmpty {
            commandLine = shellQuote(executable.path)
        } else {
            commandLine = "\(shellQuote(executable.path)) \(shellQuote(task.body))"
        }

        return TerminalSurface(
            id: task.id,
            command: commandLine,
            workingDirectory: worktreeURL.path,
            initialInput: nil,
            environment: env
        )
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
