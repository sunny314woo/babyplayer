#!/bin/zsh

# BabyPlayer 手动一键签名、构建、安装并启动到 Apple TV。
# 脚本使用 Xcode 的 Automatic Signing，不把证书、私钥或密码写入项目。
# 首次配对、Apple ID 登录、电视 PIN 和系统弹窗仍需人工完成。

set -Eeuo pipefail
setopt NULL_GLOB

script_dir="${0:A:h}"
project_root="${script_dir:h}"
project_path="${project_root}/BabyPlayer.xcodeproj"
scheme="BabyPlayer"
configuration="Release"
bundle_id="${BABYPLAYER_BUNDLE_ID:-com.wufengyu.BabyPlayer}"
team_id="${BABYPLAYER_TEAM_ID:-RD2D85V483}"
device_selector="${APPLE_TV_DEVICE:-}"
preferred_device_name="${APPLE_TV_NAME:-客厅}"
derived_data="${BABYPLAYER_DERIVED_DATA:-${project_root}/.derivedData-apple-tv}"

usage() {
  cat <<'EOF'
用法：
  ./Scripts/deploy-to-apple-tv.command [选项]

作用：
  使用 Xcode Automatic Signing 重新签名 BabyPlayer，构建 tvOS App，
  安装到已配对的实体 Apple TV，并启动应用。

选项：
  --device <名称或标识>  指定 Apple TV 名称、CoreDevice ID 或 UDID
  --debug                使用 Debug 配置（默认是 Release）
  --no-launch            安装完成后不启动应用
  --help                 显示本帮助

可选环境变量：
  APPLE_TV_NAME           默认目标名称，默认：客厅
  APPLE_TV_DEVICE         等价于 --device
  BABYPLAYER_TEAM_ID      Xcode Development Team，默认：RD2D85V483
  BABYPLAYER_BUNDLE_ID    Bundle ID，默认：com.wufengyu.BabyPlayer
  BABYPLAYER_DERIVED_DATA 构建目录，默认：.derivedData-apple-tv
  DEVELOPER_DIR           Xcode.app 或其 Contents/Developer 路径

示例：
  ./Scripts/deploy-to-apple-tv.command
  ./Scripts/deploy-to-apple-tv.command --device "客厅"
  ./Scripts/deploy-to-apple-tv.command --debug --no-launch
EOF
}

die() {
  echo "错误：$*">&2
  exit 1
}

warn() {
  echo "警告：$*">&2
}

no_launch=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || die "--device 需要一个名称、CoreDevice ID 或 UDID。"
      device_selector="$2"
      shift 2
      ;;
    --debug)
      configuration="Debug"
      shift
      ;;
    --no-launch)
      no_launch=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "未知选项：$1"
      ;;
  esac
done

[[ -d "$project_path" ]] || die "找不到工程：$project_path"

resolve_developer_dir() {
  local requested="${DEVELOPER_DIR:-}"
  local selected=""
  local candidate=""

  if [[ -n "$requested" ]]; then
    if [[ "$requested" == *.app ]]; then
      requested="${requested}/Contents/Developer"
    fi
    [[ -x "${requested}/usr/bin/xcodebuild" ]] || \
      die "DEVELOPER_DIR 不是完整 Xcode 的开发者目录：${requested}"
    print -r -- "$requested"
    return
  fi

  selected="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [[ -x "${selected}/usr/bin/xcodebuild" ]]; then
    print -r -- "$selected"
    return
  fi

  for candidate in \
    "/Applications/Xcode.app/Contents/Developer" \
    "/Applications/Xcode-beta.app/Contents/Developer" \
    /Applications/Xcode-*.app/Contents/Developer; do
    if [[ -x "${candidate}/usr/bin/xcodebuild" ]]; then
      print -r -- "$candidate"
      return
    fi
  done

  die "找不到完整 Xcode。请先安装 Xcode，并在 Xcode → Settings → Locations 中选择命令行工具；也可以执行：DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/deploy-to-apple-tv.command"
}

developer_dir="$(resolve_developer_dir)"
export DEVELOPER_DIR="$developer_dir"

xcodebuild_path="${developer_dir}/usr/bin/xcodebuild"
xcrun_path="/usr/bin/xcrun"
codesign_path="/usr/bin/codesign"
security_path="/usr/bin/security"
plutil_path="/usr/bin/plutil"
python3_path="$(command -v python3 || true)"

[[ -x "$xcodebuild_path" ]] || die "Xcode 工具不存在：$xcodebuild_path"
[[ -x "$xcrun_path" ]] || die "Xcode 工具不存在：$xcrun_path"
[[ -x "$codesign_path" ]] || die "找不到 codesign。"
[[ -x "$security_path" ]] || die "找不到 security。"
[[ -x "$plutil_path" ]] || die "找不到 plutil。"
[[ -n "$python3_path" ]] || die "找不到 python3；脚本需要它解析 devicectl 的设备列表。"

echo "BabyPlayer Apple TV 部署开始"
echo "Xcode：$($xcodebuild_path -version | tr '\n' ' ')"
echo "工程：$project_path"
echo "配置：$configuration"
echo "Bundle ID：$bundle_id"
echo "Team：$team_id"

device_json="$(mktemp "${TMPDIR:-/tmp}/babyplayer-devices.XXXXXX.json")"
profile_plist=""
cleanup() {
  rm -f "$device_json"
  if [[ -n "$profile_plist" ]]; then
    rm -f "$profile_plist"
  fi
}
trap cleanup EXIT

echo "正在查找已配对的 tvOS 设备……"
if ! "$xcrun_path" devicectl list devices --timeout 15 --json-output "$device_json" >/dev/null; then
  die "devicectl 无法读取设备列表。请确认 Apple TV 已开机、与 Mac 在同一局域网，并已在 Xcode 中配对。"
fi

if ! selected_device="$( "$python3_path" - "$device_json" "$device_selector" "$preferred_device_name" <<'PY'
import json
import sys

json_path, selector, preferred_name = sys.argv[1:]
with open(json_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

devices = payload.get("result", {}).get("devices", [])

def text(value):
    return "" if value is None else str(value)

def normal(value):
    return text(value).strip().casefold()

tv_devices = []
for device in devices:
    hardware = device.get("hardwareProperties") or {}
    if normal(hardware.get("platform")) not in {"tvos", "tv os"}:
        continue
    connection = device.get("connectionProperties") or {}
    properties = device.get("deviceProperties") or {}
    tv_devices.append({
        "identifier": text(device.get("identifier")),
        "udid": text(hardware.get("udid")),
        "name": text(properties.get("name")),
        "serial": text(hardware.get("serialNumber")),
        "pairing": text(connection.get("pairingState")),
        "tunnel": text(connection.get("tunnelState")),
    })

def matches(device, value):
    wanted = normal(value)
    return wanted and wanted in {
        normal(device["identifier"]),
        normal(device["udid"]),
        normal(device["name"]),
        normal(device["serial"]),
    }

selected = None
if selector:
    candidates = [device for device in tv_devices if matches(device, selector)]
    if len(candidates) == 1:
        selected = candidates[0]
else:
    candidates = [device for device in tv_devices
                  if normal(device["name"]) == normal(preferred_name)]
    if len(candidates) == 1:
        selected = candidates[0]
    elif len(tv_devices) == 1:
        selected = tv_devices[0]

if selected is None:
    if not tv_devices:
        print("未发现已配对的 tvOS 设备。")
    elif selector:
        print("没有找到匹配的 tvOS 设备：" + selector)
    else:
        print("发现多个 tvOS 设备，无法自动选择；请使用 --device 指定：")
    for device in tv_devices:
        print("  名称={}  CoreDeviceID={}  UDID={}  配对={}  通道={}".format(
            device["name"] or "(未命名)",
            device["identifier"] or "(无)",
            device["udid"] or "(无)",
            device["pairing"] or "(未知)",
            device["tunnel"] or "(未知)",
        ))
    sys.exit(2)

core_id = selected["identifier"] or selected["udid"]
destination_id = selected["udid"] or selected["identifier"]
if not core_id or not destination_id:
    print("选中的设备缺少可用的设备标识。")
    sys.exit(3)

print("\t".join([
    core_id,
    destination_id,
    selected["name"] or preferred_name or selector,
    selected["pairing"] or "unknown",
    selected["tunnel"] or "unknown",
]))
PY
)"; then
  echo "$selected_device" >&2
  exit 1
fi

IFS=$'\t' read -r device_id destination_id device_name pairing_state tunnel_state <<< "$selected_device"
echo "目标：${device_name}"
echo "设备标识：${device_id}"
echo "配对状态：${pairing_state}；连接状态：${tunnel_state}"

if [[ "$pairing_state" != "" && "$pairing_state" != "paired" ]]; then
  warn "设备当前不是 paired 状态；如果安装失败，请先在 Xcode 的 Devices and Simulators 中完成配对。"
fi

echo "正在使用 Automatic Signing 构建并重新签名……"
"$xcodebuild_path" \
  -project "$project_path" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "platform=tvOS,id=${destination_id}" \
  -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$team_id" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  build

app_path="${derived_data}/Build/Products/${configuration}-appletvos/${scheme}.app"
[[ -d "$app_path" ]] || die "构建成功但找不到 App 包：$app_path"

echo "正在验证签名……"
"$codesign_path" --verify --deep --strict --verbose=2 "$app_path"
echo "签名摘要："
"$codesign_path" -dvv "$app_path" 2>&1 | awk '/^Identifier=|^TeamIdentifier=|^Authority=/' || true

for profile_path in \
  "${app_path}/embedded.mobileprovision" \
  "${app_path}/embedded.provisionprofile"; do
  if [[ -f "$profile_path" ]]; then
    profile_plist="$(mktemp "${TMPDIR:-/tmp}/babyplayer-profile.XXXXXX.plist")"
    if "$security_path" cms -D -i "$profile_path" > "$profile_plist" 2>/dev/null; then
      profile_name="$("$plutil_path" -extract Name raw -o - "$profile_plist" 2>/dev/null || true)"
      profile_expiration="$("$plutil_path" -extract ExpirationDate raw -o - "$profile_plist" 2>/dev/null || true)"
      echo "Provisioning Profile：${profile_name:-未命名}"
      echo "Profile 到期时间：${profile_expiration:-未知}"
    fi
    break
  fi
done

echo "签名后的 App 包：$app_path"
echo "正在安装到 Apple TV……"
"$xcrun_path" devicectl device install app \
  --device "$device_id" \
  --timeout 240 \
  "$app_path"

if [[ "$no_launch" == "true" ]]; then
  echo
  echo "BabyPlayer 已安装到 ${device_name}，按要求未启动。"
  exit 0
fi

echo "正在启动 BabyPlayer……"
if "$xcrun_path" devicectl device process launch \
  --terminate-existing \
  --device "$device_id" \
  "$bundle_id"; then
  echo
  echo "BabyPlayer 已重新签名、构建、安装并启动到 ${device_name}。"
else
  warn "App 已安装，但启动失败；请在 Apple TV 主屏幕手动打开，并检查设备连接状态。"
  exit 1
fi
