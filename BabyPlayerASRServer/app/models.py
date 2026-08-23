"""BabyPlayer ASR/usage 与 AI Lyrics limited-repair API 数据模型。

当前主要功能：校验腾讯时间证据、用量响应、AI v1 原始行和逐行文本修复建议。
最近修改：2026-08-23 将 /v1/refine 收紧为 Version C 结构化 repair contract。
"""

from typing import Annotated

from pydantic import BaseModel, Field, StringConstraints


LyricText = Annotated[str, StringConstraints(min_length=1, max_length=500)]


class AsrWord(BaseModel):
    text: str
    start_seconds: float
    end_seconds: float


class AsrSegment(BaseModel):
    text: str
    start_seconds: float
    end_seconds: float
    words: list[AsrWord] = Field(default_factory=list)


class AsrAnalysisResponse(BaseModel):
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
    month: str
    used_seconds: int
    reserved_seconds: int
    remaining_seconds: int
    limit_seconds: int
    next_reset_at: str


class LyricsAlignedWord(BaseModel):
    text: str = Field(min_length=1, max_length=100)
    start_seconds: float = Field(ge=0, le=3600)
    end_seconds: float = Field(ge=0, le=3600)


class LyricsIndexedWord(LyricsAlignedWord):
    word_index: int = Field(ge=0, le=20_000)


class LyricsOriginalLine(BaseModel):
    line_identifier: str = Field(min_length=3, max_length=128)
    original_text: str = Field(min_length=1, max_length=500)
    start_seconds: float = Field(ge=0, le=3600)
    end_seconds: float = Field(ge=0, le=3600)
    aligned_words: list[LyricsAlignedWord] = Field(default_factory=list, max_length=100)


class LyricsMatchEvidence(BaseModel):
    normalized_text_similarity: float = Field(ge=0, le=1)
    ordered_token_similarity: float = Field(ge=0, le=1)
    title_similarity: float = Field(ge=0, le=1)
    asr_coverage: float = Field(ge=0, le=1)
    temporal_order: float = Field(ge=0, le=1)
    same_song_confidence: float = Field(ge=0, le=1)


class LyricsRefineRequest(BaseModel):
    media_fingerprint: str = Field(min_length=8, max_length=128)
    transcript: str = Field(max_length=30_000)
    original_lines: list[LyricsOriginalLine] = Field(min_length=2, max_length=300)
    asr_words: list[LyricsIndexedWord] = Field(min_length=3, max_length=5_000)
    evidence: LyricsMatchEvidence


class LyricsTextRepair(BaseModel):
    line_identifier: str = Field(min_length=3, max_length=128)
    original_text: str = Field(min_length=1, max_length=500)
    suggested_text: str = Field(min_length=1, max_length=500)
    should_modify: bool
    evidence: str = Field(min_length=1, max_length=500)
    confidence: float = Field(ge=0, le=1)
    should_display: bool
    start_word_index: int | None = Field(default=None, ge=0, le=20_000)
    end_word_index: int | None = Field(default=None, ge=0, le=20_000)
    start_seconds: float | None = Field(default=None, ge=0, le=3600)
    end_seconds: float | None = Field(default=None, ge=0, le=3600)


class LyricsRefineResponse(BaseModel):
    status: str
    model: str
    overall_confidence: float = Field(ge=0, le=1)
    repairs: list[LyricsTextRepair]
