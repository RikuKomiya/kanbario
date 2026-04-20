# ADR 0002: Milestone 順序を D → C に反転する

- **Status**: Accepted
- **Date**: 2026-04-19
- **Deciders**: 本人 (solo)
- **Scope**: spec.md §8 のマイルストーン実装順序
- **Supersedes**: なし
- **Superseded by**: なし

---

## Context

spec.md §8 はマイルストーンを以下の順で並べていた:

1. Milestone A: 状態モデル + Kanban UI
2. Milestone B: WorktreeService
3. **Milestone C: claude spawn + hook 統合**
4. **Milestone D: libghostty 描画**

A / B 完了後、Milestone C 前半 (Start ボタンで claude を spawn してプロセス exit を検知) まで進めた段階で、claude の TUI 出力を表示する暫定 UI (`TaskDetailView.sessionPane` + `AppState.sessionLogs` + `stripANSI`) を作った。これが「動くだけで使い物にならない」状態だった:

- ANSI escape sequence を素朴に strip しているため色が出ない
- カーソル制御も座標操作も effective に効かないので、claude のリッチな TUI (border / spinner / カラーログ) がほぼ判読不能
- 入力欄も plain text で渡すだけなので、claude の interactive prompt との対話が破綻する

この状態で C 後半 (hook 統合) に進むと、「hook で状態変化を捕捉しても、肝心の TUI が読めないので何が起きたか分からない」 → デバッグが困難 → 進捗が止まる、という展望だった。

一方で D (libghostty 描画) を先に倒せば:

- 暫定 sessionPane / sessionLogs / stripANSI を**丸ごと捨てる**ことが確定する (libghostty が GPU に描画するので)
- 暫定 UI の磨き込みコストを完全に省略できる
- TUI が読めるようになるので、その上で hook 統合 (C 後半) を実装すれば動作確認が容易

---

## Decision

**spec.md §8 の C → D 順を D → C に反転して実装する**。

具体的には:

1. Milestone D (libghostty 描画) を先に完了させる
2. その間に暫定 sessionPane 系コードは触らない (どうせ捨てる)
3. D 完了 (色つき TUI が動く) 後に Milestone C 後半 (hook 統合) を進める

D 完了時点で C 前半の暫定 UI コードはすべて削除し、`ClaudeSessionFactory` を 264 → 100 行に縮退して PTY 所有を libghostty に移譲する。

---

## Consequences

### Positive

- **暫定 UI の磨き込みゼロ**: 捨てる前提のコードに時間を使わなくて済んだ。実際に D 完了時点で sessionPane / sessionLogs / stripANSI は迷いなく削除できた
- **デバッグの観測可能性向上**: hook 統合のデバッグが「TUI が見える状態」で進められる。claude が何を考えているかをターミナル上で目視できるので、hook event の発火タイミングと UI 反映の対応が取りやすい
- **cmux 写経の前提条件が揃う**: hook 統合は cmux の shim / CLI を流用する設計だが、cmux 自体が libghostty 前提なので D を先に倒した方が cmux のコード構造との対応が取りやすい

### Negative

- **C 前半の暫定 UI コードが約 1 週間「使われずに残る」**: D を完了させるまでは C 前半の動作確認は暫定 UI でしかできなかった。ただしこの期間は実機で「Start で claude が起動する」ことの確認用としては機能した
- **spec.md §8 と実装順が食い違う**: 仕様書を読んだ第三者は混乱しうる。これは next-steps.md の冒頭で「§8 と異なる」と明示することで対処

### Neutral

- 最終的な実装内容は同一 (どちらの順序でも C と D 両方を完了させる)。差は道中の中間状態だけ

---

## Alternatives Considered

### A. spec.md §8 通り C → D で進める

却下理由: 暫定 UI の磨き込みに時間を使うことになる + デバッグ困難。

### B. C 後半と D を並行で進める

却下理由: solo 開発なので並行の意味がない。コンテキストスイッチコストの方が大きい。

### C. C 前半で暫定 UI を作らず即 D に進む

検討した。Start ボタンの spawn 経路の動作確認が「色なし TUI が出ない状態」になり、wt + claude の動作がブラックボックス化するリスクが高かった。C 前半の暫定 UI は「捨てる前提だが、D 完了までの中間動作確認用に必要最低限を作る」という妥協で正解だった。

---

## References

- [spec.md §8](../spec.md) — 元の C → D 順序
- [docs/next-steps.md](../next-steps.md) — マイルストーン進捗の生きたメモ
- 関連 commit:
  - `98fa812` docs: 次セッションの着手メモ (Milestone D 先行の決定を含む)
  - Milestone D 完了 PR: #1 (`a46c28a`)
  - Milestone C 後半完了 PR: #2 (`71137ee`)
