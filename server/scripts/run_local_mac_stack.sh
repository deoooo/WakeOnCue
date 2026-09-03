#!/bin/bash

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

script_directory="$(cd "$(dirname "$0")" && pwd)"
server_directory="$(cd "$script_directory/.." && pwd)"
repository_directory="$(cd "$server_directory/.." && pwd)"
runtime_directory="$server_directory/.runtime/local-mac"
python_binary="$server_directory/.venv/bin/python"
backend="${WAKEONCUE_ASR_BACKEND:-whisper}"
processor_python="$python_binary"
qwen_model="${WAKEONCUE_QWEN_MODEL:-$repository_directory/.runtime/asr-qwen/models/Qwen3-ASR-1.7B}"
token="$(/usr/bin/security find-generic-password -s com.deoooo.WakeOnCue.realtime.mac -a gateway-token -w 2>/dev/null || true)"
host_name="${WAKEONCUE_REALTIME_LAN_HOST:-$(/usr/sbin/scutil --get LocalHostName).local}"

[[ -x "$python_binary" ]] || { echo "Run server/scripts/setup_mac.sh first" >&2; exit 1; }
[[ -n "$token" ]] || { echo "Gateway token missing; run server/scripts/setup_mac.sh first" >&2; exit 1; }
if [[ "$backend" == "qwen" ]]; then
  processor_python="$repository_directory/.runtime/asr-qwen/.venv/bin/python"
  [[ -x "$processor_python" ]] || { echo "Run WAKEONCUE_ASR_BACKEND=qwen server/scripts/setup_mac.sh first" >&2; exit 1; }
fi

mkdir -p "$runtime_directory"
gateway_log="$runtime_directory/gateway.log"
processor_log="$runtime_directory/processor.log"
bonjour_log="$runtime_directory/bonjour.log"
child_pids=()
cleanup() { for pid in "${child_pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

(
  cd "$server_directory"
  exec env WAKEONCUE_REALTIME_HOST=0.0.0.0 WAKEONCUE_REALTIME_PORT=8090 \
    WAKEONCUE_REALTIME_API_TOKEN="$token" PYTHONPATH=. \
    "$python_binary" -m recording_service.realtime_main
) >> "$gateway_log" 2>&1 &
child_pids+=("$!")

for _ in {1..30}; do curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1 && break; sleep 1; done
curl -fsS http://127.0.0.1:8090/health >/dev/null || { echo "Gateway failed to start" >&2; exit 1; }

(
  cd "$server_directory"
  exec env WAKEONCUE_REALTIME_API_TOKEN="$token" PYTHONPATH=. \
    "$processor_python" -m recording_service.mac_processor --gateway http://127.0.0.1:8090 \
      --backend "$backend" --qwen-model "$qwen_model" \
      --model "${WAKEONCUE_WHISPER_MODEL:-mlx-community/whisper-large-v3-turbo}"
) >> "$processor_log" 2>&1 &
child_pids+=("$!")

for _ in {1..60}; do
  health="$(curl -fsS http://127.0.0.1:8090/health 2>/dev/null || true)"
  printf '%s' "$health" | grep -Eq '"processors_available"[[:space:]]*:[[:space:]]*1' && break
  sleep 1
done
printf '%s' "$health" | grep -Eq '"processors_available"[[:space:]]*:[[:space:]]*1' || { echo "Processor failed to register" >&2; exit 1; }

dns-sd -R "WakeOnCue Gateway" _wakeoncue._tcp local. 8090 \
  "protocol=1" "host=$host_name" "port=8090" "scheme=http" >> "$bonjour_log" 2>&1 &
child_pids+=("$!")
printf 'http://%s:8090\n' "$host_name" > "$runtime_directory/local-url"
echo "WakeOnCue LAN Gateway: http://$host_name:8090"
echo "Keep this terminal open while recording."
while true; do sleep 5; done
