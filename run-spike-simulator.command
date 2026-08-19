#!/bin/zsh

# BabyPlayer 技术 Spike 一键运行脚本。
# 作用：构建、启动 Apple TV 1080p 模拟器、安装并启动 BabyPlayer。
# 运行方式：在 Finder 中双击本文件，或在终端执行 ./run-spike-simulator.command。
# 【MODIFIED】2026-08-19：为非开发者提供自动构建、安装和启动流程。

set -euo pipefail

project_root="${0:A:h}"
developer_dir="/Applications/Xcode.app/Contents/Developer"
derived_data="${project_root}/.derivedData"

cd "$project_root"

echo "正在构建 BabyPlayer Spike..."

# 自动查找 1080p Apple TV 模拟器，避免模拟器被重建后旧 UDID 失效。
simulator_udid="$(
  DEVELOPER_DIR="$developer_dir" xcrun simctl list devices available --json |
    /usr/bin/python3 -c '
import json
import sys

devices = json.load(sys.stdin)["devices"]
preferred_name = "Apple TV 4K (3rd generation) (at 1080p)"
matches = [
    device
    for runtime_devices in devices.values()
    for device in runtime_devices
    if device.get("name") == preferred_name and device.get("isAvailable", True)
]
print(matches[0]["udid"] if matches else "")
'
)"

if [[ -z "$simulator_udid" ]]; then
  echo "没有找到 Apple TV 4K 1080p 模拟器，请先在 Xcode 中安装 tvOS Simulator。"
  exit 1
fi

DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project BabyPlayer.xcodeproj \
  -scheme BabyPlayer \
  -configuration Debug \
  -destination "platform=tvOS Simulator,id=${simulator_udid}" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build

simulator_state="$(
  DEVELOPER_DIR="$developer_dir" xcrun simctl list devices --json |
    /usr/bin/python3 -c 'import json, sys; d=json.load(sys.stdin); u=sys.argv[1]; print(next((x["state"] for group in d["devices"].values() for x in group if x["udid"] == u), "Unknown"))' "$simulator_udid"
)"

if [[ "$simulator_state" != "Booted" ]]; then
  DEVELOPER_DIR="$developer_dir" xcrun simctl boot "$simulator_udid" 2>/dev/null || true
fi

DEVELOPER_DIR="$developer_dir" xcrun simctl bootstatus "$simulator_udid" -b
DEVELOPER_DIR="$developer_dir" xcrun simctl install "$simulator_udid" \
  "${derived_data}/Build/Products/Debug-appletvsimulator/BabyPlayer.app"
DEVELOPER_DIR="$developer_dir" xcrun simctl launch \
  --terminate-running-process \
  "$simulator_udid" \
  com.wufengyu.BabyPlayer

open -a Simulator
echo
echo "BabyPlayer Spike 已启动。"
echo "如果 Jellyfin 未运行，请先打开 /Applications/Jellyfin.app。"
