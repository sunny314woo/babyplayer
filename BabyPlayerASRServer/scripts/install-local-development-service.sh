#!/usr/bin/env bash
set -euo pipefail

# 把 Mac 本地分析服务注册为当前登录用户的 LaunchAgent。
# 不复制或输出 .env；launchd 仍通过 start-local-development.sh 从项目目录加载配置。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_PATH="${SERVER_DIR}/launchd/uk.wisteriasoftware.babyplayer-asr-local.plist.template"
LABEL="uk.wisteriasoftware.babyplayer-asr-local"
DOMAIN="gui/$(id -u)"
AGENT_DIRECTORY="${HOME}/Library/LaunchAgents"
AGENT_PATH="${AGENT_DIRECTORY}/${LABEL}.plist"
LOG_DIRECTORY="${HOME}/Library/Logs/BabyPlayerASR"
START_SCRIPT="${SERVER_DIR}/scripts/start-local-development.sh"
STDOUT_LOG="${LOG_DIRECTORY}/local-service.stdout.log"
STDERR_LOG="${LOG_DIRECTORY}/local-service.stderr.log"

if [[ ! -f "${TEMPLATE_PATH}" || ! -x "${START_SCRIPT}" ]]; then
  echo "BabyPlayer 本地服务文件不完整" >&2
  exit 1
fi

if [[ ! -x "${SERVER_DIR}/.venv/bin/uvicorn" ]]; then
  echo "请先在 BabyPlayerASRServer 中创建 .venv 并安装 requirements-local-quality.txt" >&2
  exit 1
fi

if ! "${SERVER_DIR}/.venv/bin/python" -c \
  'import audio_separator, faster_whisper' >/dev/null 2>&1; then
  echo "Mac 质量依赖不完整；请先运行 pip install -r requirements-local-quality.txt" >&2
  exit 1
fi

MODEL_DIRECTORY="${SERVER_DIR}/.cache/audio-separator-models"
MODEL_FILENAME="Kim_Vocal_2.onnx"
if [[ ! -f "${MODEL_DIRECTORY}/${MODEL_FILENAME}" ]]; then
  echo "Mac 人声分离模型未就绪；请先运行：" >&2
  echo ".venv/bin/audio-separator -m ${MODEL_FILENAME} --model_file_dir .cache/audio-separator-models --download_model_only" >&2
  exit 1
fi

mkdir -p "${AGENT_DIRECTORY}" "${LOG_DIRECTORY}"
temporary_plist="$(mktemp "${TMPDIR:-/tmp}/babyplayer-asr-launchd.XXXXXX")"
trap 'rm -f "${temporary_plist}"' EXIT

escape_replacement() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

sed \
  -e "s|__START_SCRIPT__|$(escape_replacement "${START_SCRIPT}")|g" \
  -e "s|__SERVER_DIR__|$(escape_replacement "${SERVER_DIR}")|g" \
  -e "s|__STDOUT_LOG__|$(escape_replacement "${STDOUT_LOG}")|g" \
  -e "s|__STDERR_LOG__|$(escape_replacement "${STDERR_LOG}")|g" \
  "${TEMPLATE_PATH}" > "${temporary_plist}"

plutil -lint "${temporary_plist}" >/dev/null
install -m 600 "${temporary_plist}" "${AGENT_PATH}"

launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
bootstrapped=false
for _ in {1..5}; do
  if launchctl bootstrap "${DOMAIN}" "${AGENT_PATH}" 2>/dev/null; then
    bootstrapped=true
    break
  fi
  sleep 0.5
done
if [[ "${bootstrapped}" != "true" ]]; then
  echo "LaunchAgent 注册失败；可用 launchctl bootstrap ${DOMAIN} ${AGENT_PATH} 重试" >&2
  exit 1
fi
launchctl enable "${DOMAIN}/${LABEL}"
launchctl kickstart -k "${DOMAIN}/${LABEL}"

for _ in {1..20}; do
  if curl --fail --silent --max-time 2 http://127.0.0.1:8011/health >/dev/null; then
    echo "BabyPlayer Mac 本地分析服务已安装并启动"
    echo "状态：launchctl print ${DOMAIN}/${LABEL}"
    echo "日志：${STDERR_LOG}"
    exit 0
  fi
  sleep 0.5
done

echo "LaunchAgent 已安装，但健康检查未通过；请查看 ${STDERR_LOG}" >&2
exit 1
