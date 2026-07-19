#!/bin/bash
# SessionStart フック
# stdout がそのまま新しいコンテクストに注入される。
# 「新セッションはまず STATUS.md を読む」というルールを、ルールではなく自動化で保証する。

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

echo "== プロジェクト状態(SessionStart フックによる自動注入) =="

# 前提ツールの欠如はここで能動的に警告する(ガード類が黙って no-op 化する事故の防止)
command -v jq >/dev/null 2>&1 \
  || echo "警告: jq が見つからない。ガード系フック(block-danger / guard-files / verify)が全て無効になっている。README の前提ツールに従って導入すること。"

if [ -f STATUS.md ]; then
  echo "--- STATUS.md ---"
  # 肥大化していても事故らないよう上限を設ける。行単位で切るためマルチバイト文字を壊さない
  # (STATUS.md 自体を簡潔に保つのが本筋)
  head -n 120 STATUS.md
  [ "$(wc -l < STATUS.md)" -gt 120 ] && echo "...(120行で切り捨て。STATUS.md が肥大化している。/handoff で整理すること)"
else
  echo "STATUS.md が存在しない。作業の節目に /handoff で作成すること。"
fi

echo "--- git 状態 ---"
git status -sb 2>/dev/null | head -30
echo "--- 直近のコミット ---"
git log --oneline -5 2>/dev/null

exit 0
