#!/usr/bin/env bash
# Install an isolated Nginx vhost for player.wisteriasoftware.uk.
set -Eeuo pipefail

service_dir="/opt/babyplayer-asr"
source_file="${service_dir}/ops/nginx-babyplayer-asr.conf.example"
site_file="/etc/nginx/sites-available/babyplayer-asr"
enabled_file="/etc/nginx/sites-enabled/babyplayer-asr"
backup_file="${site_file}.before-$(date -u +%Y%m%dT%H%M%SZ)"

[[ "${EUID}" -eq 0 ]] || { echo "Run through sudo." >&2; exit 1; }
[[ -f "${source_file}" ]] || { echo "Missing ${source_file}. Deploy first." >&2; exit 1; }
[[ -f /etc/nginx/ssl/origin.pem && -f /etc/nginx/ssl/origin.key ]] || {
  echo "Missing the existing wildcard origin certificate." >&2
  exit 1
}

if [[ -f "${site_file}" ]]; then
  cp -p "${site_file}" "${backup_file}"
fi

install -m 0644 "${source_file}" "${site_file}"
ln -sfn "${site_file}" "${enabled_file}"

if ! nginx -t; then
  rm -f "${enabled_file}"
  if [[ -f "${backup_file}" ]]; then
    cp -p "${backup_file}" "${site_file}"
    ln -sfn "${site_file}" "${enabled_file}"
  else
    rm -f "${site_file}"
  fi
  echo "Nginx validation failed; previous configuration restored." >&2
  exit 1
fi

systemctl reload nginx
curl --fail --silent --insecure --noproxy '*' \
  --resolve player.wisteriasoftware.uk:443:127.0.0.1 \
  https://player.wisteriasoftware.uk/health
echo
echo "Nginx route ready: https://player.wisteriasoftware.uk"
