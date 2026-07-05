# Claude Code 検証優先セットアップ

## 導入手順(プロジェクトごと)
1. この一式をプロジェクトルートに展開する(.claude/ と CLAUDE.md が root 直下に来るように)
2. chmod +x .claude/hooks/*.sh
3. CLAUDE.md の「プロジェクト固有情報」セクションを実際のビルド/テストコマンドに書き換える
4. .claude/hooks/verify.sh を使用言語に合わせて調整(不要な言語ブロックは削除可)
5. jq が必要: sudo apt install jq (Windowsなら scoop/choco または WSL)
6. Claude Code を起動し /hooks でフックが認識されているか確認

## 構成
- CLAUDE.md ............... 運用ルール(検証優先・ルーティング・STATUS.mdプロトコル)
- .claude/settings.json ... フック定義(git共有してチームに配布可)
- .claude/hooks/verify.sh . 編集ごとの自動lint/型チェック(失敗はClaudeに自動フィードバック)
- .claude/hooks/block-danger.sh ... 破壊的コマンドの実行前ブロック
- .claude/agents/explorer.md ... Haiku: 探索・ログ解析(幅・安さ)
- .claude/agents/architect.md .. Opus: 設計・難問(深さ)
- .claude/agents/adversary.md .. Sonnet: 敵対的レビュー
- .claude/commands/handoff.md .. /handoff: STATUS.md更新とコンテクスト引き継ぎ
- .claude/commands/redteam.md .. /redteam: GPT-5.5用レビュープロンプト生成
- .claude/commands/crossexam.md  /crossexam: GPT-5.5の返答との交差尋問
- .claude/commands/parallel.md . /parallel: 並列試作→検証で選抜

## 全プロジェクト共通にしたい場合
agents/ と commands/ は ~/.claude/agents/, ~/.claude/commands/ に置けばユーザー共通になる。
hooks は ~/.claude/settings.json に同じ内容を書けば共通化できるが、
verify.sh がプロジェクト構成に依存するため、まずはプロジェクト単位での導入を推奨。
