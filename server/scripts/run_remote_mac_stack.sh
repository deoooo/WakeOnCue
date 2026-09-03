#!/bin/bash

set -euo pipefail

# LaunchAgents do not inherit Homebrew's shell PATH. MLX Whisper invokes ffmpeg
# by name, so keep the Homebrew prefix explicit for unattended processing.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

script_directory="$(cd "$(dirname "$0")" && pwd)"
server_directory="$(cd "$script_directory/.." && pwd)"
repository_directory="$(cd "$server_directory/.." && pwd)"
runtime_directory="$server_directory/.runtime/remote-mac"
cloudflared_binary="/opt/homebrew/opt/cloudflared/bin/cloudflared"
python_binary="$server_directory/.venv/bin/python"
asr_backend="${WAKEONCUE_ASR_BACKEND:-qwen}"
qwen_runtime="$repository_directory/.runtime/asr-qwen"
processor_python="${WAKEONCUE_ASR_PYTHON:-$qwen_runtime/.venv/bin/python}"
qwen_model="${WAKEONCUE_QWEN_MODEL:-$qwen_runtime/models/Qwen3-ASR-1.7B}"
keychain_service="com.deoooo.WakeOnCue.realtime.mac"
keychain_account="gateway-token"
tunnel_log="$runtime_directory/cloudflared.log"
gateway_log="$runtime_directory/gateway.log"
processor_log="$runtime_directory/processor.log"
bonjour_log="$runtime_directory/bonjour.log"
gateway_bind_host="${WAKEONCUE_REALTIME_HOST:-0.0.0.0}"
local_host_name="${WAKEONCUE_REALTIME_LAN_HOST:-$(/usr/sbin/scutil --get LocalHostName).local}"

mkdir -p "$runtime_directory"
: > "$tunnel_log"
: > "$gateway_log"
: > "$processor_log"
: > "$bonjour_log"

if [[ ! -x "$cloudflared_binary" ]]; then
  echo "cloudflared is not installed at $cloudflared_binary" >&2
  exit 1
fi
if [[ ! -x "$python_binary" ]]; then
  echo "WakeOnCue Python environment is missing at $python_binary" >&2
  exit 1
fi
if [[ "$asr_backend" == "whisper" ]]; then
  processor_python="$python_binary"
elif [[ ! -x "$processor_python" ]]; then
  echo "Qwen3-ASR Python environment is missing at $processor_python" >&2
  echo "Set WAKEONCUE_ASR_PYTHON or use WAKEONCUE_ASR_BACKEND=whisper" >&2
  exit 1
fi

gateway_token="$(/usr/bin/security find-generic-password \
  -s "$keychain_service" -a "$keychain_account" -w)"
if [[ -z "$gateway_token" ]]; then
  echo "WakeOnCue realtime token is missing from Keychain" >&2
  exit 1
fi

child_pids=()
cleanup() {
  for child_pid in "${child_pids[@]:-}"; do
    kill "$child_pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

"$cloudflared_binary" tunnel \
  --no-autoupdate \
  --protocol http2 \
  --url http://127.0.0.1:8090 \
  --loglevel info \
  --logfile "$tunnel_log" \
  >> "$tunnel_log" 2>&1 &
child_pids+=("$!")

public_url=""
for _ in {1..60}; do
  public_url="$(/usr/bin/grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$tunnel_log" \
    | /usr/bin/tail -1 || true)"
  [[ -n "$public_url" ]] && break
  sleep 1
done
if [[ -z "$public_url" ]]; then
  echo "Cloudflare Quick Tunnel did not publish a URL" >&2
  exit 1
fi

(
  cd "$server_directory"
  exec env \
    WAKEONCUE_REALTIME_HOST="$gateway_bind_host" \
    WAKEONCUE_REALTIME_PORT=8090 \
    WAKEONCUE_REALTIME_PUBLIC_BASE_URL="$public_url" \
    WAKEONCUE_REALTIME_API_TOKEN="$gateway_token" \
    PYTHONPATH=. \
    "$python_binary" -m recording_service.realtime_main
) >> "$gateway_log" 2>&1 &
child_pids+=("$!")

for _ in {1..30}; do
  /usr/bin/curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1 && break
  sleep 1
done
if ! /usr/bin/curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1; then
  echo "WakeOnCue Realtime Gateway failed to start" >&2
  exit 1
fi

(
  cd "$server_directory"
  exec env \
    WAKEONCUE_REALTIME_API_TOKEN="$gateway_token" \
    PYTHONPATH=. \
    "$processor_python" -m recording_service.mac_processor \
      --gateway http://127.0.0.1:8090 \
      --backend "$asr_backend" \
      --qwen-model "$qwen_model" \
      --model "${WAKEONCUE_WHISPER_MODEL:-mlx-community/whisper-large-v3-turbo}"
) >> "$processor_log" 2>&1 &
child_pids+=("$!")

for _ in {1..60}; do
  local_health="$(/usr/bin/curl -fsS http://127.0.0.1:8090/health 2>/dev/null || true)"
  printf '%s' "$local_health" | /usr/bin/grep -Eq '"processors_available"[[:space:]]*:[[:space:]]*1' && break
  sleep 1
done
if ! printf '%s' "$local_health" | /usr/bin/grep -Eq '"processors_available"[[:space:]]*:[[:space:]]*1'; then
  echo "WakeOnCue Mac Processor failed to register" >&2
  exit 1
fi

public_health=""
for _ in {1..30}; do
  public_health="$(/usr/bin/curl -fsS --max-time 10 "$public_url/health" 2>/dev/null || true)"
  printf '%s' "$public_health" | /usr/bin/grep -Eq '"processors_available"[[:space:]]*:[[:space:]]*1' && break
  sleep 1
done
if ! printf '%s' "$public_health" | /usr/bin/grep -Eq '"processors_available"[[:space:]]*:[[:space:]]*1'; then
  echo "WakeOnCue public tunnel failed its health check" >&2
  exit 1
fi

/usr/bin/dns-sd -R \
  "WakeOnCue Gateway" \
  "_wakeoncue._tcp" \
  "local." \
  8090 \
  "protocol=1" \
  "host=$local_host_name" \
  "port=8090" \
  "scheme=http" \
  >> "$bonjour_log" 2>&1 &
child_pids+=("$!")

printf '%s\n' "$public_url" > "$runtime_directory/public-url"
printf 'http://%s:8090\n' "$local_host_name" > "$runtime_directory/local-url"

/usr/bin/caffeinate -dimsu -w $$ &
child_pids+=("$!")

echo "$public_url"

while true; do
  for child_pid in "${child_pids[@]:0:3}"; do
    if ! kill -0 "$child_pid" 2>/dev/null; then
      echo "WakeOnCue remote Mac service stopped unexpectedly" >&2
      exit 1
    fi
  done
  sleep 5
done
