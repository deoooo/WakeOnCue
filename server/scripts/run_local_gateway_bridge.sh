#!/bin/bash

set -euo pipefail

# Hot-deployment bridge for a legacy loopback-only Gateway. It preserves the
# currently running Cloudflare Quick Tunnel and exposes that same Gateway on a
# separate LAN port until the main stack can be restarted with 0.0.0.0 binding.
bridge_port="${WAKEONCUE_REALTIME_LAN_BRIDGE_PORT:-8091}"
gateway_port="${WAKEONCUE_REALTIME_PORT:-8090}"
ncat_binary="/opt/homebrew/bin/ncat"
local_host_name="${WAKEONCUE_REALTIME_LAN_HOST:-$(/usr/sbin/scutil --get LocalHostName).local}"

if [[ ! -x "$ncat_binary" ]]; then
  echo "ncat is required at $ncat_binary" >&2
  exit 1
fi

child_pids=()
cleanup() {
  for child_pid in "${child_pids[@]:-}"; do
    kill "$child_pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

"$ncat_binary" \
  --listen \
  --keep-open \
  --source-port "$bridge_port" \
  --sh-exec "$ncat_binary 127.0.0.1 $gateway_port" &
child_pids+=("$!")

/usr/bin/dns-sd -R \
  "WakeOnCue Gateway" \
  "_wakeoncue._tcp" \
  "local." \
  "$bridge_port" \
  "protocol=1" \
  "host=$local_host_name" \
  "port=$bridge_port" \
  "scheme=http" &
child_pids+=("$!")

while true; do
  for child_pid in "${child_pids[@]}"; do
    if ! kill -0 "$child_pid" 2>/dev/null; then
      echo "WakeOnCue local Gateway bridge stopped unexpectedly" >&2
      exit 1
    fi
  done
  sleep 5
done
