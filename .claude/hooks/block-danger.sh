#!/bin/bash
# PreToolUse (Bash) 危険コマンドブロック
# exit 2 = 実行拒否(stderr が Claude に返り、理由を認識して代替案を出す)
#
# 位置づけ: これは「事故防止」であり「セキュリティ境界」ではない(README の既知の制約を参照)。
# 正規表現ベースのため変形コマンドで原理的に迂回可能。引用文字列・ヒアドキュメント内の
# テキストにも反応する(安全側の誤検知として許容する)。grep は行単位でマッチする。
# プロジェクト固有の危険コマンドは末尾のセクションに追加すること。

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0   # jq が無い環境ではガード不能(session-start.sh が警告を出す)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$CMD" ] && exit 0

deny() {
  echo "BLOCKED: $1" >&2
  echo "対象コマンド: $CMD" >&2
  echo "本当に必要な場合は、理由と影響範囲を説明してユーザーの明示的な承認を得るか、手動実行を依頼すること。" >&2
  exit 2
}

# --- 自己改変ガード: 防御機構そのものを Bash 経由で書き換えることを禁止 ---
# メンテナンス時はユーザー承認のもと `touch .claude/allow-selfmod` で一時解除(作業後に削除)。
if [ ! -f "${CLAUDE_PROJECT_DIR:-.}/.claude/allow-selfmod" ]; then
  if echo "$CMD" | grep -qE '\.claude/(settings(\.local)?\.json|hooks/)' \
     && echo "$CMD" | grep -qE '(>|>>|sed[[:space:]]+-i|tee[[:space:]]|mv[[:space:]]|cp[[:space:]]|rm[[:space:]]|chmod[[:space:]]|truncate[[:space:]]|ln[[:space:]])'; then
    deny "ガード機構(.claude/settings*.json, .claude/hooks/)の Bash 経由の変更は禁止。ユーザーが依頼した正当なメンテナンスなら、ユーザーに 'touch .claude/allow-selfmod' の実行(または手動編集)を依頼すること"
  fi
fi

# --- コンテナ/インフラ破壊 ---
# docker(-)compose ... down : 間にどんなフラグ(-f file, --env-file 等)が入っても検出する
echo "$CMD" | grep -qE 'docker([[:space:]]+|-)compose([[:space:]]+[^;&|]*)?[[:space:]]+down([[:space:]]|$)' \
  && deny "docker compose down は禁止(過去に環境破壊事故あり)"
echo "$CMD" | grep -qE 'docker[[:space:]]+(system|volume|image|container|network|builder|buildx)[[:space:]]+prune' \
  && deny "docker prune 系は復元不能なため禁止"
echo "$CMD" | grep -qE '(^|[[:space:];&|])(mkfs(\.[a-z0-9]+)?|fdisk|parted)([[:space:]]|$)' \
  && deny "ディスク/パーティション操作は禁止"
echo "$CMD" | grep -qE 'dd[[:space:]]+[^;&|]*of=/dev/' \
  && deny "デバイスへの dd 書き込みは禁止"

# --- ファイル一括破壊 ---
# rm + 再帰フラグ(-r / -rf / -r -f / --recursive、順不同・分離形も検出)+ 危険なターゲット
# 危険なターゲット: 絶対パス, ~, グロブ, カレント(., ./), 親(.., ../xxx), .git
RM_FLAGS='((-[a-zA-Z]+|--[a-z-]+)[[:space:]]+)*(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)[[:space:]]+((-[a-zA-Z]+|--[a-z-]+)[[:space:]]+)*'
RM_TARGET='([/~*]|\./?([[:space:]]|$)|\.\.(/[^[:space:]]*)?([[:space:]]|$)|\.git([[:space:]]|$|/))'
echo "$CMD" | grep -qE "(^|[[:space:];&|(])rm[[:space:]]+${RM_FLAGS}${RM_TARGET}" \
  && deny "危険な rm(絶対パス/ホーム/カレント/親ディレクトリ/.git への再帰削除)"
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

# --- 秘密情報の読み出し・書き込み(.env 系。テンプレート .env.example 等は除外) ---
# 変形(cp してから読む、sed/awk/grep でのダンプ)もできる範囲で検出する。
# 変数名の一覧だけ必要な場合の公認イディオム: grep -oE '^[A-Z0-9_]+' .env
ENV_REF='\.env(\.[A-Za-z0-9_.-]+)?([[:space:]"'"'"']|$)'
ENV_TEMPLATE='\.env[A-Za-z0-9_.-]*\.(example|sample|template|dist)'
if echo "$CMD" | grep -qE "(^|[[:space:];&|])(cat|less|more|head|tail|bat|strings|cp|mv|ln|dd|sed|awk|sort|uniq|tr|cut|paste|rev|od|xxd|hexdump|base64|grep|egrep|fgrep|rg)[[:space:]][^;&|]*${ENV_REF}" \
   && ! echo "$CMD" | grep -qE "$ENV_TEMPLATE" \
   && ! echo "$CMD" | grep -qE "(grep|rg)[[:space:]][^;&|]*-[a-zA-Z]*o[a-zA-Z]*[[:space:]][^;&|]*['\"]\^"; then
  deny ".env の内容の表示・複製は禁止(変数名の確認だけなら grep -oE '^[A-Z0-9_]+' .env を使う)"
fi
if echo "$CMD" | grep -qE "open\(['\"][^'\")]*\.env" \
   && ! echo "$CMD" | grep -qE "$ENV_TEMPLATE"; then
  deny "スクリプト経由の .env 読み出しは禁止"
fi
if echo "$CMD" | grep -qE '>[[:space:]]*\.env([.[:space:]]|$)' \
   && ! echo "$CMD" | grep -qE "$ENV_TEMPLATE"; then
  deny ".env へのリダイレクト書き込みは禁止"
fi

# --- 外部公開・サプライチェーン ---
echo "$CMD" | grep -qE '(^|[[:space:];&|])(npm|pnpm|yarn)[[:space:]]+publish' \
  && deny "パッケージの publish はユーザーの明示的承認が必要"
echo "$CMD" | grep -qE '(^|[[:space:];&|])twine[[:space:]]+upload' \
  && deny "PyPI への upload はユーザーの明示的承認が必要"
echo "$CMD" | grep -qE '(curl|wget)[[:space:]][^;&|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)' \
  && deny "リモートスクリプトのパイプ実行(curl | sh)は禁止(まずダウンロードして内容を確認する)"
echo "$CMD" | grep -qE '(^|[[:space:];&|])(base64|openssl)[[:space:]][^;&|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)' \
  && deny "デコード結果のパイプ実行は禁止(内容を確認してから実行する)"

# --- プロジェクト固有の追加禁止(ここに追記) ---
# 例: echo "$CMD" | grep -qE 'terraform[[:space:]]+destroy' && deny "terraform destroy は禁止"

exit 0
