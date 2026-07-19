#!/bin/bash
# SessionStart フック
# stdout がそのまま新しいコンテクストに注入される。
# 「新セッションはまず STATUS.md を読む」というルールを、ルールではなく自動化で保証する。

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

echo "== プロジェクト状態(SessionStart フックによる自動注入) =="

if [ -f STATUS.md ]; then
  echo "--- STATUS.md ---"
  # 肥大化していても事故らないよう上限を設ける(STATUS.md 自体を簡潔に保つのが本筋)
  head -c 8000 STATUS.md
  [ "$(wc -c < STATUS.md)" -gt 8000 ] && echo "...(8KB で切り捨て。STATUS.md が肥大化している。/handoff で整理すること)"
else
  echo "STATUS.md が存在しない。作業の節目に /handoff で作成すること。"
fi

echo "--- git 状態 ---"
git status -sb 2>/dev/null | head -30
echo "--- 直近のコミット ---"
git log --oneline -5 2>/dev/null

exit 0
