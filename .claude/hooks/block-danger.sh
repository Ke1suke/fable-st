#!/bin/bash
# PreToolUse (Bash) 危険コマンドブロック
# exit 2 = 実行拒否(stderr が Claude に返り、理由を認識して代替案を出す)
# ルールで「お願い」するのではなく、機械的に強制するための最終防衛線。
# プロジェクト固有の危険コマンドは末尾のセクションに追加すること。

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0   # jq が無い環境ではガード不能(READMEの前提ツール参照)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$CMD" ] && exit 0

deny() {
  echo "BLOCKED: $1" >&2
  echo "対象コマンド: $CMD" >&2
  echo "本当に必要な場合は、理由と影響範囲を説明してユーザーの明示的な承認を得るか、手動実行を依頼すること。" >&2
  exit 2
}

# --- コンテナ/インフラ破壊 ---
echo "$CMD" | grep -qE 'docker([ -])compose[[:space:]]+down' \
  && deny "docker compose down は禁止(過去に環境破壊事故あり)"
echo "$CMD" | grep -qE 'docker[[:space:]]+(system|volume|image|container|network)[[:space:]]+prune' \
  && deny "docker prune 系は復元不能なため禁止"
echo "$CMD" | grep -qE '(^|[[:space:];&|])(mkfs(\.[a-z0-9]+)?|fdisk|parted)([[:space:]]|$)' \
  && deny "ディスク/パーティション操作は禁止"
echo "$CMD" | grep -qE 'dd[[:space:]]+[^;&|]*of=/dev/' \
  && deny "デバイスへの dd 書き込みは禁止"

# --- ファイル一括破壊 ---
# rm -rf/-fr(フラグ結合含む)+ 危険なターゲット(/ ~ * . .. .git)
echo "$CMD" | grep -qE 'rm[[:space:]]+-[a-zA-Z]*([rR][a-zA-Z]*f|f[a-zA-Z]*[rR])[a-zA-Z]*[[:space:]]+([/~*]|\./?([[:space:]]|$)|\.\.(/[^[:space:]]*)?([[:space:]]|$)|\.git([[:space:]]|$|/))' \
  && deny "危険な rm -rf(ルート/ホーム/カレント/.git への再帰削除)"
echo "$CMD" | grep -qE 'find[[:space:]]+[^;&|]*-delete' \
  && deny "find -delete は影響範囲が読みにくいため禁止(まず -print で対象を確認しユーザー承認を得る)"

# --- git の不可逆操作 ---
echo "$CMD" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;&|]*(--force|-f)([[:space:]]|$)' \
  && deny "git push --force は禁止(どうしても必要なら --force-with-lease をユーザー承認の上で)"
echo "$CMD" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;&|]*[[:space:]]\+[^[:space:]]' \
  && deny "+refspec による強制 push は禁止"
echo "$CMD" | grep -qE 'git[[:space:]]+reset[[:space:]]+[^;&|]*--hard' \
  && deny "git reset --hard は未コミット変更を破壊するため禁止"
echo "$CMD" | grep -qE 'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f' \
  && deny "git clean -f は禁止(まず git clean -n で対象を確認しユーザー承認を得る)"
echo "$CMD" | grep -qE 'git[[:space:]]+(checkout|restore)[[:space:]]+(--[[:space:]]+)?\.([[:space:]]|$)' \
  && deny "git checkout/restore . による未コミット変更の一括破棄は禁止"
echo "$CMD" | grep -qE 'git[[:space:]]+stash[[:space:]]+(clear|drop)' \
  && deny "git stash clear/drop は退避内容を失うため禁止"
echo "$CMD" | grep -qE 'git[[:space:]]+commit[[:space:]]+[^;&|]*--no-verify' \
  && deny "--no-verify によるフック回避は禁止(フックが失敗するなら原因を直す)"
echo "$CMD" | grep -qE 'git[[:space:]]+branch[[:space:]]+[^;&|]*-D([[:space:]]|$)' \
  && deny "git branch -D(未マージブランチの強制削除)は禁止"

# --- 秘密情報の読み出し(.env のダンプ。キー名の確認は grep -oE '^[A-Z0-9_]+' を使う) ---
if echo "$CMD" | grep -qE '(^|[[:space:];&|])(cat|less|more|head|tail|bat|strings)[[:space:]]+[^;&|]*\.env' \
   && ! echo "$CMD" | grep -qE '\.env[a-zA-Z0-9_.-]*\.(example|sample|template)'; then
  deny ".env の内容表示は禁止(変数名の確認だけなら grep -oE '^[A-Z0-9_]+' .env を使う)"
fi
echo "$CMD" | grep -qE '>[[:space:]]*\.env([.[:space:]]|$)' \
  && ! echo "$CMD" | grep -qE '\.env[a-zA-Z0-9_.-]*\.(example|sample|template)' \
  && deny ".env へのリダイレクト書き込みは禁止"

# --- 外部公開・サプライチェーン ---
echo "$CMD" | grep -qE '(^|[[:space:];&|])(npm|pnpm|yarn)[[:space:]]+publish' \
  && deny "パッケージの publish はユーザーの明示的承認が必要"
echo "$CMD" | grep -qE '(^|[[:space:];&|])twine[[:space:]]+upload' \
  && deny "PyPI への upload はユーザーの明示的承認が必要"
echo "$CMD" | grep -qE '(curl|wget)[[:space:]][^;&|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)' \
  && deny "リモートスクリプトのパイプ実行(curl | sh)は禁止(まずダウンロードして内容を確認する)"

# --- プロジェクト固有の追加禁止(ここに追記) ---
# 例: echo "$CMD" | grep -qE 'terraform[[:space:]]+destroy' && deny "terraform destroy は禁止"

exit 0
