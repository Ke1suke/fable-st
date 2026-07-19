#!/bin/bash
# PreToolUse (Edit|Write|MultiEdit) 保護ファイルガード
# 秘密情報ファイル・ロックファイル・.git 内部への直接編集をブロックする。
# exit 2 = 拒否(stderr が Claude に返る)

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')

[ -z "$FILE" ] && exit 0

BASE=$(basename "$FILE")

deny() {
  echo "BLOCKED: $1" >&2
  echo "対象ファイル: $FILE" >&2
  exit 2
}

# .git 内部
case "$FILE" in
  */.git/*|.git/*) deny ".git 内部の直接編集は禁止(git コマンドを使う)" ;;
esac

# 秘密情報ファイル(.env.example 等のテンプレートは許可)
case "$BASE" in
  .env|.env.*)
    case "$BASE" in
      *.example|*.sample|*.template|*.dist) : ;;
      *) deny "秘密情報ファイルの編集は禁止(必要ならユーザーに手動編集を依頼し、.env.example の更新を提案する)" ;;
    esac
    ;;
  *.pem|*.p12|*.pfx|id_rsa*|id_ed25519*|id_ecdsa*|*.keystore|credentials.json|service[-_]account*.json|.netrc|.npmrc|.pypirc)
    deny "秘密鍵・認証情報ファイルの編集は禁止"
    ;;
esac

# ロックファイル(直接編集はほぼ常に誤り。パッケージマネージャ経由で更新する)
case "$BASE" in
  package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lockb|Cargo.lock|poetry.lock|uv.lock|Pipfile.lock|Gemfile.lock|composer.lock|go.sum|flake.lock)
    deny "ロックファイルの直接編集は禁止(npm install / cargo update 等、パッケージマネージャ経由で更新する)"
    ;;
esac

exit 0
