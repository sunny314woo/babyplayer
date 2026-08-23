import hashlib
import re
import threading
from datetime import datetime

from app.config import Settings
from app.database import AsrRepository, Usage
from app.tencent_asr import TencentAsrError


class AudioValidationError(Exception):
    pass


class ServerBusyError(Exception):
    pass


ALLOWED_FORMATS = {"m4a", "aac", "mp3"}
OPERATION_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


class AsrService:
    def __init__(self, repository: AsrRepository, client, config: Settings) -> None:
        self.repository = repository
        self.client = client
        self.config = config
        self._semaphore = threading.BoundedSemaphore(config.max_concurrency)

    def lookup(self, *, subject_hash: str, media_fingerprint: str, now: datetime):
        fingerprint_hash = fingerprint(media_fingerprint)
        cached = self.repository.cached(
            subject_hash, fingerprint_hash, self.config.analysis_version,
        )
        if not cached:
            return None
        return self._response(cached, cache_hit=True, now=now)

    def analyze(
        self,
        *,
        subject_hash: str,
        operation_id: str,
        media_fingerprint: str,
        duration_seconds: float,
        voice_format: str,
        audio: bytes,
        now: datetime,
    ) -> dict:
        self._validate(operation_id, media_fingerprint, duration_seconds, voice_format, audio)
        fingerprint_hash = fingerprint(media_fingerprint)
        cached = self.repository.cached(
            subject_hash, fingerprint_hash, self.config.analysis_version,
        )
        if cached:
            return self._response(cached, cache_hit=True, now=now)

        reserve_seconds = max(1, int(duration_seconds + 0.999))
        audio_sha256 = hashlib.sha256(audio).hexdigest()
        identical = self.repository.alias_cached_audio(
            subject_hash=subject_hash,
            fingerprint_hash=fingerprint_hash,
            audio_sha256=audio_sha256,
            version=self.config.analysis_version,
            now=now,
        )
        if identical:
            return self._response(identical, cache_hit=True, now=now)
        self.repository.claim(
            operation_id=operation_id,
            subject_hash=subject_hash,
            fingerprint_hash=fingerprint_hash,
            audio_sha256=audio_sha256,
            reserve_seconds=reserve_seconds,
            monthly_limit=self.config.monthly_limit_seconds,
            requests_per_minute=self.config.requests_per_minute,
            now=now,
        )
        acquired = self._semaphore.acquire(timeout=self.config.timeout_seconds)
        if not acquired:
            self.repository.release(operation_id, now)
            raise ServerBusyError()
        try:
            recognition = self.client.recognize(audio, voice_format)
            if recognition.duration_seconds <= 0:
                raise TencentAsrError("Tencent ASR returned an invalid duration")
            usage = self.repository.complete(
                operation_id=operation_id,
                subject_hash=subject_hash,
                fingerprint_hash=fingerprint_hash,
                analysis_version=self.config.analysis_version,
                audio_sha256=audio_sha256,
                engine_type=self.config.engine_type,
                duration_seconds=recognition.duration_seconds,
                transcript=recognition.transcript,
                segments=recognition.segments,
                monthly_limit=self.config.monthly_limit_seconds,
                now=now,
            )
            return response_payload(
                cache_hit=False,
                engine_type=self.config.engine_type,
                duration_seconds=recognition.duration_seconds,
                transcript=recognition.transcript,
                segments=recognition.segments,
                usage=usage,
            )
        except Exception:
            self.repository.release(operation_id, now)
            raise
        finally:
            self._semaphore.release()

    def _validate(self, operation_id, media_fingerprint, duration_seconds, voice_format, audio):
        if not OPERATION_PATTERN.fullmatch(operation_id):
            raise AudioValidationError("Invalid operation id")
        if not 8 <= len(media_fingerprint) <= 512:
            raise AudioValidationError("Invalid media fingerprint")
        if voice_format not in ALLOWED_FORMATS:
            raise AudioValidationError("Unsupported audio format")
        if not 0 < duration_seconds <= self.config.max_audio_seconds:
            raise AudioValidationError("Audio duration exceeds the BabyPlayer limit")
        if not audio or len(audio) > self.config.max_audio_bytes:
            raise AudioValidationError("Audio size exceeds the BabyPlayer limit")

    def _response(self, cached: dict, *, cache_hit: bool, now: datetime) -> dict:
        usage = self.repository.usage(self.config.monthly_limit_seconds, now)
        return response_payload(
            cache_hit=cache_hit,
            engine_type=cached["engine_type"],
            duration_seconds=cached["audio_duration_seconds"],
            transcript=cached["transcript"],
            segments=cached["segments"],
            usage=usage,
        )


def fingerprint(value: str) -> str:
    return hashlib.sha256(value.strip().encode("utf-8")).hexdigest()


def response_payload(
    *, cache_hit: bool, engine_type: str, duration_seconds: float,
    transcript: str, segments: list[dict], usage: Usage,
) -> dict:
    return {
        "status": "cached" if cache_hit else "completed",
        "cache_hit": cache_hit,
        "provider": "tencent_flash_asr",
        "engine_type": engine_type,
        "audio_duration_seconds": duration_seconds,
        "transcript": transcript,
        "segments": segments,
        "monthly_used_seconds": usage.used_seconds,
        "monthly_reserved_seconds": usage.reserved_seconds,
        "monthly_limit_seconds": usage.limit_seconds,
    }
