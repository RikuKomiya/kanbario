# ADR 0003: cmux は逐字写経ではなく機能再現で取り込む

- **Status**: Accepted
- **Date**: 2026-04-20
- **Deciders**: 本人 (solo)
- **Scope**: Milestone C 後半 (hook 統合) における cmux 由来コードの取り込み方
- **Supersedes**: なし
- **Superseded by**: なし

---

## Context

kanbario は libghostty + Claude Code hook 統合という重厚な統合領域で、先行実装の **cmux** (https://github.com/manaflow-ai/cmux、14k★) を参照実装としてコードを取り込む方針を採っていた。Milestone D (libghostty 描画) ではこの方針を「**完全踏襲 (逐字写経)**」と定義していた:

> 変数名 / 関数名の prefix は `cmux*` → `kanbario*`、環境変数は `CMUX_` → `KANBARIO_` に機械置換。それ以外は構造・ロジックを変えない。
>
> — `docs/next-steps.md` (D 着手時)

D ではこの方針が功を奏した。libghostty の modifier 左右判定 / clipboard NSPasteboard 分岐 / IME NSTextInputClient のエッジケースは、写経しなければ必ず踏む地雷だった。

しかし Milestone C 後半 (hook 統合) で同じ方針を当てようとした段階で、cmux のコード規模が想定外だと判明した:

- `CLI/cmux.swift`: **14,521 行**
- `SocketClient`: **約 450 行** (keychain 認証 / V2 RPC / multi-workspace fallback)
- `claude-hook` dispatch: 約 290 行 (per-event の status mutation + telemetry)
- 加えて codex / cursor / gemini など他 agent サポート、`open` サブコマンド、`postInstall` サブコマンド

逐字写経すると kanbario 側の CLI だけで 1,500 行超になる。一方で kanbario の MVP 要件は:

- 単一プロセス (multi-workspace 不要)
- 単一 surface (multi-tab 不要)
- 認証なし (Unix socket は同一ユーザー前提)
- 単一 agent (Claude Code のみ、codex / cursor / gemini 不要)

cmux の複雑性の大部分は kanbario には不要だった。

---

## Decision

**Milestone C 後半 (hook 統合) では「機能再現 (B 路線)」を採用する**。具体的には:

1. cmux の **挙動の契約** (環境変数規約 / JSON スキーマ / hook event 一覧 / shim の pass-through 条件) は踏襲する
2. cmux の **実装コード** は逐字写経しない。kanbario MVP の要件に必要な最小実装で再現する
3. cmux 由来の業務ロジック (status mutation / notification dispatch) は **CLI 側ではなく App 側に集約**する。CLI は素通しの relay に縮退する
4. Milestone D で採用した「完全踏襲」方針は Milestone D 範囲限定とする (libghostty + Metal layer + NSTextInputClient のエッジケース対応)

結果としての実装サイズ:

| Component | cmux | kanbario | 削減比 |
|---|---:|---:|---:|
| CLI (claude-hook 関連のみ) | ~800 行 | 108 行 | 87 % |
| SocketClient | 450 行 | 50 行 (CLI 内) | 89 % |
| Hook receiver | 約 200 行 (cmux app 側) | 173 行 | 13 % |
| AppState handler | (相当部分が CLI 内) | 約 60 行 | — |
| Shim | 約 100 行 (cmux) | 50 行 | 50 % |

cmux 14,521 行のうち実質取り込んだのは **約 300 行 (2 %)**。

---

## Consequences

### Positive

- **コードレビュー可能なサイズに収まった**: 1 PR で全部読み切れる (300 行) ので、後で読み直した時に何が起きているか追える
- **検証範囲の集中**: CLI が業務ロジックを持たないので、socket 1 経路の E2E テスト (Python listener で受信して JSON shape を確認) で全機能の動作保証が取れた
- **App 側の一元管理**: hook event → Kanban カラム遷移のマッピングが `AppState.handleHook(_:)` 1 箇所に集約される。"review" カラムの定義変更 (PR #2 の `871d420`) のような大幅修正も 1 ファイルで済んだ
- **Bundle 同梱が単純**: CLI が小さく依存物がないので、`Copy Hook Bin` build phase で 1 binary + 1 shim を埋め込むだけで済んだ

### Negative

- **cmux の bug fix を import する時に手作業が必要**: 直接的な merge は不可能。cmux で hook 周りの修正があった場合は、対応する kanbario コードの該当箇所を手で書き換える必要がある
- **将来 multi-workspace を持ちたくなった時に SocketClient 側を再実装する必要がある**: cmux の keychain 認証 / V2 RPC は捨てているので、ゼロから足すことになる。ただし MVP 要件には入っていないので現時点では問題なし

### Neutral

- 「cmux 写経」という単一方針ではなく、Milestone ごとに踏襲レベルを変える運用になった。Milestone D = 完全踏襲、Milestone C 後半 = 機能再現。**これはバグではなく意図的な使い分け**で、エッジケースが多い領域は写経、業務ロジックが kanbario 固有な領域は再実装、という棲み分け

---

## Alternatives Considered

### A. cmux 完全踏襲 (~1,500 行)

検討の出発点。`SocketClient` の 450 行、claude-hook dispatch 290 行、その他 fallback / authentication をすべて移植する案。

却下理由: kanbario MVP の要件 (単一 workspace / 認証なし / 単一 agent) に対して過剰。コードレビュー可能性が著しく落ちる。逐字写経という名目で「自分が理解していないコード」が大量に入ると、後で fix する時にコストが発生する。

### B. 機能再現 (採用)

cmux の挙動契約だけ踏襲、実装は MVP 要件に絞った最小再実装。

採用理由: 上記の「Positive」に列挙した利点。特に「CLI が小さい (108 行) ため業務ロジックを App 側に集約できる」が決定的だった。socket protocol さえ守れば実装の自由度が高い。

### C. 完全独自設計 (cmux 未参照)

cmux を一切見ずに Claude Code hook の仕様だけからゼロ設計する案。

却下理由: hook の挙動契約 (環境変数 / JSON shape / shim の pass-through 条件) は仕様書だけでは確定しない。cmux が実戦検証した規約を踏襲する方が地雷が少ない。

---

## References

- cmux: https://github.com/manaflow-ai/cmux
  - `CLI/cmux.swift` (14,521 行) — 参照した本体
  - `Resources/bin/claude` (約 100 行) — shim の参照
- 関連 PR: #2 (`71137ee`) — Milestone C 後半完了
- 関連 ADR: 0002 — Milestone 順序反転 (D → C、cmux 完全踏襲は D 限定だった経緯)
- spec.md §6 — Claude Code 統合の仕様
