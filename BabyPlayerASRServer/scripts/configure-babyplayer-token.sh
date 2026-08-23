#!/usr/bin/env bash
# Rotate only the private BabyPlayer API token; Tencent and DeepSeek keys are untouched.
set -Eeuo pipefail

env_file="/opt/babyplayer-asr/.env"
[[ "${EUID}" -eq 0 ]] || { echo "Run through sudo." >&2; exit 1; }
[[ -f "${env_file}" ]] || { echo "Missing ${env_file}. Deploy first." >&2; exit 1; }

read -r -s -p "New private BabyPlayer API token (32+ chars): " api_token
echo
[[ ${#api_token} -ge 32 ]] || {
  echo "Token is missing or too short." >&2
  exit 1
}
[[ "${api_token}" != *$'\n'* && "${api_token}" != *$'\r'* \
    && "${api_token}" != *"|"* && "${api_token}" != *"&"* \
    && "${api_token}" != *"\\"* ]] || {
  echo "Token contains an unsupported character." >&2
  exit 1
}

cp -p "${env_file}" "${env_file}.before-token-$(date -u +%Y%m%dT%H%M%SZ)"
if grep -q '^BABYPLAYER_API_TOKEN=' "${env_file}"; then
  sed -i "s|^BABYPLAYER_API_TOKEN=.*|BABYPLAYER_API_TOKEN=${api_token}|" "${env_file}"
else
  printf '\nBABYPLAYER_API_TOKEN=%s\n' "${api_token}" >> "${env_file}"
fi
chown root:babyplayer-asr "${env_file}"
chmod 0640 "${env_file}"
systemctl restart babyplayer-asr.service
for attempt in {1..20}; do
  if curl --fail --silent --max-time 2 http://127.0.0.1:8011/health; then
    echo
    echo "BabyPlayer API token rotated without printing the token."
    exit 0
  fi
  sleep 0.5
done
echo "Service did not become healthy after restart; token was written, but health must be checked manually." >&2
exit 1
