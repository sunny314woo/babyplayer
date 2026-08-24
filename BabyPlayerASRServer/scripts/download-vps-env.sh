#!/usr/bin/env bash
# Download BabyPlayer's private VPS environment without printing or committing it.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "${script_dir}/.." && pwd)"
remote_host="${1:-wisteria}"
remote_source="/opt/babyplayer-asr/.env"
remote_export="/home/wisteria/.babyplayer-asr-env-export"
local_env="${server_dir}/.env"
local_download="$(mktemp "${server_dir}/.env.download.XXXXXX")"

cleanup() {
  rm -f "${local_download}"
  ssh -o BatchMode=yes "${remote_host}" "rm -f '${remote_export}'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! git -C "${server_dir}" check-ignore -q -- .env; then
  echo "Refusing to download: BabyPlayerASRServer/.env is not ignored by Git." >&2
  exit 1
fi

echo "VPS sudo authorization is required to read only ${remote_source}."
ssh -t "${remote_host}" \
  "sudo install -m 0600 -o wisteria -g wisteria '${remote_source}' '${remote_export}'"
scp -q "${remote_host}:${remote_export}" "${local_download}"

[[ -s "${local_download}" ]] || {
  echo "Downloaded environment is empty." >&2
  exit 1
}
for required_key in BABYPLAYER_API_TOKEN TENCENT_ASR_SECRET_ID \
  TENCENT_ASR_SECRET_KEY DEEPSEEK_API_KEY; do
  grep -Eq "^${required_key}=.+$" "${local_download}" || {
    echo "Downloaded environment is missing ${required_key}." >&2
    exit 1
  }
done

if [[ -f "${local_env}" ]]; then
  backup_path="${local_env}.backup-$(date -u +%Y%m%dT%H%M%SZ)"
  install -m 0600 "${local_env}" "${backup_path}"
  echo "Previous local environment backed up without printing its contents."
fi
install -m 0600 "${local_download}" "${local_env}"
rm -f "${local_download}"
ssh -o BatchMode=yes "${remote_host}" "rm -f '${remote_export}'"
trap - EXIT

echo "Downloaded to BabyPlayerASRServer/.env (mode 0600, ignored by Git)."
