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


class LyricsRefineSegment(BaseModel):
    index: int = Field(ge=0, le=500)
    text: str = Field(min_length=1, max_length=500)
    start_seconds: float = Field(ge=0, le=3600)
    end_seconds: float = Field(ge=0, le=3600)


class LyricsRefineCandidate(BaseModel):
    identifier: str = Field(min_length=3, max_length=256)
    title: str = Field(min_length=1, max_length=256)
    artist: str = Field(max_length=256)
    source: str = Field(max_length=128)
    lines: list[LyricText] = Field(min_length=1, max_length=300)


class LyricsRefineRequest(BaseModel):
    media_fingerprint: str = Field(min_length=8, max_length=128)
    transcript: str = Field(max_length=30_000)
    segments: list[LyricsRefineSegment] = Field(min_length=2, max_length=500)
    candidates: list[LyricsRefineCandidate] = Field(default_factory=list, max_length=4)


class RefinedLyricLine(BaseModel):
    segment_index: int
    start_seconds: float
    end_seconds: float
    text: str


class LyricsRefineResponse(BaseModel):
    status: str
    model: str
    confidence: float
    selected_candidate_identifier: str | None = None
    lines: list[RefinedLyricLine]
