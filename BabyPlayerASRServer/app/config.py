import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


BASE_DIR = Path(__file__).resolve().parents[1]
load_dotenv(BASE_DIR / ".env")


def _placeholder(value: str) -> bool:
    normalized = value.strip().upper()
    return not normalized or normalized == "XX" or normalized.startswith("XX_")


@dataclass(frozen=True)
class Settings:
    api_token: str = os.getenv("BABYPLAYER_API_TOKEN", "XX_BABYPLAYER_API_TOKEN")
    app_id: str = os.getenv("TENCENT_ASR_APP_ID", "XX_APP_ID")
    secret_id: str = os.getenv("TENCENT_ASR_SECRET_ID", "XX_SECRET_ID")
    secret_key: str = os.getenv("TENCENT_ASR_SECRET_KEY", "XX_SECRET_KEY")
    deepseek_api_key: str = os.getenv("DEEPSEEK_API_KEY", "XX_DEEPSEEK_API_KEY")
    deepseek_endpoint: str = os.getenv(
        "DEEPSEEK_ENDPOINT", "https://api.deepseek.com/chat/completions"
    )
    deepseek_model: str = os.getenv("DEEPSEEK_MODEL", "deepseek-v4-flash")
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
        return not _placeholder(self.api_token)

    @property
    def provider_enabled(self) -> bool:
        return not any(_placeholder(value) for value in (
            self.app_id, self.secret_id, self.secret_key,
        ))

    @property
    def lyrics_refiner_enabled(self) -> bool:
        return not _placeholder(self.deepseek_api_key)


settings = Settings()
