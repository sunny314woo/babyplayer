#!/usr/bin/env bash
# Run on the VPS: sudo bash deploy-vps-release.sh /home/wisteria/babyplayer-asr-release-TIMESTAMP
set -Eeuo pipefail

release_dir="${1:?Usage: sudo bash deploy-vps-release.sh /path/to/release}"
service_dir="/opt/babyplayer-asr"
data_dir="/var/lib/babyplayer-asr"
service_user="babyplayer-asr"
backup_dir="/opt/babyplayer-backups/asr-before-$(date -u +%Y%m%dT%H%M%SZ)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script through sudo." >&2
  exit 1
fi

for required in requirements.txt app/main.py ops/babyplayer-asr.service .env.example; do
  [[ -f "${release_dir}/${required}" ]] || {
    echo "Missing required file: ${release_dir}/${required}" >&2
    exit 1
  }
done

if ! id "${service_user}" >/dev/null 2>&1; then
  useradd --system --home "${service_dir}" --shell /usr/sbin/nologin "${service_user}"
fi
mkdir -p "${service_dir}" "${data_dir}" "${backup_dir}"

if [[ -d "${service_dir}/app" ]]; then
  tar -C "${service_dir}" --exclude='./.venv' --exclude='./.env' \
    -czf "${backup_dir}/source.tgz" .
fi
if [[ -f "${service_dir}/.env" ]]; then
  cp -p "${service_dir}/.env" "${backup_dir}/.env"
fi
if [[ -f "${data_dir}/babyplayer-asr.sqlite3" ]]; then
  cp -p "${data_dir}/babyplayer-asr.sqlite3" "${backup_dir}/babyplayer-asr.sqlite3"
fi
chmod -R go= "${backup_dir}"

rsync -a --delete \
  --exclude '.env' \
  --exclude '.venv' \
  --exclude '__pycache__' \
  --exclude '.pytest_cache' \
  "${release_dir}/" "${service_dir}/"

python3 -m venv "${service_dir}/.venv"
"${service_dir}/.venv/bin/pip" install --quiet --upgrade pip
"${service_dir}/.venv/bin/pip" install --quiet -r "${service_dir}/requirements.txt"

if [[ ! -f "${service_dir}/.env" ]]; then
  install -m 0600 "${service_dir}/.env.example" "${service_dir}/.env"
  echo "Created ${service_dir}/.env with safe XX placeholders. ASR remains disabled."
fi

chown -R root:"${service_user}" "${service_dir}"
chmod -R u=rwX,g=rX,o= "${service_dir}"
chmod 0640 "${service_dir}/.env"
chown -R "${service_user}":"${service_user}" "${data_dir}"
chmod 0750 "${data_dir}"

cd "${service_dir}"
"${service_dir}/.venv/bin/python" -m pytest -q -p no:cacheprovider
install -m 0644 "${service_dir}/ops/babyplayer-asr.service" \
  /etc/systemd/system/babyplayer-asr.service
systemctl daemon-reload
systemctl enable babyplayer-asr.service
systemctl restart babyplayer-asr.service
health_ready=false
for _ in {1..20}; do
  if systemctl is-active --quiet babyplayer-asr.service && \
    curl --fail --silent http://127.0.0.1:8011/health; then
    health_ready=true
    break
  fi
  sleep 0.5
done
if [[ "${health_ready}" != true ]]; then
  systemctl status babyplayer-asr.service --no-pager -l >&2 || true
  journalctl -u babyplayer-asr.service -n 50 --no-pager >&2 || true
  exit 1
fi
echo
echo "Deployment complete. Backup: ${backup_dir}"
echo "If provider_configured is false, edit /opt/babyplayer-asr/.env and restart only babyplayer-asr.service."
