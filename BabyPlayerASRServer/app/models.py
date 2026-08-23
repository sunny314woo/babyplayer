"""
BabyPlayerASRServer/app/models.py

用途：定义 BabyPlayer 独立 ASR API 的 Pydantic 响应模型。
主要功能：
1. 描述腾讯 ASR 单词和句子时间戳。
2. 描述 ASR 分析结果。
3. 描述月度额度状态。
最近修改：2026-08-23 【MODIFIED】移除已停用的 LLM 歌词纠正请求/响应模型。
"""

from pydantic import BaseModel, Field


class AsrWord(BaseModel):
    """单个 ASR 单词及其相对识别音频的起止时间。"""

    text: str
    start_seconds: float
    end_seconds: float


class AsrSegment(BaseModel):
    """单个 ASR 句段，包含句级时间和可选单词时间戳。"""

    text: str
    start_seconds: float
    end_seconds: float
    words: list[AsrWord] = Field(default_factory=list)


class AsrAnalysisResponse(BaseModel):
    """一次 ASR 或缓存命中的完整返回，不包含原始音频或 Jellyfin 信息。"""

    status: str
    cache_hit: bool
    provider: str
    engine_type: str
    audio_duration_seconds: float
    transcript: str
    segments: list[AsrSegment]
    monthly_used_seconds: int
    monthly_reserved_seconds: int
    monthly_limit_seconds: int


class UsageResponse(BaseModel):
    """北京时间自然月的 ASR 用量与下一次重置时间。"""

    month: str
    used_seconds: int
    reserved_seconds: int
    remaining_seconds: int
    limit_seconds: int
    next_reset_at: str
