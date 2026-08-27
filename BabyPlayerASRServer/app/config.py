import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


BASE_DIR = Path(__file__).resolve().parents[1]
load_dotenv(BASE_DIR / ".env")


def _placeholder(value: str) -> bool:
    normalized = value.strip().upper()
    return not normalized or normalized == "XX" or normalized.startswith("XX_")


def _boolean(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _path_list(name: str) -> tuple[str, ...]:
    """读取由系统路径分隔符连接的目录列表；空值代表不允许本地文件分析。"""
    return tuple(
        value.strip()
        for value in os.getenv(name, "").split(os.pathsep)
        if value.strip()
    )


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
    lyrics_reconciliation_version: str = os.getenv(
        "LYRICS_RECONCILIATION_VERSION", "babyplayer-lyrics-d3-v1"
    )
    lyrics_web_search_enabled: bool = _boolean("LYRICS_WEB_SEARCH_ENABLED", True)
    lyrics_web_search_timeout_seconds: float = float(
        os.getenv("LYRICS_WEB_SEARCH_TIMEOUT_SECONDS", "8")
    )
    lyrics_web_search_max_results: int = int(
        os.getenv("LYRICS_WEB_SEARCH_MAX_RESULTS", "3")
    )
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
    asr_timeline_version: str = os.getenv(
        "ASR_TIMELINE_VERSION", "mac-chunked-60s-overlap-5s-v1"
    )
    database_path: str = os.getenv(
        "DATABASE_PATH", str(BASE_DIR / "babyplayer-asr.sqlite3")
    )
    product_env: str = os.getenv("PRODUCT_ENV", "development")
    development_artifacts_directory: str = os.getenv(
        "DEVELOPMENT_ARTIFACTS_DIRECTORY", ""
    )
    # 与调试过程文件分开：这是可跨任务、跨服务重启复用的正式音频预处理缓存。
    local_preprocessed_audio_cache_directory: str = os.getenv(
        "LOCAL_PREPROCESSED_AUDIO_CACHE_DIRECTORY",
        str(BASE_DIR / ".cache" / "preprocessed-audio"),
    )
    # 完整媒体哈希只在源文件身份变化时重算，不与音频处理版本绑定。
    local_media_content_hash_cache_directory: str = os.getenv(
        "LOCAL_MEDIA_CONTENT_HASH_CACHE_DIRECTORY",
        str(BASE_DIR / ".cache" / "media-content-hashes"),
    )
    # 【MODIFIED】Mac 本地分析只允许读取显式白名单目录，不开放任意文件路径。
    local_media_roots: tuple[str, ...] = _path_list("LOCAL_MEDIA_ROOTS")
    local_ffmpeg_path: str = os.getenv(
        "LOCAL_FFMPEG_PATH", "/Applications/Jellyfin.app/Contents/MacOS/ffmpeg"
    )
    local_extraction_timeout_seconds: float = float(
        os.getenv("LOCAL_EXTRACTION_TIMEOUT_SECONDS", "180")
    )
    local_asr_chunk_seconds: float = float(
        os.getenv("LOCAL_ASR_CHUNK_SECONDS", "60")
    )
    local_asr_chunk_overlap_seconds: float = float(
        os.getenv("LOCAL_ASR_CHUNK_OVERLAP_SECONDS", "5")
    )
    # Local quality path: one lossless decode -> vocal stem -> VAD and Tencent chunks.
    # Production remains opt-in because it cannot read the Mac media paths.
    local_vocal_separation_enabled: bool = _boolean(
        "LOCAL_VOCAL_SEPARATION_ENABLED", False
    )
    local_vocal_separation_model: str = os.getenv(
        "LOCAL_VOCAL_SEPARATION_MODEL", "Kim_Vocal_2.onnx"
    )
    local_vocal_separation_model_directory: str = os.getenv(
        "LOCAL_VOCAL_SEPARATION_MODEL_DIRECTORY",
        str(BASE_DIR / ".cache" / "audio-separator-models"),
    )
    local_vocal_separation_version: str = os.getenv(
        "LOCAL_VOCAL_SEPARATION_VERSION",
        "python-audio-separator-0.44.5-kim-vocal-2-v1",
    )
    local_minimum_vocal_coverage: float = float(
        os.getenv("LOCAL_MINIMUM_VOCAL_COVERAGE", "0.03")
    )
    local_minimum_vocal_mean_probability: float = float(
        os.getenv("LOCAL_MINIMUM_VOCAL_MEAN_PROBABILITY", "0.05")
    )
    local_voice_activity_enabled: bool = _boolean(
        "LOCAL_VOICE_ACTIVITY_ENABLED", False
    )
    local_voice_activity_threshold: float = float(
        os.getenv("LOCAL_VOICE_ACTIVITY_THRESHOLD", "0.15")
    )
    local_voice_activity_minimum_suspicious_words: int = int(
        os.getenv("LOCAL_VOICE_ACTIVITY_MINIMUM_SUSPICIOUS_WORDS", "3")
    )
    local_voice_activity_maximum_low_coverage: float = float(
        os.getenv("LOCAL_VOICE_ACTIVITY_MAXIMUM_LOW_COVERAGE", "0.25")
    )
    # Sparse ASR is used only when VAD produced a trustworthy plan. Every planner
    # failure falls back to the existing complete-song chunk path.
    local_sparse_asr_enabled: bool = _boolean("LOCAL_SPARSE_ASR_ENABLED", True)
    local_voice_window_minimum_speech_seconds: float = float(
        os.getenv("LOCAL_VOICE_WINDOW_MINIMUM_SPEECH_SECONDS", "0.18")
    )
    local_voice_window_merge_gap_seconds: float = float(
        os.getenv("LOCAL_VOICE_WINDOW_MERGE_GAP_SECONDS", "2.0")
    )
    local_voice_window_padding_before_seconds: float = float(
        os.getenv("LOCAL_VOICE_WINDOW_PADDING_BEFORE_SECONDS", "1.5")
    )
    local_voice_window_padding_after_seconds: float = float(
        os.getenv("LOCAL_VOICE_WINDOW_PADDING_AFTER_SECONDS", "1.5")
    )
    local_voice_window_stable_body_gap_seconds: float = float(
        os.getenv("LOCAL_VOICE_WINDOW_STABLE_BODY_GAP_SECONDS", "4.0")
    )
    local_voice_window_stable_body_minimum_span_seconds: float = float(
        os.getenv("LOCAL_VOICE_WINDOW_STABLE_BODY_MINIMUM_SPAN_SECONDS", "10.0")
    )
    local_voice_window_stable_body_minimum_speech_seconds: float = float(
        os.getenv("LOCAL_VOICE_WINDOW_STABLE_BODY_MINIMUM_SPEECH_SECONDS", "6.0")
    )
    local_voice_window_stable_body_minimum_density: float = float(
        os.getenv("LOCAL_VOICE_WINDOW_STABLE_BODY_MINIMUM_DENSITY", "0.35")
    )
    local_voice_window_boundary_safety_seconds: float = float(
        os.getenv("LOCAL_VOICE_WINDOW_BOUNDARY_SAFETY_SECONDS", "1.0")
    )
    local_voice_window_minimum_skip_seconds: float = float(
        os.getenv("LOCAL_VOICE_WINDOW_MINIMUM_SKIP_SECONDS", "3.0")
    )
    local_voice_window_maximum_count: int = int(
        os.getenv("LOCAL_VOICE_WINDOW_MAXIMUM_COUNT", "32")
    )

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
