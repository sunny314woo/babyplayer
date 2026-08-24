#!/usr/bin/env bash
set -euo pipefail

# 【MODIFIED】仅在 Mac 启动开发服务；复用现有 .env 密钥，强制隔离本地 SQLite 与过程文件。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SERVER_DIR}"
if [[ ! -x .venv/bin/uvicorn ]]; then
  echo "请先在 BabyPlayerASRServer 中创建 .venv 并安装 requirements.txt" >&2
  exit 1
fi

export DATABASE_PATH="${SERVER_DIR}/babyplayer-asr.local.sqlite3"
export DEVELOPMENT_ARTIFACTS_DIRECTORY="${SERVER_DIR}/LyricsTestOutputs"
export PRODUCT_ENV="development"
# 【MODIFIED】只向本地任务开放常见媒体目录；可在启动前用 LOCAL_MEDIA_ROOTS 覆盖。
LOCAL_USER_ROOT="${HOME}"
export LOCAL_MEDIA_ROOTS="${LOCAL_MEDIA_ROOTS:-${LOCAL_USER_ROOT}/Music:${LOCAL_USER_ROOT}/Movies:${LOCAL_USER_ROOT}/Downloads}"
export LOCAL_FFMPEG_PATH="${LOCAL_FFMPEG_PATH:-/Applications/Jellyfin.app/Contents/MacOS/ffmpeg}"

exec .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8011
