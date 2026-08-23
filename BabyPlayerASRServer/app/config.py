"""
BabyPlayerASRServer/app/config.py

用途：读取 BabyPlayer 独立 ASR 服务配置。
主要功能：
1. 读取独立 Bearer Token 与腾讯 ASR 配置。
2. 固定月度额度、上传大小、并发与限流参数。
3. 判断鉴权和腾讯 ASR 是否已完成配置。
最近修改：2026-08-23 【MODIFIED】按冻结版本 B 删除 DeepSeek/LLM 配置，只保留腾讯 ASR。
"""

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


BASE_DIR = Path(__file__).resolve().parents[1]
load_dotenv(BASE_DIR / ".env")


# 【MODIFIED】配置占位符检测只服务于 BabyPlayer Token 与腾讯 ASR Secret，不读取其他产品 Secret。
def _placeholder(value: str) -> bool:
    """判断配置值是否仍为空或为可提交的 XX 占位符；无副作用。"""
    normalized = value.strip().upper()
    return not normalized or normalized == "XX" or normalized.startswith("XX_")


@dataclass(frozen=True)
class Settings:
    """BabyPlayer 独立 ASR 服务的只读配置集合。"""

    api_token: str = os.getenv("BABYPLAYER_API_TOKEN", "XX_BABYPLAYER_API_TOKEN")
    app_id: str = os.getenv("TENCENT_ASR_APP_ID", "XX_APP_ID")
    secret_id: str = os.getenv("TENCENT_ASR_SECRET_ID", "XX_SECRET_ID")
    secret_key: str = os.getenv("TENCENT_ASR_SECRET_KEY", "XX_SECRET_KEY")
    endpoint: str = os.getenv("TENCENT_ASR_ENDPOINT", "https://asr.cloud.tencent.com")
    engine_type: str = os.getenv("TENCENT_ASR_ENGINE_TYPE", "16k_en")
    monthly_limit_seconds: int = int(
        os.getenv("TENCENT_ASR_MONTHLY_LIMIT_SECONDS", "18000")
    )
    max_audio_seconds: int = int(os.getenv("TENCENT_ASR_MAX_AUDIO_SECONDS", "120"))
    max_audio_bytes: int = int(os.getenv("TENCENT_ASR_MAX_AUDIO_BYTES", "12582912"))
    timeout_seconds: float = float(os.getenv("TENCENT_ASR_TIMEOUT_SECONDS", "30"))
    max_concurrency: int = int(os.getenv("TENCENT_ASR_MAX_CONCURRENCY", "2"))
    requests_per_minute: int = int(
        os.getenv("TENCENT_ASR_REQUESTS_PER_MINUTE", "3")
    )
    analysis_version: str = os.getenv("ASR_ANALYSIS_VERSION", "babyplayer-asr-v1")
    database_path: str = os.getenv(
        "DATABASE_PATH", str(BASE_DIR / "babyplayer-asr.sqlite3")
    )
    product_env: str = os.getenv("PRODUCT_ENV", "development")

    @property
    def auth_enabled(self) -> bool:
        """返回独立 BabyPlayer Bearer Token 是否可用；不修改配置。"""
        return not _placeholder(self.api_token)

    @property
    def provider_enabled(self) -> bool:
        """返回腾讯 ASR 所需三项凭据是否均已配置；不显示任何 Secret。"""
        return not any(_placeholder(value) for value in (
            self.app_id, self.secret_id, self.secret_key,
        ))


settings = Settings()
