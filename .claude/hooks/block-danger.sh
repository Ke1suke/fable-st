#!/bin/bash
# PreToolUse (Bash) 危険コマンドブロック
# exit 2 = 実行拒否(stderr が Claude に返り、理由を認識して代替案を出す)

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$CMD" ] && exit 0

if echo "$CMD" | grep -qE '(docker([ -])compose[[:space:]]+down|rm[[:space:]]+-rf[[:space:]]+[/~]|rm[[:space:]]+-rf[[:space:]]+\*|git[[:space:]]+push[[:space:]]+.*(--force|-f)([[:space:]]|$)|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+clean[[:space:]]+-[a-z]*f)'; then
  echo "BLOCKED: 破壊的コマンドはフックにより禁止されています: $CMD" >&2
  echo "必要な場合は理由を説明し、ユーザーに手動実行を依頼してください。" >&2
  exit 2
fi

exit 0
