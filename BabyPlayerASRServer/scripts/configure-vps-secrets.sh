#!/usr/bin/env bash
# Interactive helper: secrets are read without echo and never passed in command arguments.
set -Eeuo pipefail

env_file="/opt/babyplayer-asr/.env"
[[ "${EUID}" -eq 0 ]] || { echo "Run through sudo." >&2; exit 1; }
[[ -f "${env_file}" ]] || { echo "Missing ${env_file}. Deploy first." >&2; exit 1; }

read -r -p "Tencent ASR AppID: " app_id
read -r -s -p "Tencent ASR SecretId: " secret_id
echo
read -r -s -p "Tencent ASR SecretKey: " secret_key
echo
read -r -s -p "Independent BabyPlayer API token (32+ chars): " api_token
echo
read -r -s -p "DeepSeek API key for lyrics text refinement: " deepseek_api_key
echo

[[ "${app_id}" =~ ^[0-9]+$ ]] || { echo "AppID must contain digits only." >&2; exit 1; }
[[ ${#secret_id} -ge 16 && ${#secret_key} -ge 16 && ${#api_token} -ge 32 && ${#deepseek_api_key} -ge 16 ]] || {
  echo "One or more secret values are missing or too short." >&2
  exit 1
}
for value in "${secret_id}" "${secret_key}" "${api_token}" "${deepseek_api_key}"; do
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* && "${value}" != *"|"* \
      && "${value}" != *"&"* && "${value}" != *"\\"* ]] || {
    echo "Secret contains an unsupported character." >&2
    exit 1
  }
done

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
set_value TENCENT_ASR_SECRET_ID "${secret_id}"
set_value TENCENT_ASR_SECRET_KEY "${secret_key}"
set_value BABYPLAYER_API_TOKEN "${api_token}"
set_value DEEPSEEK_API_KEY "${deepseek_api_key}"
chown root:babyplayer-asr "${env_file}"
chmod 0640 "${env_file}"
systemctl restart babyplayer-asr.service
curl --fail --silent http://127.0.0.1:8011/health
echo
echo "Configured without printing secret values. Put the BabyPlayer token in the local Xcode secrets file; never commit it."
