#!/usr/bin/env bash
# Configure only the lyrics-refiner credential without touching Tencent ASR settings.
set -Eeuo pipefail

env_file="/opt/babyplayer-asr/.env"
[[ "${EUID}" -eq 0 ]] || { echo "Run through sudo." >&2; exit 1; }
[[ -f "${env_file}" ]] || { echo "Missing ${env_file}. Deploy first." >&2; exit 1; }

read -r -s -p "DeepSeek API key for lyrics text refinement: " deepseek_api_key
echo
[[ ${#deepseek_api_key} -ge 16 ]] || {
  echo "DeepSeek API key is missing or too short." >&2
  exit 1
}
[[ "${deepseek_api_key}" != *$'\n'* && "${deepseek_api_key}" != *$'\r'* \
    && "${deepseek_api_key}" != *"|"* && "${deepseek_api_key}" != *"&"* \
    && "${deepseek_api_key}" != *"\\"* ]] || {
  echo "API key contains an unsupported character." >&2
  exit 1
}

cp -p "${env_file}" "${env_file}.before-deepseek-$(date -u +%Y%m%dT%H%M%SZ)"
if grep -q '^DEEPSEEK_API_KEY=' "${env_file}"; then
  sed -i "s|^DEEPSEEK_API_KEY=.*|DEEPSEEK_API_KEY=${deepseek_api_key}|" "${env_file}"
else
  printf '\nDEEPSEEK_API_KEY=%s\n' "${deepseek_api_key}" >> "${env_file}"
fi
chown root:babyplayer-asr "${env_file}"
chmod 0640 "${env_file}"
systemctl restart babyplayer-asr.service
curl --fail --silent http://127.0.0.1:8011/health
echo
echo "DeepSeek lyrics refiner configured without printing the API key."
