import hashlib
import math
import re
import threading
import time
from collections import deque
from dataclasses import dataclass
from datetime import datetime
from typing import Callable, Sequence

from app.config import Settings
from app.database import AsrRepository, Usage
from app.tencent_asr import TencentAsrError
from app.voice_activity import annotate_asr_segments, voice_activity_summary
from app.voice_window_planner import PLANNER_VERSION


class AudioValidationError(Exception):
    pass


class ServerBusyError(Exception):
    pass


ALLOWED_FORMATS = {"m4a", "aac", "mp3"}
OPERATION_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


@dataclass(frozen=True)
class AsrAudioChunk:
    """One provider request with timing relative to the complete extracted song."""

    index: int
    offset_seconds: float
    duration_seconds: float
    audio: bytes
    voice_format: str = "m4a"

    @property
    def end_seconds(self) -> float:
        return self.offset_seconds + self.duration_seconds


class ProviderRequestLimiter:
    """Process-local rolling-window limiter for actual Tencent requests."""

    def __init__(
        self,
        requests_per_minute: int,
        *,
        clock: Callable[[], float] = time.monotonic,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        self.limit = max(1, int(requests_per_minute))
        self.clock = clock
        self.sleeper = sleeper
        self._lock = threading.Lock()
        self._timestamps: deque[float] = deque()

    def wait_for_slot(self) -> None:
        while True:
            with self._lock:
                current = self.clock()
                while self._timestamps and current - self._timestamps[0] >= 60:
                    self._timestamps.popleft()
                if len(self._timestamps) < self.limit:
                    self._timestamps.append(current)
                    return
                delay = max(0.01, 60 - (current - self._timestamps[0]))
            self.sleeper(delay)


class AsrService:
    def __init__(
        self,
        repository: AsrRepository,
        client,
        config: Settings,
        *,
        provider_request_limiter=None,
    ) -> None:
        self.repository = repository
        self.client = client
        self.config = config
        chunk_shape = (
            f"{config.local_asr_chunk_seconds:g}s-"
            f"{config.local_asr_chunk_overlap_seconds:g}s"
        )
        source_shape = (
            f"|source:{config.local_vocal_separation_version}"
            if config.local_vocal_separation_enabled else ""
        )
        planner_shape = ""
        if config.local_sparse_asr_enabled and config.local_voice_activity_enabled:
            planner_settings = "|".join(str(value) for value in (
                config.local_voice_window_minimum_speech_seconds,
                config.local_voice_window_merge_gap_seconds,
                config.local_voice_window_padding_before_seconds,
                config.local_voice_window_padding_after_seconds,
                config.local_voice_window_stable_body_gap_seconds,
                config.local_voice_window_stable_body_minimum_span_seconds,
                config.local_voice_window_stable_body_minimum_speech_seconds,
                config.local_voice_window_stable_body_minimum_density,
                config.local_voice_window_boundary_safety_seconds,
                config.local_voice_window_minimum_skip_seconds,
                config.local_voice_window_maximum_count,
            ))
            planner_digest = hashlib.sha256(
                planner_settings.encode("utf-8")
            ).hexdigest()[:10]
            planner_shape = f"|planner:{PLANNER_VERSION}:{planner_digest}"
        # Cache identity changes when either the declared analysis algorithm or the
        # deterministic Mac chunk timeline changes. Existing whole-song v1 rows stay
        # intact but cannot mask the first complete chunked result.
        self.analysis_version = (
            f"{config.analysis_version}|{config.asr_timeline_version}"
            f"{source_shape}|{chunk_shape}{planner_shape}"
        )
        self._semaphore = threading.BoundedSemaphore(config.max_concurrency)
        self._provider_request_limiter = (
            provider_request_limiter
            or ProviderRequestLimiter(config.requests_per_minute)
        )

    def lookup(self, *, subject_hash: str, media_fingerprint: str, now: datetime):
        fingerprint_hash = fingerprint(media_fingerprint)
        cached = self.repository.cached(
            subject_hash, fingerprint_hash, self.analysis_version,
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
        force_refresh: bool,
        now: datetime,
        media_content_sha256: str | None = None,
    ) -> dict:
        self._validate(operation_id, media_fingerprint, duration_seconds, voice_format, audio)
        fingerprint_hash = fingerprint(media_fingerprint)
        audio_sha256 = hashlib.sha256(audio).hexdigest()
        cached = self.repository.cached(
            subject_hash, fingerprint_hash, self.analysis_version,
        )
        if cached and not force_refresh:
            cached_media_hash = cached.get("media_content_sha256")
            if not media_content_sha256 or cached_media_hash == media_content_sha256:
                return self._response(cached, cache_hit=True, now=now)
            if cached_media_hash is None:
                # Legacy 缓存来自同一 fingerprint；首次由 Mac 找到源文件时只补哈希，不重复计费。
                self.repository.attach_media_content_hash(
                    subject_hash=subject_hash,
                    fingerprint_hash=fingerprint_hash,
                    analysis_version=self.analysis_version,
                    media_content_sha256=media_content_sha256,
                    now=now,
                )
                cached["media_content_sha256"] = media_content_sha256
                return self._response(cached, cache_hit=True, now=now)

        reserve_seconds = max(1, int(duration_seconds + 0.999))
        identical = None if force_refresh else self.repository.alias_cached_audio(
            subject_hash=subject_hash,
            fingerprint_hash=fingerprint_hash,
            audio_sha256=audio_sha256,
            media_content_sha256=media_content_sha256,
            version=self.analysis_version,
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
        # A matching operation may have completed between the first cache lookup and
        # this atomic claim. Re-check after claiming so this request never calls the
        # provider for audio that has just become cacheable.
        identical_after_claim = None if force_refresh else self.repository.alias_cached_audio(
            subject_hash=subject_hash,
            fingerprint_hash=fingerprint_hash,
            audio_sha256=audio_sha256,
            media_content_sha256=media_content_sha256,
            version=self.analysis_version,
            now=now,
        )
        if identical_after_claim:
            self.repository.release(operation_id, now)
            return self._response(identical_after_claim, cache_hit=True, now=now)
        acquired = self._semaphore.acquire(timeout=self.config.timeout_seconds)
        if not acquired:
            self.repository.release(operation_id, now)
            raise ServerBusyError()
        try:
            self._provider_request_limiter.wait_for_slot()
            recognition = self.client.recognize(audio, voice_format)
            if recognition.duration_seconds <= 0:
                raise TencentAsrError("Tencent ASR returned an invalid duration")
            usage = self.repository.complete(
                operation_id=operation_id,
                subject_hash=subject_hash,
                fingerprint_hash=fingerprint_hash,
                analysis_version=self.analysis_version,
                audio_sha256=audio_sha256,
                media_content_sha256=media_content_sha256,
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
                audio_sha256=audio_sha256,
                media_content_sha256=media_content_sha256,
                usage=usage,
            )
        except Exception:
            self.repository.release(operation_id, now)
            raise
        finally:
            self._semaphore.release()

    def analyze_chunked(
        self,
        *,
        subject_hash: str,
        operation_id: str,
        media_fingerprint: str,
        duration_seconds: float,
        audio: bytes,
        chunks: Sequence[AsrAudioChunk],
        force_refresh: bool,
        now: datetime,
        media_content_sha256: str | None = None,
        voice_activity=None,
        audio_preprocessing: dict | None = None,
        on_chunk: Callable[[int, int], None] | None = None,
    ) -> dict:
        """Recognize local Mac chunks sequentially and persist one merged timeline."""
        self._validate_chunked(
            operation_id,
            media_fingerprint,
            duration_seconds,
            audio,
            chunks,
        )
        ordered_chunks = tuple(sorted(chunks, key=lambda value: value.index))
        fingerprint_hash = fingerprint(media_fingerprint)
        audio_sha256 = hashlib.sha256(audio).hexdigest()
        cached = self.repository.cached(
            subject_hash, fingerprint_hash, self.analysis_version,
        )
        if cached and not force_refresh:
            cached_media_hash = cached.get("media_content_sha256")
            if not media_content_sha256 or cached_media_hash == media_content_sha256:
                cached = self._enrich_voice_activity(
                    cached,
                    subject_hash=subject_hash,
                    fingerprint_hash=fingerprint_hash,
                    voice_activity=voice_activity,
                    now=now,
                )
                return self._response(cached, cache_hit=True, now=now)
            if cached_media_hash is None:
                self.repository.attach_media_content_hash(
                    subject_hash=subject_hash,
                    fingerprint_hash=fingerprint_hash,
                    analysis_version=self.analysis_version,
                    media_content_sha256=media_content_sha256,
                    now=now,
                )
                cached["media_content_sha256"] = media_content_sha256
                cached = self._enrich_voice_activity(
                    cached,
                    subject_hash=subject_hash,
                    fingerprint_hash=fingerprint_hash,
                    voice_activity=voice_activity,
                    now=now,
                )
                return self._response(cached, cache_hit=True, now=now)

        identical = None if force_refresh else self.repository.alias_cached_audio(
            subject_hash=subject_hash,
            fingerprint_hash=fingerprint_hash,
            audio_sha256=audio_sha256,
            media_content_sha256=media_content_sha256,
            version=self.analysis_version,
            now=now,
        )
        if identical:
            identical = self._enrich_voice_activity(
                identical,
                subject_hash=subject_hash,
                fingerprint_hash=fingerprint_hash,
                voice_activity=voice_activity,
                now=now,
            )
            return self._response(identical, cache_hit=True, now=now)

        reserve_seconds = sum(
            max(1, math.ceil(chunk.duration_seconds)) for chunk in ordered_chunks
        )
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
        identical_after_claim = None if force_refresh else self.repository.alias_cached_audio(
            subject_hash=subject_hash,
            fingerprint_hash=fingerprint_hash,
            audio_sha256=audio_sha256,
            media_content_sha256=media_content_sha256,
            version=self.analysis_version,
            now=now,
        )
        if identical_after_claim:
            self.repository.release(operation_id, now)
            identical_after_claim = self._enrich_voice_activity(
                identical_after_claim,
                subject_hash=subject_hash,
                fingerprint_hash=fingerprint_hash,
                voice_activity=voice_activity,
                now=now,
            )
            return self._response(identical_after_claim, cache_hit=True, now=now)

        acquired = self._semaphore.acquire(timeout=self.config.timeout_seconds)
        if not acquired:
            self.repository.release(operation_id, now)
            raise ServerBusyError()
        recognitions = []
        provider_billed_seconds = 0
        try:
            for position, chunk in enumerate(ordered_chunks, start=1):
                if on_chunk:
                    on_chunk(position, len(ordered_chunks))
                self._provider_request_limiter.wait_for_slot()
                recognition = self.client.recognize(chunk.audio, chunk.voice_format)
                if recognition.duration_seconds <= 0:
                    raise TencentAsrError("Tencent ASR returned an invalid duration")
                provider_billed_seconds += max(
                    1, math.ceil(recognition.duration_seconds)
                )
                recognitions.append(recognition)

            maximum_with_padding = reserve_seconds + 2 * len(ordered_chunks)
            if provider_billed_seconds > maximum_with_padding:
                raise TencentAsrError(
                    "Tencent ASR chunk durations exceeded the extracted timeline"
                )
            transcript, segments = merge_chunk_recognitions(
                ordered_chunks,
                recognitions,
                duration_seconds=duration_seconds,
            )
            segments = annotate_asr_segments(
                segments,
                voice_activity,
                minimum_suspicious_words=(
                    self.config.local_voice_activity_minimum_suspicious_words
                ),
                maximum_low_activity_coverage=(
                    self.config.local_voice_activity_maximum_low_coverage
                ),
            )
            segments = annotate_audio_preprocessing(
                segments,
                audio_preprocessing,
            )
            billed_seconds = min(reserve_seconds, provider_billed_seconds)
            usage = self.repository.complete(
                operation_id=operation_id,
                subject_hash=subject_hash,
                fingerprint_hash=fingerprint_hash,
                analysis_version=self.analysis_version,
                audio_sha256=audio_sha256,
                media_content_sha256=media_content_sha256,
                engine_type=self.config.engine_type,
                duration_seconds=duration_seconds,
                transcript=transcript,
                segments=segments,
                monthly_limit=self.config.monthly_limit_seconds,
                now=now,
                provider_billed_seconds=billed_seconds,
                provider_request_count=len(recognitions),
            )
            return response_payload(
                cache_hit=False,
                engine_type=self.config.engine_type,
                duration_seconds=duration_seconds,
                transcript=transcript,
                segments=segments,
                audio_sha256=audio_sha256,
                media_content_sha256=media_content_sha256,
                usage=usage,
            )
        except Exception:
            if recognitions:
                self.repository.settle_failed_provider_usage(
                    operation_id=operation_id,
                    subject_hash=subject_hash,
                    billed_seconds=min(reserve_seconds, provider_billed_seconds),
                    provider_request_count=len(recognitions),
                    now=now,
                )
            else:
                self.repository.release(operation_id, now)
            raise
        finally:
            self._semaphore.release()

    def _validate_chunked(
        self,
        operation_id: str,
        media_fingerprint: str,
        duration_seconds: float,
        audio: bytes,
        chunks: Sequence[AsrAudioChunk],
    ) -> None:
        if not OPERATION_PATTERN.fullmatch(operation_id):
            raise AudioValidationError("Invalid operation id")
        if not 8 <= len(media_fingerprint) <= 512:
            raise AudioValidationError("Invalid media fingerprint")
        if not 0 < duration_seconds <= 86_400 or not audio:
            raise AudioValidationError("Invalid complete audio timeline")
        if not chunks:
            raise AudioValidationError("ASR chunks are required")
        previous_offset = -1.0
        for expected_index, chunk in enumerate(sorted(chunks, key=lambda value: value.index)):
            if chunk.index != expected_index or chunk.offset_seconds <= previous_offset:
                raise AudioValidationError("ASR chunk order is invalid")
            if chunk.voice_format not in ALLOWED_FORMATS:
                raise AudioValidationError("Unsupported audio format")
            if not 0 < chunk.duration_seconds <= self.config.max_audio_seconds:
                raise AudioValidationError("ASR chunk duration exceeds the provider limit")
            if not chunk.audio or len(chunk.audio) > self.config.max_audio_bytes:
                raise AudioValidationError("ASR chunk size exceeds the provider limit")
            if chunk.offset_seconds < 0 or chunk.end_seconds > duration_seconds + 0.25:
                raise AudioValidationError("ASR chunk falls outside the song timeline")
            previous_offset = chunk.offset_seconds

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
            audio_sha256=cached.get("audio_sha256"),
            media_content_sha256=cached.get("media_content_sha256"),
            usage=usage,
        )

    def _enrich_voice_activity(
        self,
        cached: dict,
        *,
        subject_hash: str,
        fingerprint_hash: str,
        voice_activity,
        now: datetime,
    ) -> dict:
        if voice_activity is None:
            return cached
        annotated = annotate_asr_segments(
            cached["segments"],
            voice_activity,
            minimum_suspicious_words=(
                self.config.local_voice_activity_minimum_suspicious_words
            ),
            maximum_low_activity_coverage=(
                self.config.local_voice_activity_maximum_low_coverage
            ),
        )
        if annotated != cached["segments"]:
            self.repository.update_cached_segments(
                subject_hash=subject_hash,
                fingerprint_hash=fingerprint_hash,
                analysis_version=self.analysis_version,
                segments=annotated,
                now=now,
            )
        return {**cached, "segments": annotated}


def merge_chunk_recognitions(
    chunks: Sequence[AsrAudioChunk],
    recognitions: Sequence,
    *,
    duration_seconds: float,
) -> tuple[str, list[dict]]:
    """Offset chunk-local words and deterministically assign each overlap to one chunk.

    Adjacent chunks meet at the midpoint of their overlap. Text equality is never a
    reason to remove performances at different times; the narrow duplicate guard only
    removes equal tokens from different chunks when their original time ranges overlap.
    """
    if len(chunks) != len(recognitions) or not chunks:
        raise TencentAsrError("Tencent ASR chunk result count is invalid")
    ordered = sorted(zip(chunks, recognitions), key=lambda value: value[0].index)
    ownership = []
    for position, (chunk, _) in enumerate(ordered):
        owner_start = chunk.offset_seconds
        owner_end = chunk.end_seconds
        if position > 0:
            previous = ordered[position - 1][0]
            if chunk.offset_seconds < previous.end_seconds:
                owner_start = (previous.end_seconds + chunk.offset_seconds) / 2
        if position + 1 < len(ordered):
            following = ordered[position + 1][0]
            if following.offset_seconds < chunk.end_seconds:
                owner_end = (chunk.end_seconds + following.offset_seconds) / 2
        ownership.append((owner_start, owner_end))

    word_candidates: list[dict] = []
    text_candidates: list[dict] = []
    for position, (chunk, recognition) in enumerate(ordered):
        owner_start, owner_end = ownership[position]
        for segment_index, segment in enumerate(recognition.segments):
            try:
                local_segment_start = float(segment.get("start_seconds", 0))
                local_segment_end = float(segment.get("end_seconds", 0))
            except (TypeError, ValueError):
                continue
            raw_words = segment.get("words") or []
            for word_index, word in enumerate(raw_words):
                text = " ".join(str(word.get("text") or "").split())
                try:
                    raw_start = chunk.offset_seconds + float(word["start_seconds"])
                    raw_end = chunk.offset_seconds + float(word["end_seconds"])
                except (KeyError, TypeError, ValueError):
                    continue
                if not text or raw_start < chunk.offset_seconds - 0.25 or raw_end < raw_start:
                    continue
                midpoint = (raw_start + raw_end) / 2
                inside_owner = owner_start <= midpoint and (
                    midpoint < owner_end or position == len(ordered) - 1
                )
                if not inside_owner:
                    continue
                start = max(owner_start, chunk.offset_seconds, raw_start)
                end = min(owner_end, chunk.end_seconds, duration_seconds, raw_end)
                if end < start:
                    continue
                word_candidates.append({
                    "text": text,
                    "normalized": _normalized_word(text),
                    "start_seconds": start,
                    "end_seconds": end,
                    "raw_start_seconds": raw_start,
                    "raw_end_seconds": raw_end,
                    "chunk_index": chunk.index,
                    "group": (chunk.index, segment_index),
                    "order": word_index,
                })

            segment_text = " ".join(str(segment.get("text") or "").split())
            if not raw_words and segment_text:
                raw_start = chunk.offset_seconds + local_segment_start
                raw_end = chunk.offset_seconds + max(
                    local_segment_start, local_segment_end
                )
                midpoint = (raw_start + raw_end) / 2
                if owner_start <= midpoint and (
                    midpoint < owner_end or position == len(ordered) - 1
                ):
                    text_candidates.append({
                        "text": segment_text,
                        "start_seconds": max(owner_start, chunk.offset_seconds, raw_start),
                        "end_seconds": min(
                            owner_end, chunk.end_seconds, duration_seconds, raw_end
                        ),
                    })

    word_candidates.sort(key=lambda value: (
        value["start_seconds"],
        value["end_seconds"],
        value["chunk_index"],
        value["order"],
    ))
    words: list[dict] = []
    for candidate in word_candidates:
        duplicate = False
        for previous in reversed(words[-12:]):
            if (
                previous["chunk_index"] != candidate["chunk_index"]
                and previous["normalized"]
                and previous["normalized"] == candidate["normalized"]
                and _ranges_overlap(
                    previous["raw_start_seconds"],
                    previous["raw_end_seconds"],
                    candidate["raw_start_seconds"],
                    candidate["raw_end_seconds"],
                )
            ):
                duplicate = True
                break
        if duplicate:
            continue
        start = candidate["start_seconds"]
        if words:
            start = max(start, words[-1]["end_seconds"])
        if candidate["end_seconds"] < start:
            continue
        words.append({**candidate, "start_seconds": start})

    segments: list[dict] = []
    for word in words:
        public_word = {
            "text": word["text"],
            "start_seconds": word["start_seconds"],
            "end_seconds": word["end_seconds"],
        }
        if segments and segments[-1]["group"] == word["group"]:
            segments[-1]["words"].append(public_word)
            segments[-1]["text"] = " ".join(
                value["text"] for value in segments[-1]["words"]
            )
            segments[-1]["end_seconds"] = public_word["end_seconds"]
        else:
            segments.append({
                "group": word["group"],
                "text": public_word["text"],
                "start_seconds": public_word["start_seconds"],
                "end_seconds": public_word["end_seconds"],
                "words": [public_word],
            })

    for candidate in text_candidates:
        if candidate["end_seconds"] < candidate["start_seconds"]:
            continue
        if any(
            _ranges_overlap(
                candidate["start_seconds"],
                candidate["end_seconds"],
                segment["start_seconds"],
                segment["end_seconds"],
            )
            for segment in segments
        ):
            continue
        segments.append({**candidate, "group": None, "words": []})

    if not segments:
        for position, (chunk, recognition) in enumerate(ordered):
            text = " ".join(str(recognition.transcript or "").split())
            if not text:
                continue
            owner_start, owner_end = ownership[position]
            segments.append({
                "group": None,
                "text": text,
                "start_seconds": owner_start,
                "end_seconds": owner_end,
                "words": [],
            })

    segments.sort(key=lambda value: (value["start_seconds"], value["end_seconds"]))
    public_segments = []
    previous_end = 0.0
    for segment in segments:
        start = max(previous_end, float(segment["start_seconds"]))
        end = max(start, min(duration_seconds, float(segment["end_seconds"])))
        if segment["words"] and start > segment["words"][0]["start_seconds"]:
            segment["words"][0]["start_seconds"] = start
        public_segments.append({
            "text": segment["text"],
            "start_seconds": start,
            "end_seconds": end,
            "words": segment["words"],
        })
        previous_end = end
    transcript = " ".join(
        segment["text"] for segment in public_segments if segment["text"]
    )
    if not transcript:
        raise TencentAsrError("Tencent ASR returned no usable chunk transcript")
    return transcript, public_segments


def _normalized_word(value: str) -> str:
    return "".join(character for character in value.casefold() if character.isalnum())


def _ranges_overlap(
    left_start: float,
    left_end: float,
    right_start: float,
    right_end: float,
) -> bool:
    return min(left_end, right_end) > max(left_start, right_start)


def fingerprint(value: str) -> str:
    return hashlib.sha256(value.strip().encode("utf-8")).hexdigest()


def annotate_audio_preprocessing(
    segments: list[dict],
    evidence: dict | None,
) -> list[dict]:
    """Persist non-secret local audio-source identity with the ASR timeline."""
    if not evidence:
        return segments
    allowed = {
        "source": str(evidence.get("source") or "")[:128],
        "decode": str(evidence.get("decode") or "")[:128],
        "separator": str(evidence.get("separator") or "")[:128] or None,
        "model": str(evidence.get("model") or "")[:256] or None,
        "vocal_coverage": evidence.get("vocal_coverage"),
        "vocal_mean_probability": evidence.get("vocal_mean_probability"),
        "planner_version": str(evidence.get("planner_version") or "")[:128] or None,
        "planner_status": str(evidence.get("planner_status") or "")[:64] or None,
        "planner_fallback_reason": (
            str(evidence.get("planner_fallback_reason") or "")[:128] or None
        ),
        "media_duration_seconds": evidence.get("media_duration_seconds"),
        "analysis_duration_seconds": evidence.get("analysis_duration_seconds"),
        "raw_vocal_seconds": evidence.get("raw_vocal_seconds"),
        "planned_asr_seconds": evidence.get("planned_asr_seconds"),
        "saved_asr_seconds": evidence.get("saved_asr_seconds"),
        "asr_window_count": evidence.get("asr_window_count"),
        "smart_intro_end_seconds": evidence.get("smart_intro_end_seconds"),
        "smart_outro_start_seconds": evidence.get("smart_outro_start_seconds"),
    }
    return [
        {**segment, "audio_preprocessing": allowed}
        for segment in segments
    ]


def audio_preprocessing_summary(segments: list[dict]) -> dict | None:
    return next(
        (
            dict(segment["audio_preprocessing"])
            for segment in segments
            if isinstance(segment.get("audio_preprocessing"), dict)
        ),
        None,
    )


def voice_window_plan_summary(segments: list[dict]) -> dict | None:
    preprocessing = audio_preprocessing_summary(segments)
    if not preprocessing or not preprocessing.get("planner_status"):
        return None
    return {
        "planner_version": preprocessing.get("planner_version") or "unknown",
        "planner_status": preprocessing["planner_status"],
        "fallback_reason": preprocessing.get("planner_fallback_reason"),
        "media_duration_seconds": preprocessing.get("media_duration_seconds"),
        "analysis_duration_seconds": preprocessing.get("analysis_duration_seconds"),
        "raw_vocal_seconds": preprocessing.get("raw_vocal_seconds") or 0,
        "planned_asr_seconds": preprocessing.get("planned_asr_seconds") or 0,
        "saved_asr_seconds": preprocessing.get("saved_asr_seconds") or 0,
        "asr_window_count": preprocessing.get("asr_window_count") or 0,
        "smart_intro_end_seconds": preprocessing.get("smart_intro_end_seconds"),
        "smart_outro_start_seconds": preprocessing.get("smart_outro_start_seconds"),
    }


def response_payload(
    *, cache_hit: bool, engine_type: str, duration_seconds: float,
    transcript: str, segments: list[dict], audio_sha256: str | None,
    media_content_sha256: str | None, usage: Usage,
) -> dict:
    return {
        "status": "cached" if cache_hit else "completed",
        "cache_hit": cache_hit,
        "provider": "tencent_flash_asr",
        "engine_type": engine_type,
        "audio_duration_seconds": duration_seconds,
        "transcript": transcript,
        "segments": segments,
        "voice_activity": voice_activity_summary(segments),
        "audio_preprocessing": audio_preprocessing_summary(segments),
        "voice_window_plan": voice_window_plan_summary(segments),
        "audio_sha256": audio_sha256,
        "media_content_sha256": media_content_sha256,
        "monthly_used_seconds": usage.used_seconds,
        "monthly_reserved_seconds": usage.reserved_seconds,
        "monthly_limit_seconds": usage.limit_seconds,
    }
