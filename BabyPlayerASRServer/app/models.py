"""BabyPlayer ASR/usage 与 AI Lyrics limited-repair API 数据模型。

当前主要功能：校验腾讯时间证据、用量响应、AI v1 原始行和逐行文本修复建议。
最近修改：2026-08-24 增加 Mac 本地媒体异步分析任务模型。
"""

from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints, model_validator


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
    audio_sha256: str | None = None
    media_content_sha256: str | None = None


class UsageResponse(BaseModel):
    month: str
    used_seconds: int
    reserved_seconds: int
    remaining_seconds: int
    limit_seconds: int
    next_reset_at: str


class LocalAnalysisJobRequest(BaseModel):
    """Apple TV 只提交媒体身份与 Mac 本机路径，不上传音频。"""

    media_fingerprint: str = Field(min_length=8, max_length=512)
    media_title: str = Field(default="", max_length=500)
    media_path: str = Field(min_length=1, max_length=4096)
    duration_seconds: float = Field(gt=0, le=86_400)
    song_start_seconds: float = Field(default=0, ge=0, le=86_400)
    song_end_seconds: float | None = Field(default=None, gt=0, le=86_400)
    force_refresh: bool = False

    @model_validator(mode="after")
    def validate_song_window(self):
        end = self.song_end_seconds or self.duration_seconds
        if end > self.duration_seconds + 1:
            raise ValueError("song end exceeds media duration")
        if end <= self.song_start_seconds:
            raise ValueError("song end must be after song start")
        return self

    @property
    def analysis_duration_seconds(self) -> float:
        return (self.song_end_seconds or self.duration_seconds) - self.song_start_seconds


class LocalAnalysisJobResponse(BaseModel):
    job_id: str
    status: Literal["queued", "extracting", "recognizing", "completed", "failed"]
    message: str | None = None
    error_code: str | None = None
    analysis: AsrAnalysisResponse | None = None


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


class LyricsCandidateLineInput(BaseModel):
    line_identifier: str = Field(min_length=3, max_length=128)
    text: str = Field(min_length=1, max_length=500)
    original_start_seconds: float | None = Field(default=None, ge=0, le=3600)
    original_end_seconds: float | None = Field(default=None, ge=0, le=3600)


class LyricsCandidateInput(BaseModel):
    candidate_id: str = Field(min_length=1, max_length=128)
    source: str = Field(min_length=1, max_length=128)
    title: str | None = Field(default=None, max_length=500)
    artist: str | None = Field(default=None, max_length=500)
    lines: list[LyricsCandidateLineInput] = Field(min_length=1, max_length=300)

    @model_validator(mode="after")
    def validate_unique_line_identifiers(self):
        identifiers = [line.line_identifier for line in self.lines]
        if len(set(identifiers)) != len(identifiers):
            raise ValueError("candidate line identifiers must be unique")
        return self


class LyricsReconcileRequest(BaseModel):
    media_fingerprint: str = Field(min_length=8, max_length=512)
    song_title: str = Field(min_length=1, max_length=500)
    candidates: list[LyricsCandidateInput] = Field(default_factory=list, max_length=3)
    force_refresh: bool = False

    @model_validator(mode="after")
    def validate_candidate_evidence(self):
        candidate_ids = [candidate.candidate_id for candidate in self.candidates]
        if len(set(candidate_ids)) != len(candidate_ids):
            raise ValueError("candidate identifiers must be unique")
        total_characters = sum(
            len(line.text)
            for candidate in self.candidates
            for line in candidate.lines
        )
        if total_characters > 60_000:
            raise ValueError("candidate lyric evidence is too large")
        return self


class LyricsReconciledLine(BaseModel):
    text: str = Field(min_length=1, max_length=500)
    asr_word_start_index: int = Field(ge=0, le=20_000)
    asr_word_end_index: int = Field(ge=0, le=20_000)
    start_seconds: float = Field(ge=0, le=3600)
    end_seconds: float = Field(ge=0, le=3600)
    source: str = Field(min_length=1, max_length=128)
    source_line_ids: list[str] = Field(default_factory=list, max_length=20)
    confidence: float = Field(ge=0, le=1)
    text_corrected: bool


class LyricsDiscardedLine(BaseModel):
    source_line_id: str | None = Field(default=None, max_length=128)
    text: str = Field(min_length=1, max_length=500)
    reason: str = Field(min_length=1, max_length=128)


class LyricsReconcileResponse(BaseModel):
    status: str
    cache_hit: bool
    model: str
    reconciliation_version: str
    song_match_confidence: float = Field(ge=0, le=1)
    primary_source: str = Field(min_length=1, max_length=128)
    web_search_used: bool
    lines: list[LyricsReconciledLine]
    discarded_lines: list[LyricsDiscardedLine] = Field(default_factory=list)
