#!/bin/bash
# PostToolUse (Edit|Write|MultiEdit) 検証フック
# 失敗時は exit 2 で stderr の内容が Claude にフィードバックされ、即座に修正ループに入る。
# 方針: 「入っているツールだけ実行」。ツール未導入なら黙って通す(導入は README 参照)。
# ★プロジェクトの言語・ツールに合わせて各ブロックを調整すること★

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[ -z "$FILE" ] && exit 0
[ ! -f "$FILE" ] && exit 0

# 生成物・外部コードは検証しない
case "$FILE" in
  */node_modules/*|*/.git/*|*/dist/*|*/build/*|*/vendor/*|*/target/*|*/.venv/*|*/venv/*) exit 0 ;;
esac

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

ERRORS=""
add_error() { ERRORS="$ERRORS\n[$1]\n$2"; }

case "$FILE" in
  *.py)
    if command -v ruff >/dev/null 2>&1; then
      OUT=$(ruff check "$FILE" 2>&1) || add_error "ruff" "$OUT"
      OUT=$(ruff format --check "$FILE" 2>&1) || add_error "ruff format" "$OUT"
    fi
    if command -v mypy >/dev/null 2>&1; then
      OUT=$(mypy --ignore-missing-imports "$FILE" 2>&1) || add_error "mypy" "$OUT"
    fi
    ;;
  *.ts|*.tsx|*.mts|*.cts)
    if command -v npx >/dev/null 2>&1 && [ -f package.json ]; then
      OUT=$(npx --no-install eslint "$FILE" 2>&1) || add_error "eslint" "$OUT"
      if [ -f tsconfig.json ]; then
        OUT=$(npx --no-install tsc --noEmit 2>&1) || add_error "tsc" "$OUT"
      fi
    fi
    ;;
  *.js|*.jsx|*.mjs|*.cjs)
    if command -v npx >/dev/null 2>&1 && [ -f package.json ]; then
      OUT=$(npx --no-install eslint "$FILE" 2>&1) || add_error "eslint" "$OUT"
    fi
    ;;
  *.go)
    if command -v gofmt >/dev/null 2>&1; then
      OUT=$(gofmt -l "$FILE" 2>&1)
      [ -n "$OUT" ] && add_error "gofmt" "未フォーマット: $OUT(gofmt -w で修正)"
    fi
    if command -v go >/dev/null 2>&1; then
      OUT=$(cd "$(dirname "$FILE")" && go vet . 2>&1) || add_error "go vet" "$OUT"
    fi
    ;;
  *.rs)
    if command -v cargo >/dev/null 2>&1 && [ -f Cargo.toml ]; then
      OUT=$(cargo check --quiet --message-format short 2>&1) || add_error "cargo check" "$OUT"
    fi
    ;;
  *.rb)
    if command -v rubocop >/dev/null 2>&1; then
      OUT=$(rubocop --force-exclusion "$FILE" 2>&1) || add_error "rubocop" "$OUT"
    elif command -v ruby >/dev/null 2>&1; then
      OUT=$(ruby -c "$FILE" 2>&1) || add_error "ruby -c" "$OUT"
    fi
    ;;
  *.php)
    if command -v php >/dev/null 2>&1; then
      OUT=$(php -l "$FILE" 2>&1) || add_error "php -l" "$OUT"
    fi
    ;;
  *.kt|*.kts)
    if command -v ktlint >/dev/null 2>&1; then
      OUT=$(ktlint "$FILE" 2>&1) || add_error "ktlint" "$OUT"
    fi
    ;;
  *.sh|*.bash)
    if command -v bash >/dev/null 2>&1; then
      OUT=$(bash -n "$FILE" 2>&1) || add_error "bash -n" "$OUT"
    fi
    if command -v shellcheck >/dev/null 2>&1; then
      OUT=$(shellcheck "$FILE" 2>&1) || add_error "shellcheck" "$OUT"
    fi
    ;;
  *.json)
    # tsconfig 等の JSONC(コメント付きJSON)は除外
    case "$(basename "$FILE")" in
      tsconfig*.json|*.jsonc|devcontainer.json) : ;;
      *)
        if command -v jq >/dev/null 2>&1; then
          OUT=$(jq empty "$FILE" 2>&1) || add_error "jq" "$OUT"
        fi
        ;;
    esac
    ;;
  *.yml|*.yaml)
    if command -v yamllint >/dev/null 2>&1; then
      OUT=$(yamllint -d relaxed "$FILE" 2>&1) || add_error "yamllint" "$OUT"
    fi
    ;;
  *.tf)
    if command -v terraform >/dev/null 2>&1; then
      OUT=$(terraform fmt -check "$FILE" 2>&1) || add_error "terraform fmt" "$OUT"
    fi
    ;;
esac

if [ -n "$ERRORS" ]; then
  echo -e "検証失敗。修正が必要:\n$ERRORS" >&2
  exit 2
fi

exit 0
