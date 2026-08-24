"""Mac 本地媒体分析任务。

Apple TV 只提交 Jellyfin 返回的本机路径；本模块校验目录边界、调用本机 FFmpeg，
再复用现有 ASR 服务。任务在后台线程运行，不占用 Apple TV 的播放线程。
"""

from __future__ import annotations

import logging
import hashlib
import subprocess
import tempfile
import threading
import uuid
from dataclasses import dataclass
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


logger = logging.getLogger("babyplayer.local_analysis")
ALLOWED_MEDIA_EXTENSIONS = {
    ".aac", ".avi", ".m4a", ".m4v", ".mkv", ".mov", ".mp3", ".mp4", ".webm"
}


class LocalMediaValidationError(Exception):
    pass


class LocalMediaExtractionError(Exception):
    pass


@dataclass(frozen=True)
class ExtractedAudio:
    data: bytes
    duration_seconds: float
    voice_format: str = "m4a"
    media_content_sha256: str | None = None
    chunks: tuple[AsrAudioChunk, ...] = ()


@dataclass(frozen=True)
class AudioChunkWindow:
    index: int
    offset_seconds: float
    duration_seconds: float

    @property
    def end_seconds(self) -> float:
        return self.offset_seconds + self.duration_seconds


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


class LocalMediaAudioExtractor:
    """只从白名单目录读取源媒体，并输出腾讯 ASR 可接收的单声道 M4A。"""

    def __init__(self, config: Settings) -> None:
        self.config = config
        self.roots = tuple(
            Path(value).expanduser().resolve()
            for value in config.local_media_roots
        )

    def extract(self, request: LocalAnalysisJobRequest) -> ExtractedAudio:
        source = self._validated_source(request.media_path)
        media_content_sha256 = _sha256_file(source)
        duration = request.analysis_duration_seconds
        windows = plan_audio_chunks(
            duration,
            chunk_seconds=self.config.local_asr_chunk_seconds,
            overlap_seconds=self.config.local_asr_chunk_overlap_seconds,
        )
        if any(
            window.duration_seconds > self.config.max_audio_seconds
            for window in windows
        ):
            raise LocalMediaValidationError("Mac ASR 分片超过腾讯单次时长上限")

        ffmpeg = Path(self.config.local_ffmpeg_path).expanduser()
        if not ffmpeg.is_file():
            raise LocalMediaExtractionError("Mac 未找到可用的 FFmpeg")

        with tempfile.TemporaryDirectory(prefix="babyplayer-asr-") as directory:
            output = Path(directory) / "analysis.m4a"
            command = [
                str(ffmpeg),
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-ss", f"{request.song_start_seconds:.3f}",
                "-i", str(source),
                "-t", f"{duration:.3f}",
                "-vn", "-ac", "1", "-ar", "16000",
                "-c:a", "aac", "-b:a", "64k",
                str(output),
            ]
            self._run_ffmpeg(command, output, error_message="Mac 无法从该视频提取音频")

            audio = output.read_bytes()
            if not audio or len(audio) > self.config.max_audio_bytes * len(windows):
                raise LocalMediaExtractionError("提取后的音频大小超过当前限制")
            chunks = []
            for window in windows:
                chunk_output = Path(directory) / f"chunk-{window.index:03d}.m4a"
                chunk_command = [
                    str(ffmpeg),
                    "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                    "-ss", f"{window.offset_seconds:.3f}",
                    "-i", str(output),
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
            return ExtractedAudio(
                data=audio,
                duration_seconds=duration,
                media_content_sha256=media_content_sha256,
                chunks=tuple(chunks),
            )

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
            self._update(job_id, status="extracting", message="Mac 正在从原视频提取音频")
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
    "LocalMediaAudioExtractor",
    "LocalMediaExtractionError",
    "LocalMediaValidationError",
    "plan_audio_chunks",
]
