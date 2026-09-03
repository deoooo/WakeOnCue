#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
server_directory="$(cd "$script_directory/.." && pwd)"
repository_directory="$(cd "$server_directory/.." && pwd)"
backend="${WAKEONCUE_ASR_BACKEND:-whisper}"

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
python3 -m venv "$server_directory/.venv"
"$server_directory/.venv/bin/python" -m pip install --upgrade pip
"$server_directory/.venv/bin/pip" install -e "$server_directory[mac-processor]"

if [[ "$backend" == "qwen" ]]; then
  qwen_runtime="$repository_directory/.runtime/asr-qwen"
  mkdir -p "$qwen_runtime"
  python3 -m venv "$qwen_runtime/.venv"
  "$qwen_runtime/.venv/bin/python" -m pip install --upgrade pip
  "$qwen_runtime/.venv/bin/pip" install -e "$server_directory[qwen-processor]"
  echo "Qwen runtime is ready. Set WAKEONCUE_QWEN_MODEL to a local Qwen3-ASR-1.7B checkout."
fi

if ! command -v dns-sd >/dev/null; then
  echo "Warning: dns-sd is missing; Bonjour LAN discovery will be unavailable." >&2
fi

keychain_service="com.deoooo.WakeOnCue.realtime.mac"
keychain_account="gateway-token"
if ! /usr/bin/security find-generic-password -s "$keychain_service" -a "$keychain_account" -w >/dev/null 2>&1; then
  token="$(/usr/bin/openssl rand -hex 32)"
  /usr/bin/security add-generic-password -U -s "$keychain_service" -a "$keychain_account" -w "$token" >/dev/null
  echo "Created a random realtime Gateway token in the macOS Keychain."
else
  echo "Reusing the existing realtime Gateway token in the macOS Keychain."
fi

echo "Mac dependencies are ready. Start the LAN stack with:"
echo "  server/scripts/run_local_mac_stack.sh"
