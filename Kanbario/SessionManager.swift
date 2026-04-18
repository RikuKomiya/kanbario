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

        return TerminalSurface(
            id: task.id,
            command: executable.path,
            workingDirectory: worktreeURL.path,
            initialInput: task.body.isEmpty ? nil : task.body,
            environment: env
        )
    }

    // MARK: - PATH / executable helpers (unchanged from pre-Milestone-D)

    /// Augment the child process PATH with typical user-local dev toolchain
    /// locations so claude / its node hooks / MCP clients resolve.
    static func augmentedPATH(current: String?) -> String {
        let home = NSHomeDirectory()
        let additions = [
            "\(home)/.local/bin",
            "\(home)/.volta/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ]
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
