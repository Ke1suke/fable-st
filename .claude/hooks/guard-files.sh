#!/bin/bash
# PreToolUse (Edit|Write|MultiEdit|NotebookEdit) 保護ファイルガード
# 秘密情報・ロックファイル・.git 内部・ガード機構自体への編集をブロックする (exit 2)。
# 大文字小文字の差(.ENV 等)とシンボリックリンクを解決した実体パスの両方を検査する。

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')

[ -z "$FILE" ] && exit 0

PROJ="${CLAUDE_PROJECT_DIR:-.}"

# シンボリックリンク・相対パスを解決した実体パス(realpath が無い環境では元のパスで判定)
RESOLVED=$(realpath -m -- "$FILE" 2>/dev/null || echo "$FILE")

deny() {
  echo "BLOCKED: $1" >&2
  echo "対象ファイル: $FILE" >&2
  [ "$RESOLVED" != "$FILE" ] && echo "実体パス: $RESOLVED" >&2
  exit 2
}

# パスとベース名の検査(元のパスと解決後パスの両方に対して行う)
check_path() {
  local p="$1"
  local base lower
  base=$(basename "$p")
  lower=$(echo "$base" | tr '[:upper:]' '[:lower:]')

  # .git 内部
  case "$p" in
    */.git/*|.git/*) deny ".git 内部の直接編集は禁止(git コマンドを使う)" ;;
  esac

  # 秘密情報ファイル(.env.example 等のテンプレートは許可)
  case "$lower" in
    .env|.env.*)
      case "$lower" in
        *.example|*.sample|*.template|*.dist) : ;;
        *) deny "秘密情報ファイルの編集は禁止(必要ならユーザーに手動編集を依頼し、.env.example の更新を提案する)" ;;
      esac
      ;;
    .envrc|*.pem|*.p12|*.pfx|id_rsa*|id_ed25519*|id_ecdsa*|*.keystore|credentials.json|service[-_]account*.json|.netrc|.npmrc|.pypirc|*.tfstate|*.tfstate.backup)
      deny "秘密鍵・認証情報・状態ファイルの編集は禁止"
      ;;
  esac

  # ロックファイル(直接編集はほぼ常に誤り。パッケージマネージャ経由で更新する)
  case "$lower" in
    package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lockb|cargo.lock|poetry.lock|uv.lock|pipfile.lock|gemfile.lock|composer.lock|go.sum|flake.lock)
      deny "ロックファイルの直接編集は禁止(npm install / cargo update 等、パッケージマネージャ経由で更新する)"
      ;;
  esac
}

check_path "$FILE"
[ "$RESOLVED" != "$FILE" ] && check_path "$RESOLVED"

# 自己改変ガード: 防御機構(.claude/ 配下)と運用ルール(CLAUDE.md)の無断変更をブロックする。
# ユーザーが明示的に依頼した正当な変更の場合のみ、ユーザー承認のもと
# `touch .claude/allow-selfmod` で一時解除する(作業が終わったら削除する)。
if [ ! -f "$PROJ/.claude/allow-selfmod" ]; then
  for p in "$FILE" "$RESOLVED"; do
    case "$p" in
      */.claude/*|.claude/*)
        deny "ガード機構(.claude/ 配下)の変更は原則禁止。ユーザーが依頼した正当な変更なら、ユーザーに 'touch .claude/allow-selfmod' の実行を依頼してから再試行すること" ;;
    esac
    case "$(basename "$p")" in
      CLAUDE.md)
        deny "運用ルール(CLAUDE.md)の変更は原則禁止。ユーザーが承認した変更(/retro の教訓追記など)なら、ユーザーに 'touch .claude/allow-selfmod' の実行を依頼してから再試行すること" ;;
    esac
  done
fi

exit 0
