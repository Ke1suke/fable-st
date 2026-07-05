#!/bin/bash
# PostToolUse (Edit|Write) 検証フック
# 失敗時は exit 2 で stderr の内容が Claude にフィードバックされ、即座に修正ループに入る。
# ★プロジェクトの言語・ツールに合わせて各ブロックを調整すること★

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[ -z "$FILE" ] && exit 0
[ ! -f "$FILE" ] && exit 0

ERRORS=""

case "$FILE" in
  *.py)
    # Python: ruff (lint) + mypy (型) — 入っているものだけ実行
    if command -v ruff >/dev/null 2>&1; then
      OUT=$(ruff check "$FILE" 2>&1) || ERRORS="$ERRORS\n[ruff]\n$OUT"
    fi
    if command -v mypy >/dev/null 2>&1; then
      OUT=$(mypy --ignore-missing-imports "$FILE" 2>&1) || ERRORS="$ERRORS\n[mypy]\n$OUT"
    fi
    ;;
  *.ts|*.tsx|*.js|*.jsx)
    if command -v npx >/dev/null 2>&1 && [ -f package.json ]; then
      OUT=$(npx --no-install eslint "$FILE" 2>&1) || ERRORS="$ERRORS\n[eslint]\n$OUT"
      if [ -f tsconfig.json ]; then
        OUT=$(npx --no-install tsc --noEmit 2>&1) || ERRORS="$ERRORS\n[tsc]\n$OUT"
      fi
    fi
    ;;
  *.kt)
    if command -v ktlint >/dev/null 2>&1; then
      OUT=$(ktlint "$FILE" 2>&1) || ERRORS="$ERRORS\n[ktlint]\n$OUT"
    fi
    ;;
  *.sh)
    if command -v shellcheck >/dev/null 2>&1; then
      OUT=$(shellcheck "$FILE" 2>&1) || ERRORS="$ERRORS\n[shellcheck]\n$OUT"
    fi
    ;;
esac

if [ -n "$ERRORS" ]; then
  echo -e "検証失敗。修正が必要:\n$ERRORS" >&2
  exit 2
fi

exit 0
