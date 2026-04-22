import Foundation

// MARK: - FileListService

/// prompt editor の `@` autocomplete で使うファイル一覧を取る actor。
/// 毎回 `git ls-files` を叩くのは重いので、repo 単位に結果をキャッシュし、
/// explicit な invalidate か TTL (5 分) 経過で再取得。kanbario は
/// NewTaskSheet を開くたびに load(for:) を呼ぶので、連続で同じ repo を
/// 扱っているうちはキャッシュが効く。
actor FileListService {
    private struct Cache {
        let repoPath: String
        let files: [FileEntry]
        let fetchedAt: Date
    }

    static let shared = FileListService()

    private var cache: Cache?
    private let ttl: TimeInterval = 300  // 5 分

    /// repoPath のファイル一覧を取得。キャッシュが有効ならそれを返す。
    func files(in repoPath: String) async -> [FileEntry] {
        if let cache,
           cache.repoPath == repoPath,
           Date().timeIntervalSince(cache.fetchedAt) < ttl {
            return cache.files
        }
        let loaded = await Self.fetch(repoPath: repoPath)
        cache = Cache(repoPath: repoPath, files: loaded, fetchedAt: Date())
        return loaded
    }

    /// 強制再取得 (ユーザーが手動でリロードした時などに)。
    func invalidate() {
        cache = nil
    }

    private static func fetch(repoPath: String) async -> [FileEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // ls-files で tracked file + untracked-but-not-ignored を拾う。
        // binary も混じるが filtering は fuzzy 側でユーザーが query すれば OK。
        process.arguments = ["-C", repoPath, "ls-files",
                             "--cached", "--others", "--exclude-standard"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { FileEntry(relativePath: $0) }
    }
}

// MARK: - SkillDiscovery

/// `/` autocomplete で使う候補を集める。以下 4 ソースから統合:
///
/// 1. **Built-in commands** (kanbario 側で静的に持つ代表的な Claude Code 組込み)
/// 2. **User scope**: `~/.claude/{commands,skills,agents}/**/*.md`
/// 3. **Project scope**: `<repoPath>/.claude/{commands,skills,agents}/**/*.md`
///
/// 同名の command がユーザー / プロジェクト両方にあった場合、**project 優先**
/// (kanbario の repo に固有の skill が上書きするのが自然)。
/// frontmatter (YAML-like) の description を取れたら detail に。
actor SkillDiscovery {
    static let shared = SkillDiscovery()

    private struct Cache {
        let repoPath: String
        let entries: [SlashEntry]
        let fetchedAt: Date
    }
    private var cache: Cache?
    private let ttl: TimeInterval = 120  // 2 分

    /// 組込み slash command (Claude Code の代表例)。少なめに絞っておき、
    /// 本当に使うものだけ露出する。ユーザーが使う機会の多い代表 4 つ。
    private let builtinCommands: [SlashEntry] = [
        SlashEntry(id: "builtin:init", name: "init", description: "Initialize CLAUDE.md",
                   kind: .command, source: .builtin),
        SlashEntry(id: "builtin:review", name: "review", description: "Review a pull request",
                   kind: .command, source: .builtin),
        SlashEntry(id: "builtin:clear", name: "clear", description: "Clear conversation",
                   kind: .command, source: .builtin),
        SlashEntry(id: "builtin:help", name: "help", description: "Show help",
                   kind: .command, source: .builtin),
    ]

    func entries(for repoPath: String) async -> [SlashEntry] {
        if let cache,
           cache.repoPath == repoPath,
           Date().timeIntervalSince(cache.fetchedAt) < ttl {
            return cache.entries
        }
        let collected = await Self.collect(
            repoPath: repoPath,
            builtin: builtinCommands
        )
        cache = Cache(repoPath: repoPath, entries: collected, fetchedAt: Date())
        return collected
    }

    func invalidate() { cache = nil }

    private static func collect(
        repoPath: String,
        builtin: [SlashEntry]
    ) async -> [SlashEntry] {
        var merged: [String: SlashEntry] = [:]
        // 1. builtin
        for e in builtin { merged[e.name] = e }

        // 2. user scope
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path
        for entry in walkClaudeDir(basePath: home, source: .user) {
            // user は builtin を上書き OK (ユーザー設定が優先)
            merged[entry.name] = entry
        }

        // 3. project scope (最優先)
        let projectClaude = URL(fileURLWithPath: repoPath)
            .appendingPathComponent(".claude").path
        for entry in walkClaudeDir(basePath: projectClaude, source: .project) {
            merged[entry.name] = entry
        }

        // displayName 昇順で並べる (source の優先度は上書きで既に反映済)
        return merged.values.sorted { $0.displayName < $1.displayName }
    }

    /// `<base>/{commands,skills,agents}` を Claude Code の標準フォーマットに
    /// 従って walk し、SlashEntry に変換する。
    ///
    /// **フォーマットの違い (重要):**
    /// - `commands/*.md` と `agents/*.md` は **flat**: ファイル basename が
    ///   そのまま command name。`.md` 拡張子のファイルだけ拾う。
    /// - `skills/<skill-name>/SKILL.md` は **ディレクトリ形式**: 親ディレクトリ名が
    ///   skill name で、必ず大文字の `SKILL.md` が skill 本体。親ディレクトリ
    ///   内の他の `.md` (例: `references/python.md`) は internal reference で、
    ///   skill としては扱わない。
    ///
    /// 旧実装はすべてを flat `*.md` で walk していたため references まで
    /// skill として登録してしまい、また親ディレクトリ名 (= Claude Code 側で
    /// skill を指定する真の名前) ではなく `SKILL` という固定 basename を
    /// name に使ってしまう致命的バグがあった。
    private static func walkClaudeDir(basePath: String, source: SlashEntry.Source) -> [SlashEntry] {
        let fm = FileManager.default
        var results: [SlashEntry] = []

        // commands / agents は flat な *.md
        for (subdir, kind) in [("commands", SlashEntry.Kind.command),
                                ("agents",   SlashEntry.Kind.agent)] {
            let dir = (basePath as NSString).appendingPathComponent(subdir)
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "md" else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                let description = Self.extractDescription(from: url)
                let id = "\(source.rawValue):\(kind.rawValue):\(name)"
                results.append(SlashEntry(
                    id: id,
                    name: name,
                    description: description,
                    kind: kind,
                    source: source
                ))
            }
        }

        // skills は <base>/skills/<name>/SKILL.md 形式
        let skillsDir = (basePath as NSString).appendingPathComponent("skills")
        if let subdirs = try? fm.contentsOfDirectory(atPath: skillsDir) {
            for subdir in subdirs {
                let skillDir = (skillsDir as NSString).appendingPathComponent(subdir)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: skillDir, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                let skillMdPath = (skillDir as NSString).appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: skillMdPath) else { continue }
                let description = Self.extractDescription(from: URL(fileURLWithPath: skillMdPath))
                let id = "\(source.rawValue):skill:\(subdir)"
                results.append(SlashEntry(
                    id: id,
                    name: subdir,  // 親ディレクトリ名 = Claude Code が認識する skill 名
                    description: description,
                    kind: .skill,
                    source: source
                ))
            }
        }

        return results
    }

    /// Markdown frontmatter から `description:` または 2 行目を拾う。重くない
    /// ように最初の 40 行だけ読む。parse 失敗や未定義は nil で OK。
    private static func extractDescription(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 40,
                                omittingEmptySubsequences: false)
            .map { String($0) }
        guard !lines.isEmpty else { return nil }

        if lines.first == "---" {
            // YAML frontmatter: description: "..."
            for line in lines.dropFirst() {
                if line == "---" { break }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("description:") {
                    let value = trimmed.dropFirst("description:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    return value.isEmpty ? nil : value
                }
            }
        }
        // fallback: 最初の見出し / 段落の 1 行
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" { continue }
            // markdown heading を整理
            let cleaned = trimmed.replacingOccurrences(
                of: #"^#+\s*"#, with: "", options: .regularExpression
            )
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }
}
