# Claude Code 高生産性セットアップ(検証優先 + モデルルーティング)

Opus 4.8 / Sonnet 5 / Haiku を適材適所で使い分け、フックによる機械的な強制で
「検証済みのものだけが完了と呼ばれる」状態を作るための一式。

## 設計思想
1. **ルールより強制** — 破壊的コマンドや秘密情報の操作は、CLAUDE.md の「お願い」ではなく
   フックと permissions で機械的にブロックする。
2. **検証優先** — 完了の根拠は常に「いま実行した検証コマンドの結果」。
   さらに verifier サブエージェントが実装者の自己申告を再検証する。
3. **コンテクスト経済** — 探索は Haiku に、深い思考は Opus に委譲し、メインの文脈を薄めない。
4. **状態の外部化** — セッションを跨ぐ記憶は STATUS.md に置き、SessionStart フックで自動注入する。
5. **敵対的レビュー** — 計画と差分は adversary / 外部モデル(/redteam)に攻撃させてから確定する。
6. **自己改善** — 失敗は /retro で教訓化し、CLAUDE.md(または新しいフック)に還流する。

## 導入手順(プロジェクトごと)
1. この一式をプロジェクトルートに展開する(.claude/ と CLAUDE.md が root 直下に来るように)
2. `chmod +x .claude/hooks/*.sh`
3. CLAUDE.md の「プロジェクト固有情報」を実際のビルド/テストコマンドに書き換える
4. .claude/hooks/verify.sh を使用言語に合わせて調整(不要な言語ブロックは削除可)
5. 前提ツールを導入(下記)
6. Claude Code を起動し `/hooks` でフック、`/agents` でサブエージェントの認識を確認

### 前提ツール
- **jq(必須)**: フックの JSON パースに使用。無いとガード系フックが素通しになる。
  `sudo apt install jq` / `brew install jq`(Windows は scoop/choco または WSL)
- **shellcheck(推奨)**: シェルスクリプト編集時の自動検証に使用。
- 各言語の linter/型チェッカ(ruff, mypy, eslint, tsc など): 入っているものだけが実行される。

## 構成

| ファイル | 役割 |
|---|---|
| CLAUDE.md | 運用ルール(検証優先・モデル戦略・コンテクスト経済・教訓) |
| STATUS.md | セッション間の作業メモリ(/handoff が更新、SessionStart が注入) |
| .claude/settings.json | permissions(秘密情報の読み取り拒否等)+ フック定義 |
| .claude/hooks/session-start.sh | 新セッションに STATUS.md と git 状態を自動注入 |
| .claude/hooks/block-danger.sh | 破壊的コマンド(rm -rf, force push, compose down 等)の実行前ブロック |
| .claude/hooks/guard-files.sh | 秘密情報・ロックファイル・.git 内部への編集ブロック |
| .claude/hooks/verify.sh | 編集ごとの自動 lint/型チェック(失敗は Claude に自動フィードバック) |
| .claude/agents/explorer.md | Haiku: 探索・ログ解析(幅と安さ) |
| .claude/agents/architect.md | Opus: 設計・難問の根本原因分析(深さ) |
| .claude/agents/adversary.md | 敵対的レビュー(計画・差分の穴を探す) |
| .claude/agents/verifier.md | 完了主張の独立検証(自己申告を信用しない) |
| .claude/commands/handoff.md | /handoff: STATUS.md 更新とコンテクスト引き継ぎ |
| .claude/commands/precommit.md | /precommit: コミット前の総点検 |
| .claude/commands/debug.md | /debug: 体系的デバッグプロトコル |
| .claude/commands/retro.md | /retro: 失敗から教訓を抽出し CLAUDE.md に還流 |
| .claude/commands/redteam.md | /redteam: 外部モデル(GPT-5.5)用レビュープロンプト生成 |
| .claude/commands/crossexam.md | /crossexam: 外部モデルの返答との交差尋問 |
| .claude/commands/parallel.md | /parallel: 並列試作 → 検証結果で選抜 |

## モデル戦略(Fable なし・Pro プラン前提)
- **日常の実装**: Sonnet 5(速く、十分に賢い)
- **設計・難デバッグ・重要レビュー**: Opus 4.8
- **計画だけ重くする**: `/model opusplan`(Plan Mode = Opus、実行 = Sonnet。利用可能な場合)
- **探索・ログ解析**: explorer サブエージェント(Haiku)に委譲
- **難問**: 拡張思考(プロンプトに think hard / ultrathink)
- **レート制限の節約**:
  - 調査結果は STATUS.md に書き、同じ調査を繰り返さない
  - 大量読み込みは Haiku(explorer)へ。メインモデルのトークンを読み捨てに使わない
  - 無関係タスクの前に /clear。長話の compact 連打より /handoff で新セッション

## 典型的なワークフロー

```
新セッション開始
  └─ SessionStart フックが STATUS.md + git 状態を自動注入
計画(非自明なタスクは plan mode)
  └─ 重要な計画 → adversary レビュー、外部視点 → /redteam → /crossexam
  └─ 方針が不確実 → /parallel で並列試作
実装
  └─ 編集のたびに verify.sh が自動 lint/型チェック(失敗は即フィードバック)
  └─ バグに遭遇 → /debug プロトコル
完了前
  └─ 一定規模なら verifier で独立検証 → /precommit → コミット
節目
  └─ /handoff で STATUS.md 更新 → 新セッションへ
失敗があったら
  └─ /retro で教訓化 → CLAUDE.md またはフックに還流
```

## カスタマイズガイド
- **verify.sh**: 言語ブロックの追加・削除。プロジェクトの正式な lint コマンドがあるなら
  それを直接呼ぶ形に書き換えるのが最善。
- **block-danger.sh**: 末尾の「プロジェクト固有の追加禁止」に危険コマンドを追記
  (例: terraform destroy、本番 DB への接続)。
- **permissions**(settings.json): よく使う安全なコマンドを allow に足すと確認プロンプトが減る。
  個人の好みは .claude/settings.local.json(gitignore 済み)へ。
- **フックを一時的に無効化したい場合**: settings.json から該当エントリを外す。
  --no-verify での回避はフック自身がブロックする(仕様)。

## 全プロジェクト共通にしたい場合
agents/ と commands/ は ~/.claude/agents/, ~/.claude/commands/ に置けばユーザー共通になる。
hooks は ~/.claude/settings.json に同じ内容を書けば共通化できるが、
verify.sh がプロジェクト構成に依存するため、まずはプロジェクト単位での導入を推奨。
