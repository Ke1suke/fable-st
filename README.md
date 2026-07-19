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
- **jq(必須)**: フックの JSON パースに使用。無いとガード系フックが素通しになる
  (欠如時は SessionStart フックが警告を出す)。
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
| .claude/hooks/tests/test-hooks.sh | フックの回帰テスト(150件超)。フックを変更したら必ず実行する |
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
  - デフォルトは「編集したファイル単体の高速チェック」のみ。プロジェクト全体の検査
    (tsc --noEmit / cargo check / go vet)は重いので、settings.json の `env` に
    `"CLAUDE_VERIFY_FULL": "1"` を設定したときだけ実行される(小規模プロジェクト向け)。
    全体検査は /precommit と verifier が担う設計。
- **block-danger.sh**: 末尾の「プロジェクト固有の追加禁止」に危険コマンドを追記
  (例: terraform destroy、本番 DB への接続)。
- **フックを変更したら**: `bash .claude/hooks/tests/test-hooks.sh` で回帰テストを必ず実行する。
  新しい危険パターンを足すときは、ブロックすべき例と通すべき例の両方をテストに追加する。
- **モデル指定**: .claude/agents/*.md の `model:`(haiku/sonnet/opus)はエイリアス。
  モデル世代が変わったら4ファイルの指定を見直す。
- **permissions**(settings.json): よく使うテスト・lint 系は allow 済み。プロジェクト固有の
  コマンドを足すと確認プロンプトが減る。個人の好みは .claude/settings.local.json(gitignore 済み)へ。
- **.claude/ や CLAUDE.md を変更したい場合**: ガード機構自体の変更はフックがブロックする。
  ユーザーが承認した正当な変更のときだけ `touch .claude/allow-selfmod` で一時解除し、
  作業が終わったら削除する(このファイルは gitignore 済み)。

## 既知の制約(正直に)
このセットアップの防御は「**事故防止**」であり「**セキュリティ境界**」ではない。
- フックは正規表現ベース。コマンドの変形(一旦コピーしてから読む、エンコード、別名実行)で
  原理的に迂回できる。網羅は不可能であり、よくある事故パターンを止めるのが目的。
- 逆に、引用文字列・ヒアドキュメント内の無害なテキストにも反応する(安全側の誤検知)。
  ブロックされたら文字列を書き換えるか、ユーザーに手動実行を依頼する。
- 秘密情報は「読み取り拒否」が主な防御。読めてしまった内容が別ファイルへ複製される経路までは
  完全には防げない。本気の防御が必要なら、コンテナ隔離・ネットワーク分離・権限分離を使うこと。
- `.claude/allow-selfmod` による解除自体を防ぐ仕組みはない(内側からの完全な自己拘束は原理的に不可能)。
  解除はユーザーの承認を得た場合のみ、という運用ルールとセットで機能する。
  消し忘れ対策として、センチネルは作成から60分で自動失効し、存在する間は SessionStart が警告を出す。
- サブエージェントの「編集禁止」「STATUS.md に書かない」はプロンプトレベルの規律。
  フックはサブエージェントのツール呼び出しにも適用されるが、一般のソースファイルへの書き込みを
  「誰が書いたか」で区別することはできない。
- Stop フック(prompt 型)の判定は会話上の完了報告に依存し、深い検証はしない。
  最終的な砦は /precommit と verifier サブエージェント。

## 全プロジェクト共通にしたい場合
agents/ と commands/ は ~/.claude/agents/, ~/.claude/commands/ に置けばユーザー共通になる。
hooks は ~/.claude/settings.json に同じ内容を書けば共通化できるが、
verify.sh がプロジェクト構成に依存するため、まずはプロジェクト単位での導入を推奨。
