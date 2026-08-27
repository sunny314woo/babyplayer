"""Mac 本地媒体分析任务。

Apple TV 只提交 Jellyfin 返回的本机路径；本模块校验目录边界、调用本机 FFmpeg，
再复用现有 ASR 服务。任务在后台线程运行，不占用 Apple TV 的播放线程。
"""

from __future__ import annotations

import logging
import hashlib
import json
import shutil
import subprocess
import tempfile
import threading
import uuid
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path

from app.config import Settings
from app.database import (
    AnalysisInProgressError,
    MonthlyLimitReachedError,
    OperationAlreadyUsedError,
    RateLimitReachedError,
)
from app.models import LocalAnalysisJobRequest
from app.service import (
    AsrAudioChunk,
    AsrService,
    AudioValidationError,
    ServerBusyError,
)
from app.tencent_asr import TencentAsrError
from app.voice_activity import VoiceActivityEvidence
from app.voice_window_planner import (
    VoiceWindow,
    VoiceWindowPlanner,
    VoiceWindowPlannerConfig,
)
from app.vocal_separation import VocalSeparationError


logger = logging.getLogger("babyplayer.local_analysis")
PREPROCESSED_AUDIO_CACHE_SCHEMA = "babyplayer-preprocessed-audio-v1"
MEDIA_CONTENT_HASH_CACHE_SCHEMA = "babyplayer-media-content-hash-v1"
_CONTENT_HASH_EXECUTOR = ThreadPoolExecutor(
    max_workers=2,
    thread_name_prefix="babyplayer-content-hash",
)
ALLOWED_MEDIA_EXTENSIONS = {
    ".aac", ".avi", ".m4a", ".m4v", ".mkv", ".mov", ".mp3", ".mp4", ".webm"
}


class LocalMediaValidationError(Exception):
    pass


class LocalMediaExtractionError(Exception):
    pass


class LocalNoVocalsDetectedError(Exception):
    pass


@dataclass(frozen=True)
class ExtractedAudio:
    data: bytes
    duration_seconds: float
    voice_format: str = "m4a"
    media_content_sha256: str | None = None
    chunks: tuple[AsrAudioChunk, ...] = ()
    voice_activity: VoiceActivityEvidence | None = None
    audio_preprocessing: dict | None = None


@dataclass(frozen=True)
class AudioChunkWindow:
    index: int
    offset_seconds: float
    duration_seconds: float
    source_offset_seconds: float | None = None

    @property
    def end_seconds(self) -> float:
        return self.offset_seconds + self.duration_seconds

    @property
    def source_start_seconds(self) -> float:
        return (
            self.offset_seconds
            if self.source_offset_seconds is None
            else self.source_offset_seconds
        )


class LocalMediaContentHashCache:
    """Reuse one verified full-file hash while the source file identity is unchanged."""

    def __init__(self, directory: str, *, hash_file=None) -> None:
        self.root = Path(directory).expanduser().resolve() if directory else None
        self._hash_file = hash_file or _sha256_file
        self._lock = threading.Lock()
        self._memory: dict[str, tuple[dict[str, int | str], str]] = {}

    def lookup(self, source: Path) -> str | None:
        identity = _source_file_identity(source)
        memory = self._memory.get(str(source.resolve()))
        if memory is not None and memory[0] == identity:
            return memory[1]
        if self.root is None:
            return None
        try:
            manifest = json.loads(self._entry(source).read_text(encoding="utf-8"))
            digest = str(manifest["media_content_sha256"])
            if (
                manifest.get("schema") != MEDIA_CONTENT_HASH_CACHE_SCHEMA
                or manifest.get("source_identity") != identity
                or len(digest) != 64
                or any(value not in "0123456789abcdef" for value in digest)
            ):
                return None
            self._memory[str(source.resolve())] = (identity, digest)
            return digest
        except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
            return None

    def compute_async(self, source: Path) -> Future:
        return _CONTENT_HASH_EXECUTOR.submit(self.compute, source)

    def compute(self, source: Path) -> str:
        with self._lock:
            cached = self.lookup(source)
            if cached is not None:
                return cached
            identity_before = _source_file_identity(source)
            digest = self._hash_file(source)
            identity_after = _source_file_identity(source)
            if identity_after != identity_before:
                raise LocalMediaExtractionError(
                    "媒体文件在声音准备期间发生变化，请稍后重试"
                )
            if self.root is not None:
                try:
                    self.root.mkdir(parents=True, exist_ok=True)
                    entry = self._entry(source)
                    temporary = self.root / f".{entry.name}.{uuid.uuid4().hex}.tmp"
                    try:
                        temporary.write_text(
                            json.dumps({
                                "schema": MEDIA_CONTENT_HASH_CACHE_SCHEMA,
                                "source_identity": identity_after,
                                "media_content_sha256": digest,
                            }, ensure_ascii=False, sort_keys=True),
                            encoding="utf-8",
                        )
                        temporary.replace(entry)
                    finally:
                        temporary.unlink(missing_ok=True)
                except OSError as exc:
                    # Persistence is an optimization; a cache write failure must not
                    # delay or discard otherwise valid subtitles from this session.
                    logger.warning(
                        "Media content hash cache write unavailable error_type=%s",
                        type(exc).__name__,
                    )
            self._memory[str(source.resolve())] = (identity_after, digest)
            return digest

    def _entry(self, source: Path) -> Path:
        encoded = str(source.resolve()).encode("utf-8")
        return self.root / f"{hashlib.sha256(encoded).hexdigest()}.json"


class LocalPreprocessedAudioCache:
    """Persist exact provider inputs so forced ASR never repeats stem separation."""

    def __init__(self, directory: str) -> None:
        self.root = Path(directory).expanduser().resolve() if directory else None
        self._lock = threading.Lock()

    @property
    def enabled(self) -> bool:
        return self.root is not None

    def load(self, key: str) -> ExtractedAudio | None:
        if self.root is None:
            return None
        folder = self.root / key
        try:
            manifest = json.loads((folder / "manifest.json").read_text())
            if (
                manifest.get("schema") != PREPROCESSED_AUDIO_CACHE_SCHEMA
                or manifest.get("cache_key") != key
            ):
                return None
            complete_audio = (folder / "complete.m4a").read_bytes()
            if not complete_audio:
                return None
            chunks = []
            for expected_index, raw in enumerate(manifest["chunks"]):
                file_name = str(raw["file"])
                expected_file_name = f"chunk-{expected_index:03d}.m4a"
                if file_name != expected_file_name:
                    return None
                chunks.append(AsrAudioChunk(
                    index=int(raw["index"]),
                    offset_seconds=float(raw["offset_seconds"]),
                    duration_seconds=float(raw["duration_seconds"]),
                    audio=(folder / expected_file_name).read_bytes(),
                    voice_format=str(raw.get("voice_format") or "m4a"),
                ))
            chunks = tuple(chunks)
            if not chunks or any(
                chunk.index != index or not chunk.audio
                for index, chunk in enumerate(chunks)
            ):
                return None
            voice_activity = _voice_activity_from_cache(manifest.get("voice_activity"))
            preprocessing = manifest.get("audio_preprocessing")
            if preprocessing is not None and not isinstance(preprocessing, dict):
                return None
            preprocessing = dict(preprocessing or {})
            preprocessing["preprocessing_cache_hit"] = True
            return ExtractedAudio(
                data=complete_audio,
                duration_seconds=float(manifest["duration_seconds"]),
                voice_format=str(manifest.get("voice_format") or "m4a"),
                media_content_sha256=str(manifest["media_content_sha256"]),
                chunks=chunks,
                voice_activity=voice_activity,
                audio_preprocessing=preprocessing,
            )
        except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
            return None

    def store(self, key: str, extracted: ExtractedAudio) -> None:
        if self.root is None or not extracted.chunks or not extracted.data:
            return
        with self._lock:
            if self.load(key) is not None:
                return
            self.root.mkdir(parents=True, exist_ok=True)
            temporary = Path(tempfile.mkdtemp(prefix=f".{key[:12]}-", dir=self.root))
            try:
                (temporary / "complete.m4a").write_bytes(extracted.data)
                chunk_descriptors = []
                for chunk in extracted.chunks:
                    file_name = f"chunk-{chunk.index:03d}.m4a"
                    (temporary / file_name).write_bytes(chunk.audio)
                    chunk_descriptors.append({
                        "index": chunk.index,
                        "offset_seconds": chunk.offset_seconds,
                        "duration_seconds": chunk.duration_seconds,
                        "voice_format": chunk.voice_format,
                        "file": file_name,
                    })
                preprocessing = dict(extracted.audio_preprocessing or {})
                preprocessing.pop("preprocessing_cache_hit", None)
                manifest = {
                    "schema": PREPROCESSED_AUDIO_CACHE_SCHEMA,
                    "cache_key": key,
                    "duration_seconds": extracted.duration_seconds,
                    "voice_format": extracted.voice_format,
                    "media_content_sha256": extracted.media_content_sha256,
                    "chunks": chunk_descriptors,
                    "voice_activity": _voice_activity_to_cache(extracted.voice_activity),
                    "audio_preprocessing": preprocessing,
                }
                (temporary / "manifest.json").write_text(
                    json.dumps(manifest, ensure_ascii=False, sort_keys=True),
                    encoding="utf-8",
                )
                final = self.root / key
                if final.exists():
                    # Keep a corrupt/incomplete entry recoverable for diagnostics,
                    # while allowing the newly completed immutable entry to win.
                    final.rename(
                        self.root / f".invalid-{key[:12]}-{uuid.uuid4().hex}"
                    )
                temporary.rename(final)
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)


def _voice_activity_to_cache(evidence: VoiceActivityEvidence | None):
    if evidence is None:
        return None
    return {
        "detector": evidence.detector,
        "scope": evidence.scope,
        "threshold": evidence.threshold,
        "frame_seconds": evidence.frame_seconds,
        "probabilities": list(evidence.probabilities),
        "speech_intervals": [list(value) for value in evidence.speech_intervals],
    }


def _voice_activity_from_cache(raw) -> VoiceActivityEvidence | None:
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise TypeError("cached voice activity must be an object")
    return VoiceActivityEvidence(
        detector=str(raw["detector"]),
        scope=str(raw["scope"]),
        threshold=float(raw["threshold"]),
        frame_seconds=float(raw["frame_seconds"]),
        probabilities=tuple(float(value) for value in raw["probabilities"]),
        speech_intervals=tuple(
            (float(value[0]), float(value[1]))
            for value in raw["speech_intervals"]
        ),
    )


def plan_audio_chunks(
    duration_seconds: float,
    *,
    chunk_seconds: float,
    overlap_seconds: float,
) -> tuple[AudioChunkWindow, ...]:
    """Plan complete sequential coverage with a fixed adjacent overlap."""
    if duration_seconds <= 0:
        raise LocalMediaValidationError("歌曲时长无效")
    if chunk_seconds <= 0 or overlap_seconds < 0 or overlap_seconds >= chunk_seconds:
        raise LocalMediaValidationError("Mac ASR 分片配置无效")
    windows = []
    offset = 0.0
    step = chunk_seconds - overlap_seconds
    while offset < duration_seconds:
        duration = min(chunk_seconds, duration_seconds - offset)
        windows.append(AudioChunkWindow(
            index=len(windows),
            offset_seconds=offset,
            duration_seconds=duration,
        ))
        if offset + duration >= duration_seconds - 0.000_001:
            break
        offset += step
    return tuple(windows)


def plan_audio_chunks_for_windows(
    windows: tuple[VoiceWindow, ...],
    *,
    timeline_start_seconds: float,
    timeline_end_seconds: float,
    chunk_seconds: float,
    overlap_seconds: float,
) -> tuple[AudioChunkWindow, ...]:
    """Reuse fixed chunking inside sparse windows while preserving timeline gaps."""
    if timeline_end_seconds <= timeline_start_seconds:
        raise LocalMediaValidationError("歌曲时长无效")
    chunks = []
    for window in windows:
        start = max(timeline_start_seconds, window.start_seconds)
        end = min(timeline_end_seconds, window.end_seconds)
        if end <= start:
            continue
        local_chunks = plan_audio_chunks(
            end - start,
            chunk_seconds=chunk_seconds,
            overlap_seconds=overlap_seconds,
        )
        for local in local_chunks:
            source_start = start + local.offset_seconds
            chunks.append(AudioChunkWindow(
                index=len(chunks),
                offset_seconds=source_start - timeline_start_seconds,
                duration_seconds=local.duration_seconds,
                source_offset_seconds=source_start,
            ))
    return tuple(chunks)


class LocalMediaAudioExtractor:
    """Decode once to lossless PCM, then create all ASR inputs from one source."""

    def __init__(
        self,
        config: Settings,
        *,
        voice_activity_detector=None,
        vocal_stem_separator=None,
        voice_window_planner=None,
        preprocessing_cache=None,
        content_hash_cache=None,
    ) -> None:
        self.config = config
        self.voice_activity_detector = voice_activity_detector
        self.vocal_stem_separator = vocal_stem_separator
        self.voice_window_planner = voice_window_planner
        if self.voice_window_planner is None and config.local_sparse_asr_enabled:
            self.voice_window_planner = VoiceWindowPlanner(
                VoiceWindowPlannerConfig(
                    minimum_speech_seconds=(
                        config.local_voice_window_minimum_speech_seconds
                    ),
                    merge_gap_seconds=config.local_voice_window_merge_gap_seconds,
                    padding_before_seconds=(
                        config.local_voice_window_padding_before_seconds
                    ),
                    padding_after_seconds=(
                        config.local_voice_window_padding_after_seconds
                    ),
                    stable_body_gap_seconds=(
                        config.local_voice_window_stable_body_gap_seconds
                    ),
                    stable_body_minimum_span_seconds=(
                        config.local_voice_window_stable_body_minimum_span_seconds
                    ),
                    stable_body_minimum_speech_seconds=(
                        config.local_voice_window_stable_body_minimum_speech_seconds
                    ),
                    stable_body_minimum_density=(
                        config.local_voice_window_stable_body_minimum_density
                    ),
                    boundary_safety_seconds=(
                        config.local_voice_window_boundary_safety_seconds
                    ),
                    minimum_skip_seconds=(
                        config.local_voice_window_minimum_skip_seconds
                    ),
                    maximum_window_count=config.local_voice_window_maximum_count,
                )
            )
        self.uses_vocal_separation = vocal_stem_separator is not None
        self.preprocessing_cache = (
            preprocessing_cache
            or LocalPreprocessedAudioCache(
                config.local_preprocessed_audio_cache_directory
            )
        )
        self.content_hash_cache = (
            content_hash_cache
            or LocalMediaContentHashCache(
                config.local_media_content_hash_cache_directory
            )
        )
        self.roots = tuple(
            Path(value).expanduser().resolve()
            for value in config.local_media_roots
        )

    def extract(self, request: LocalAnalysisJobRequest) -> ExtractedAudio:
        source = self._validated_source(request.media_path)
        media_duration = request.duration_seconds
        timeline_start = request.song_start_seconds
        timeline_end = request.song_end_seconds or media_duration
        duration = timeline_end - timeline_start
        media_content_sha256 = self.content_hash_cache.lookup(source)
        if media_content_sha256 is not None:
            preprocessing_cache_key = self._preprocessing_cache_key(
                request,
                media_content_sha256=media_content_sha256,
            )
            cached = self.preprocessing_cache.load(preprocessing_cache_key)
            if (
                cached is not None
                and self.content_hash_cache.lookup(source) == media_content_sha256
            ):
                return cached

        ffmpeg = Path(self.config.local_ffmpeg_path).expanduser()
        if not ffmpeg.is_file():
            raise LocalMediaExtractionError("Mac 未找到可用的 FFmpeg")

        with tempfile.TemporaryDirectory(prefix="babyplayer-asr-") as directory:
            temporary_root = Path(directory)
            lossless_mix = temporary_root / "source-mix.wav"
            command = [
                str(ffmpeg),
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-i", str(source),
                # VAD must see the complete media timeline. Playback/manual skip
                # boundaries are applied only when provider chunks are planned.
                "-ss", "0.000",
                "-t", f"{media_duration:.3f}",
                "-vn", "-ac", "2", "-ar", "44100",
                "-c:a", "pcm_s16le",
                str(lossless_mix),
            ]
            self._run_ffmpeg(
                command,
                lossless_mix,
                error_message="Mac 无法从该视频提取音频",
            )

            # A cache miss must not put a full-file read in front of audio work.
            # Start it only after the source has been decoded, then overlap it with
            # the much slower separation/VAD/encoding pipeline.
            content_hash_future = None
            if media_content_sha256 is None:
                content_hash_future = self.content_hash_cache.compute_async(source)

            asr_source = lossless_mix
            audio_preprocessing = {
                "source": "lossless_mixed_audio",
                "decode": "pcm_s16le_44100_stereo",
            }
            if self.vocal_stem_separator is not None:
                separated = self.vocal_stem_separator.separate(
                    lossless_mix,
                    output_directory=temporary_root / "separated",
                    expected_duration_seconds=media_duration,
                )
                asr_source = separated.path
                audio_preprocessing = {
                    "source": "vocal_stem",
                    "decode": "pcm_s16le_44100_stereo",
                    "separator": separated.separator,
                    "model": separated.model,
                }

            voice_activity = None
            if self.voice_activity_detector is not None:
                try:
                    voice_activity = self.voice_activity_detector.analyze(
                        asr_source.read_bytes(),
                        duration_seconds=media_duration,
                    )
                    if voice_activity.frame_seconds <= 0:
                        raise RuntimeError("voice activity frame duration is invalid")
                    if self.vocal_stem_separator is not None:
                        voice_activity = replace(
                            voice_activity,
                            scope="vocal_stem_gate",
                        )
                    metrics = _voice_activity_metrics(voice_activity, media_duration)
                    audio_preprocessing.update(metrics)
                    if (
                        self.vocal_stem_separator is not None
                        and metrics["vocal_coverage"]
                        < self.config.local_minimum_vocal_coverage
                        and metrics["vocal_mean_probability"]
                        < self.config.local_minimum_vocal_mean_probability
                    ):
                        raise LocalNoVocalsDetectedError(
                            "未检测到足够人声，已停止 ASR 以避免生成幻觉字幕"
                        )
                except LocalNoVocalsDetectedError:
                    raise
                except Exception as exc:
                    # VAD is a quality signal, never a reason to lose an otherwise valid ASR.
                    voice_activity = None
                    logger.warning(
                        "Local voice activity analysis unavailable error_type=%s",
                        type(exc).__name__,
                    )

            provider_windows = (VoiceWindow(timeline_start, timeline_end),)
            if voice_activity is not None and self.voice_window_planner is not None:
                try:
                    plan = self.voice_window_planner.plan(
                        media_duration_seconds=media_duration,
                        evidence=voice_activity,
                    )
                    clipped = _clip_voice_windows(
                        plan.asr_windows,
                        start_seconds=timeline_start,
                        end_seconds=timeline_end,
                    )
                    plan_diagnostics = plan.diagnostics()
                    if plan.planner_status != "fallback" and clipped:
                        provider_windows = clipped
                        planned_seconds = sum(
                            value.duration_seconds for value in clipped
                        )
                        plan_diagnostics.update({
                            "planned_asr_seconds": round(planned_seconds, 3),
                            "saved_asr_seconds": round(
                                max(0.0, duration - planned_seconds), 3
                            ),
                            "asr_window_count": len(clipped),
                            "analysis_duration_seconds": round(duration, 3),
                        })
                    else:
                        plan_diagnostics.update({
                            "planner_status": "fallback",
                            "planner_fallback_reason": (
                                plan.fallback_reason
                                or "no_window_inside_analysis_boundary"
                            ),
                            "planned_asr_seconds": round(duration, 3),
                            "saved_asr_seconds": 0.0,
                            "asr_window_count": 1,
                            "analysis_duration_seconds": round(duration, 3),
                        })
                    audio_preprocessing.update(plan_diagnostics)
                except Exception as exc:
                    # Planning is quota optimization only. Preserve the complete
                    # ASR path whenever its output is unavailable or suspicious.
                    logger.warning(
                        "Voice window planning unavailable error_type=%s",
                        type(exc).__name__,
                    )
                    audio_preprocessing.update({
                        "planner_status": "fallback",
                        "planner_fallback_reason": "planner_exception",
                        "media_duration_seconds": round(media_duration, 3),
                        "analysis_duration_seconds": round(duration, 3),
                        "planned_asr_seconds": round(duration, 3),
                        "saved_asr_seconds": 0.0,
                        "asr_window_count": 1,
                        "smart_intro_end_seconds": None,
                        "smart_outro_start_seconds": None,
                    })

            windows = plan_audio_chunks_for_windows(
                provider_windows,
                timeline_start_seconds=timeline_start,
                timeline_end_seconds=timeline_end,
                chunk_seconds=self.config.local_asr_chunk_seconds,
                overlap_seconds=self.config.local_asr_chunk_overlap_seconds,
            )
            if not windows:
                # This should be unreachable after clipping, but quota optimization
                # must never make lyrics unavailable.
                windows = plan_audio_chunks_for_windows(
                    (VoiceWindow(timeline_start, timeline_end),),
                    timeline_start_seconds=timeline_start,
                    timeline_end_seconds=timeline_end,
                    chunk_seconds=self.config.local_asr_chunk_seconds,
                    overlap_seconds=self.config.local_asr_chunk_overlap_seconds,
                )
                audio_preprocessing.update({
                    "planner_status": "fallback",
                    "planner_fallback_reason": "empty_chunk_plan",
                    "planned_asr_seconds": round(duration, 3),
                    "saved_asr_seconds": 0.0,
                    "asr_window_count": 1,
                })
            if any(
                window.duration_seconds > self.config.max_audio_seconds
                for window in windows
            ):
                raise LocalMediaValidationError("Mac ASR 分片超过腾讯单次时长上限")

            output = temporary_root / "analysis.m4a"
            complete_command = [
                str(ffmpeg),
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-ss", f"{timeline_start:.3f}",
                "-i", str(asr_source),
                "-t", f"{duration:.3f}",
                "-vn", "-ac", "1", "-ar", "16000",
                "-c:a", "aac", "-b:a", "64k",
                str(output),
            ]
            self._run_ffmpeg(
                complete_command,
                output,
                error_message="Mac 无法生成完整 ASR 音频",
            )
            audio = output.read_bytes()
            if not audio or len(audio) > self.config.max_audio_bytes * len(windows):
                raise LocalMediaExtractionError("提取后的音频大小超过当前限制")
            chunks = []
            for window in windows:
                chunk_output = Path(directory) / f"chunk-{window.index:03d}.m4a"
                chunk_command = [
                    str(ffmpeg),
                    "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                    "-ss", f"{window.source_start_seconds:.3f}",
                    "-i", str(asr_source),
                    "-t", f"{window.duration_seconds:.3f}",
                    "-vn", "-ac", "1", "-ar", "16000",
                    "-c:a", "aac", "-b:a", "64k",
                    str(chunk_output),
                ]
                self._run_ffmpeg(
                    chunk_command,
                    chunk_output,
                    error_message="Mac 无法生成 ASR 音频分片",
                )
                chunk_audio = chunk_output.read_bytes()
                if not chunk_audio or len(chunk_audio) > self.config.max_audio_bytes:
                    raise LocalMediaExtractionError("ASR 音频分片大小超过当前限制")
                chunks.append(AsrAudioChunk(
                    index=window.index,
                    offset_seconds=window.offset_seconds,
                    duration_seconds=window.duration_seconds,
                    audio=chunk_audio,
                ))
            if content_hash_future is not None:
                media_content_sha256 = content_hash_future.result()
            if (
                media_content_sha256 is None
                or self.content_hash_cache.lookup(source) != media_content_sha256
            ):
                raise LocalMediaExtractionError(
                    "媒体文件在声音准备期间发生变化，请稍后重试"
                )
            preprocessing_cache_key = self._preprocessing_cache_key(
                request,
                media_content_sha256=media_content_sha256,
            )
            concurrently_cached = self.preprocessing_cache.load(
                preprocessing_cache_key
            )
            if concurrently_cached is not None:
                return concurrently_cached
            extracted = ExtractedAudio(
                data=audio,
                duration_seconds=duration,
                media_content_sha256=media_content_sha256,
                chunks=tuple(chunks),
                voice_activity=_voice_activity_for_timeline(
                    voice_activity,
                    start_seconds=timeline_start,
                    end_seconds=timeline_end,
                ),
                audio_preprocessing={
                    **audio_preprocessing,
                    "preprocessing_cache_hit": False,
                },
            )
            self.preprocessing_cache.store(preprocessing_cache_key, extracted)
            return extracted

    def _preprocessing_cache_key(
        self,
        request: LocalAnalysisJobRequest,
        *,
        media_content_sha256: str,
    ) -> str:
        config = self.config
        identity = {
            "schema": PREPROCESSED_AUDIO_CACHE_SCHEMA,
            "media_fingerprint": request.media_fingerprint,
            "media_content_sha256": media_content_sha256,
            "media_duration_seconds": f"{request.duration_seconds:.6f}",
            "song_start_seconds": f"{request.song_start_seconds:.6f}",
            "song_end_seconds": f"{(request.song_end_seconds or request.duration_seconds):.6f}",
            "audio": {
                "complete_format": "aac-16k-mono-64k-v1",
                "chunk_seconds": config.local_asr_chunk_seconds,
                "chunk_overlap_seconds": config.local_asr_chunk_overlap_seconds,
            },
            "vocal_separation": {
                "enabled": self.vocal_stem_separator is not None,
                "implementation": getattr(
                    self.vocal_stem_separator,
                    "separator_name",
                    type(self.vocal_stem_separator).__name__,
                ),
                "version": config.local_vocal_separation_version,
                "model": config.local_vocal_separation_model,
                "minimum_coverage": config.local_minimum_vocal_coverage,
                "minimum_mean_probability": (
                    config.local_minimum_vocal_mean_probability
                ),
            },
            "voice_activity": {
                "enabled": self.voice_activity_detector is not None,
                "detector": getattr(
                    self.voice_activity_detector,
                    "detector_name",
                    type(self.voice_activity_detector).__name__,
                ),
                "threshold": config.local_voice_activity_threshold,
            },
            "planner": {
                "enabled": self.voice_window_planner is not None,
                "minimum_speech_seconds": (
                    config.local_voice_window_minimum_speech_seconds
                ),
                "merge_gap_seconds": config.local_voice_window_merge_gap_seconds,
                "padding_before_seconds": (
                    config.local_voice_window_padding_before_seconds
                ),
                "padding_after_seconds": (
                    config.local_voice_window_padding_after_seconds
                ),
                "stable_body_gap_seconds": (
                    config.local_voice_window_stable_body_gap_seconds
                ),
                "stable_body_minimum_span_seconds": (
                    config.local_voice_window_stable_body_minimum_span_seconds
                ),
                "stable_body_minimum_speech_seconds": (
                    config.local_voice_window_stable_body_minimum_speech_seconds
                ),
                "stable_body_minimum_density": (
                    config.local_voice_window_stable_body_minimum_density
                ),
                "boundary_safety_seconds": (
                    config.local_voice_window_boundary_safety_seconds
                ),
                "minimum_skip_seconds": (
                    config.local_voice_window_minimum_skip_seconds
                ),
                "maximum_window_count": (
                    config.local_voice_window_maximum_count
                ),
            },
        }
        encoded = json.dumps(identity, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(encoded.encode("utf-8")).hexdigest()

    def _run_ffmpeg(
        self,
        command: list[str],
        output: Path,
        *,
        error_message: str,
    ) -> None:
        try:
            completed = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=self.config.local_extraction_timeout_seconds,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise LocalMediaExtractionError("Mac 提取音频超时") from exc
        except OSError as exc:
            raise LocalMediaExtractionError("Mac 无法启动 FFmpeg") from exc
        if completed.returncode != 0 or not output.is_file():
            raise LocalMediaExtractionError(error_message)

    def _validated_source(self, raw_path: str) -> Path:
        if not self.roots:
            raise LocalMediaValidationError("Mac 尚未配置本地媒体目录")
        try:
            source = Path(raw_path).expanduser().resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise LocalMediaValidationError("Mac 找不到该媒体文件") from exc
        if not source.is_file() or source.suffix.lower() not in ALLOWED_MEDIA_EXTENSIONS:
            raise LocalMediaValidationError("Mac 不支持该媒体文件")
        if not any(_is_below(source, root) for root in self.roots):
            raise LocalMediaValidationError("该媒体文件不在允许的本地目录中")
        return source


def _is_below(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _source_file_identity(path: Path) -> dict[str, int | str]:
    stat = path.stat()
    return {
        "resolved_path": str(path.resolve()),
        "device": int(stat.st_dev),
        "inode": int(stat.st_ino),
        "size": int(stat.st_size),
        "modified_nanoseconds": int(stat.st_mtime_ns),
        "changed_nanoseconds": int(stat.st_ctime_ns),
    }


def _voice_activity_metrics(
    evidence: VoiceActivityEvidence,
    duration_seconds: float,
) -> dict[str, float]:
    speech_seconds = sum(
        max(0.0, end - start) for start, end in evidence.speech_intervals
    )
    mean_probability = (
        sum(evidence.probabilities) / len(evidence.probabilities)
        if evidence.probabilities else 0.0
    )
    return {
        "vocal_coverage": round(
            min(1.0, speech_seconds / max(0.001, duration_seconds)), 4
        ),
        "vocal_mean_probability": round(mean_probability, 4),
    }


def _clip_voice_windows(
    windows: tuple[VoiceWindow, ...],
    *,
    start_seconds: float,
    end_seconds: float,
) -> tuple[VoiceWindow, ...]:
    clipped = []
    for window in windows:
        start = max(start_seconds, window.start_seconds)
        end = min(end_seconds, window.end_seconds)
        if end > start:
            clipped.append(VoiceWindow(start, end))
    return tuple(clipped)


def _voice_activity_for_timeline(
    evidence: VoiceActivityEvidence | None,
    *,
    start_seconds: float,
    end_seconds: float,
) -> VoiceActivityEvidence | None:
    """Translate complete-media VAD evidence onto the existing song-relative timeline."""
    if evidence is None:
        return None
    duration = max(0.0, end_seconds - start_seconds)
    frame_count = max(0, int((duration / evidence.frame_seconds) + 0.999_999))
    probabilities = []
    for index in range(frame_count):
        media_time = start_seconds + index * evidence.frame_seconds
        source_index = int(media_time / evidence.frame_seconds)
        if 0 <= source_index < len(evidence.probabilities):
            probabilities.append(evidence.probabilities[source_index])
        else:
            probabilities.append(0.0)
    intervals = []
    for raw_start, raw_end in evidence.speech_intervals:
        clipped_start = max(start_seconds, raw_start)
        clipped_end = min(end_seconds, raw_end)
        if clipped_end > clipped_start:
            intervals.append((
                clipped_start - start_seconds,
                clipped_end - start_seconds,
            ))
    return VoiceActivityEvidence(
        detector=evidence.detector,
        scope=evidence.scope,
        threshold=evidence.threshold,
        frame_seconds=evidence.frame_seconds,
        probabilities=tuple(probabilities),
        speech_intervals=tuple(intervals),
    )


class LocalAnalysisJobManager:
    """保存短期任务状态；最终 ASR 结果仍由 SQLite 持久化。"""

    def __init__(
        self,
        *,
        service: AsrService,
        extractor,
        artifact_writer,
        max_concurrency: int,
    ) -> None:
        self.service = service
        self.extractor = extractor
        self.artifact_writer = artifact_writer
        self._lock = threading.Lock()
        self._work_slots = threading.BoundedSemaphore(max(1, max_concurrency))
        self._jobs: dict[str, dict] = {}
        self._owners: dict[str, str] = {}
        self._active: dict[tuple[str, str], str] = {}

    def submit(
        self,
        *,
        subject_hash: str,
        request: LocalAnalysisJobRequest,
    ) -> dict:
        key = (subject_hash, request.media_fingerprint)
        with self._lock:
            if not request.force_refresh:
                active_id = self._active.get(key)
                if active_id and active_id in self._jobs:
                    return dict(self._jobs[active_id])
            job_id = uuid.uuid4().hex
            response = {
                "job_id": job_id,
                "status": "queued",
                "message": "任务已提交到 Mac",
                "analysis": None,
            }
            self._trim_completed_jobs()
            self._jobs[job_id] = response
            self._owners[job_id] = subject_hash
            self._active[key] = job_id

        thread = threading.Thread(
            target=self._run,
            args=(job_id, key, subject_hash, request),
            name=f"babyplayer-local-asr-{job_id[:8]}",
            daemon=True,
        )
        thread.start()
        return dict(response)

    def get(self, job_id: str, *, subject_hash: str) -> dict | None:
        with self._lock:
            if self._owners.get(job_id) != subject_hash:
                return None
            job = self._jobs.get(job_id)
            return dict(job) if job else None

    def _run(
        self,
        job_id: str,
        key: tuple[str, str],
        subject_hash: str,
        request: LocalAnalysisJobRequest,
    ) -> None:
        self._work_slots.acquire()
        try:
            extraction_message = (
                "Mac 正在提取音频并分离人声"
                if getattr(self.extractor, "uses_vocal_separation", False)
                else "Mac 正在从原视频提取音频"
            )
            self._update(job_id, status="extracting", message=extraction_message)
            extracted = self.extractor.extract(request)
            self._update(job_id, status="recognizing", message="腾讯 ASR 正在识别")
            if extracted.chunks:
                result = self.service.analyze_chunked(
                    subject_hash=subject_hash,
                    operation_id=f"local-{job_id}",
                    media_fingerprint=request.media_fingerprint,
                    duration_seconds=extracted.duration_seconds,
                    audio=extracted.data,
                    chunks=extracted.chunks,
                    force_refresh=request.force_refresh,
                    now=datetime.now(timezone.utc),
                    media_content_sha256=extracted.media_content_sha256,
                    voice_activity=extracted.voice_activity,
                    audio_preprocessing=extracted.audio_preprocessing,
                    on_chunk=lambda index, total: self._update(
                        job_id,
                        status="recognizing",
                        message=f"腾讯 ASR 正在识别分片 {index}/{total}",
                    ),
                )
            else:
                # Test/legacy extractors can still provide one already prepared sample.
                result = self.service.analyze(
                    subject_hash=subject_hash,
                    operation_id=f"local-{job_id}",
                    media_fingerprint=request.media_fingerprint,
                    duration_seconds=extracted.duration_seconds,
                    voice_format=extracted.voice_format,
                    audio=extracted.data,
                    force_refresh=request.force_refresh,
                    now=datetime.now(timezone.utc),
                    media_content_sha256=extracted.media_content_sha256,
                )
            self.artifact_writer.store_asr(
                media_fingerprint=request.media_fingerprint,
                media_title=request.media_title,
                audio=extracted.data,
                response=result,
                force_refresh=request.force_refresh,
                audio_file_name="extracted_audio.m4a",
            )
            self._update(
                job_id,
                status="completed",
                message="识别完成",
                analysis=result,
            )
        except Exception as exc:  # 所有后台错误必须转换为可轮询状态。
            error_code, message = _friendly_error(exc)
            logger.warning("Local analysis job failed job_id=%s code=%s", job_id, error_code)
            self._update(
                job_id,
                status="failed",
                error_code=error_code,
                message=message,
            )
        finally:
            with self._lock:
                if self._active.get(key) == job_id:
                    self._active.pop(key, None)
            self._work_slots.release()

    def _update(self, job_id: str, **values) -> None:
        with self._lock:
            if job_id in self._jobs:
                self._jobs[job_id] = {**self._jobs[job_id], **values}

    def _trim_completed_jobs(self) -> None:
        if len(self._jobs) < 100:
            return
        removable = [
            job_id for job_id, value in self._jobs.items()
            if value["status"] in {"completed", "failed"}
        ]
        for job_id in removable[: max(1, len(self._jobs) - 99)]:
            self._jobs.pop(job_id, None)
            self._owners.pop(job_id, None)


def _friendly_error(exc: Exception) -> tuple[str, str]:
    if isinstance(exc, LocalMediaValidationError):
        return "LOCAL_MEDIA_INVALID", str(exc)
    if isinstance(exc, LocalMediaExtractionError):
        return "LOCAL_AUDIO_EXTRACTION_FAILED", str(exc)
    if isinstance(exc, VocalSeparationError):
        return "LOCAL_VOCAL_SEPARATION_FAILED", str(exc)
    if isinstance(exc, LocalNoVocalsDetectedError):
        return "NO_VOCALS_DETECTED", str(exc)
    if isinstance(exc, MonthlyLimitReachedError):
        return "MONTHLY_ASR_LIMIT_REACHED", "本月声音分析额度已用完"
    if isinstance(exc, RateLimitReachedError):
        return "ASR_RATE_LIMITED", "声音分析请求过于频繁，请稍后再试"
    if isinstance(exc, AnalysisInProgressError):
        return "ASR_ANALYSIS_IN_PROGRESS", "同一音频正在识别，请稍后再试"
    if isinstance(exc, OperationAlreadyUsedError):
        return "ASR_OPERATION_ALREADY_USED", "该识别任务已经使用"
    if isinstance(exc, AudioValidationError):
        return "INVALID_AUDIO_SAMPLE", str(exc)
    if isinstance(exc, ServerBusyError):
        return "ASR_SERVER_BUSY", "Mac 分析任务正忙，请稍后再试"
    if isinstance(exc, TencentAsrError):
        return "TENCENT_ASR_UNAVAILABLE", "腾讯 ASR 暂时不可用"
    return "LOCAL_ANALYSIS_FAILED", "Mac 本地分析失败，请查看 Mac 服务日志"


__all__ = [
    "ExtractedAudio",
    "AudioChunkWindow",
    "LocalAnalysisJobManager",
    "LocalMediaContentHashCache",
    "LocalMediaAudioExtractor",
    "LocalPreprocessedAudioCache",
    "LocalMediaExtractionError",
    "LocalNoVocalsDetectedError",
    "LocalMediaValidationError",
    "plan_audio_chunks",
    "plan_audio_chunks_for_windows",
]
