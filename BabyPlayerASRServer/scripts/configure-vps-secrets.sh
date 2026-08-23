#!/usr/bin/env bash
# BabyPlayerASRServer/scripts/configure-vps-secrets.sh
# 用途：交互式写入 BabyPlayer 独立 ASR 所需凭据，所有敏感输入均关闭终端回显。
# 主要功能：校验输入、备份现有 .env、更新腾讯 ASR 与 BabyPlayer 独立 Token、重启独立服务。
# 最近修改：2026-08-23 【MODIFIED】删除已停用的 LLM 凭据配置，保持服务职责仅限 ASR。
set -Eeuo pipefail

env_file="/opt/babyplayer-asr/.env"
[[ "${EUID}" -eq 0 ]] || { echo "Run through sudo." >&2; exit 1; }
[[ -f "${env_file}" ]] || { echo "Missing ${env_file}. Deploy first." >&2; exit 1; }

read -r -p "Tencent ASR AppID: " app_id
read -r -s -p "Tencent ASR credential id: " credential_id
echo
read -r -s -p "Tencent ASR credential key: " credential_key
echo
read -r -s -p "Independent BabyPlayer API token (32+ chars): " api_token
echo

[[ "${app_id}" =~ ^[0-9]+$ ]] || { echo "AppID must contain digits only." >&2; exit 1; }
[[ ${#credential_id} -ge 16 && ${#credential_key} -ge 16 && ${#api_token} -ge 32 ]] || {
  echo "One or more secret values are missing or too short." >&2
  exit 1
}
for value in "${credential_id}" "${credential_key}" "${api_token}"; do
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* && "${value}" != *"|"* \
      && "${value}" != *"&"* && "${value}" != *"\\"* ]] || {
    echo "Secret contains an unsupported character." >&2
    exit 1
  }
done

# 【MODIFIED】只更新 BabyPlayer ASR 自己的配置键；不会读取或修改其他产品配置。
set_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "${env_file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${env_file}"
  else
    printf '\n%s=%s\n' "${key}" "${value}" >> "${env_file}"
  fi
}

cp -p "${env_file}" "${env_file}.before-asr-$(date -u +%Y%m%dT%H%M%SZ)"
set_value TENCENT_ASR_APP_ID "${app_id}"
set_value TENCENT_ASR_SECRET_ID "${credential_id}"
set_value TENCENT_ASR_SECRET_KEY "${credential_key}"
set_value BABYPLAYER_API_TOKEN "${api_token}"
chown root:babyplayer-asr "${env_file}"
chmod 0640 "${env_file}"
systemctl restart babyplayer-asr.service
curl --fail --silent http://127.0.0.1:8011/health
echo
echo "Configured without printing sensitive values. Put the BabyPlayer token in the local Xcode secrets file; never commit it."
