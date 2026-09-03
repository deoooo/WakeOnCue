#!/bin/bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi
device_id="${1:-}"
if [[ -z "$device_id" ]]; then
  echo "Usage: $0 <device-id-or-udid>" >&2
  xcrun devicectl list devices
  exit 2
fi

script_directory="$(cd "$(dirname "$0")" && pwd)"
cd "$script_directory"
xcodegen generate
build_args=(
  -project WakeOnCue.xcodeproj -scheme WakeOnCue -configuration Debug
  -destination "id=$device_id" -allowProvisioningUpdates
)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  build_args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
xcodebuild build "${build_args[@]}"
app_path="$(xcodebuild -project WakeOnCue.xcodeproj -scheme WakeOnCue -configuration Debug -showBuildSettings \
  | awk -F ' = ' '/ TARGET_BUILD_DIR = / {dir=$2} / WRAPPER_NAME = / {name=$2} END {print dir "/" name}')"
xcrun devicectl device install app --device "$device_id" "$app_path"
echo "Installed WakeOnCue on $device_id. Open it once to grant microphone and local-network permissions."
