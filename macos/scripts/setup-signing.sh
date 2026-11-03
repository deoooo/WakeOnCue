#!/bin/zsh
# Writes macos/Local.xcconfig so builds are signed with a stable identity and macOS keeps the
# microphone, system audio and calendar permissions across rebuilds.
#
#   scripts/setup-signing.sh            # first "Apple Development" identity in the keychain
#   scripts/setup-signing.sh TEAMID     # a specific team
set -euo pipefail

root=${0:A:h:h}
output="$root/Local.xcconfig"

team=${1:-}
if [[ -z $team ]]; then
  identity=$(security find-identity -v -p codesigning | grep -m1 '"Apple Development:' || true)
  if [[ -z $identity ]]; then
    echo "钥匙串里没有 Apple Development 证书。" >&2
    echo "在 Xcode › 设置 › 账户 里登录 Apple ID（免费账号也可以）并创建证书，然后重新运行。" >&2
    exit 1
  fi
  name=${${identity#*\"}%\"}
  team=$(security find-certificate -c "$name" -p | openssl x509 -noout -subject -nameopt multiline \
    | awk -F' = ' '/organizationalUnitName/ { print $2; exit }')
fi
if [[ -z $team ]]; then
  echo "没能从证书里读出团队 ID，请手动传入：scripts/setup-signing.sh TEAMID" >&2
  exit 1
fi

cat > "$output" <<XCCONFIG
// Written by scripts/setup-signing.sh. Not committed.
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = $team
XCCONFIG
echo "已写入 $output（团队 $team）。之后的构建都用这个身份签名，权限不会再反复询问。"
