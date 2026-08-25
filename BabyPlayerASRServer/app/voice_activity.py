"""Conservative mixed-audio voice activity evidence for ASR quality control.

This module deliberately treats VAD as advisory evidence. Music can look like speech and
isolated sung words can look like silence, so only a contiguous low-activity word run is
marked as a likely instrumental hallucination. Candidate lyrics can rescue such a run later.
"""

from __future__ import annotations

import io
import math
from dataclasses import dataclass
from importlib.util import find_spec


LOW_VOICE_ACTIVITY_FLAG = "low_voice_activity"
INSTRUMENTAL_HALLUCINATION_FLAG = "possible_instrumental_hallucination"
VAD_OWNED_FLAGS = {LOW_VOICE_ACTIVITY_FLAG, INSTRUMENTAL_HALLUCINATION_FLAG}


@dataclass(frozen=True)
class VoiceActivityEvidence:
    detector: str
    scope: str
    threshold: float
    frame_seconds: float
    probabilities: tuple[float, ...]
    speech_intervals: tuple[tuple[float, float], ...]

    def mean_score(self, start_seconds: float, end_seconds: float) -> float:
        if not self.probabilities:
            return 0.0
        start = max(0.0, float(start_seconds))
        end = max(start, float(end_seconds))
        first = max(0, int(math.floor(start / self.frame_seconds)))
        last = min(
            len(self.probabilities),
            max(first + 1, int(math.ceil(end / self.frame_seconds))),
        )
        values = self.probabilities[first:last]
        return sum(values) / len(values) if values else 0.0

    def speech_coverage(self, start_seconds: float, end_seconds: float) -> float:
        start = max(0.0, float(start_seconds))
        end = max(start, float(end_seconds))
        duration = max(0.001, end - start)
        overlap = sum(
            max(0.0, min(end, interval_end) - max(start, interval_start))
            for interval_start, interval_end in self.speech_intervals
        )
        return min(1.0, overlap / duration)


class SileroVoiceActivityDetector:
    """Runs the Silero model bundled with faster-whisper; no Whisper model is downloaded."""

    detector_name = "silero_vad_v6"
    scope = "mixed_audio_advisory"

    def __init__(
        self,
        *,
        threshold: float,
        min_speech_duration_ms: int = 150,
        min_silence_duration_ms: int = 400,
        speech_pad_ms: int = 500,
    ) -> None:
        self.threshold = max(0.01, min(0.99, float(threshold)))
        self.min_speech_duration_ms = max(0, int(min_speech_duration_ms))
        self.min_silence_duration_ms = max(0, int(min_silence_duration_ms))
        self.speech_pad_ms = max(0, int(speech_pad_ms))

    @staticmethod
    def available() -> bool:
        return find_spec("faster_whisper") is not None

    def analyze(self, audio: bytes, *, duration_seconds: float) -> VoiceActivityEvidence:
        del duration_seconds  # The decoded sample count is the authoritative VAD timeline.
        if not self.available():
            raise RuntimeError("faster-whisper is not installed")

        import numpy as np
        from faster_whisper.audio import decode_audio
        from faster_whisper.vad import VadOptions, get_speech_timestamps, get_vad_model

        sampling_rate = 16_000
        samples_per_frame = 512
        samples = decode_audio(io.BytesIO(audio), sampling_rate=sampling_rate)
        if samples.size == 0:
            raise RuntimeError("voice activity input is empty")
        padding = (-samples.shape[0]) % samples_per_frame
        padded = np.pad(samples, (0, padding)) if padding else samples
        probabilities = get_vad_model()(padded, num_samples=samples_per_frame)
        chunks = get_speech_timestamps(
            samples,
            VadOptions(
                threshold=self.threshold,
                min_speech_duration_ms=self.min_speech_duration_ms,
                min_silence_duration_ms=self.min_silence_duration_ms,
                speech_pad_ms=self.speech_pad_ms,
            ),
            sampling_rate=sampling_rate,
        )
        return VoiceActivityEvidence(
            detector=self.detector_name,
            scope=self.scope,
            threshold=self.threshold,
            frame_seconds=samples_per_frame / sampling_rate,
            probabilities=tuple(float(value) for value in probabilities),
            speech_intervals=tuple(
                (chunk["start"] / sampling_rate, chunk["end"] / sampling_rate)
                for chunk in chunks
            ),
        )


def annotate_asr_segments(
    segments: list[dict],
    evidence: VoiceActivityEvidence | None,
    *,
    minimum_suspicious_words: int,
    maximum_low_activity_coverage: float,
) -> list[dict]:
    """Add bounded quality metadata without deleting or retiming provider words."""
    if evidence is None:
        return segments

    annotated_segments = []
    minimum_run = max(2, int(minimum_suspicious_words))
    maximum_coverage = max(0.0, min(1.0, float(maximum_low_activity_coverage)))
    for raw_segment in segments:
        segment = dict(raw_segment)
        words = []
        low_activity = []
        for raw_word in raw_segment.get("words") or []:
            word = dict(raw_word)
            try:
                start = float(word["start_seconds"])
                end = float(word["end_seconds"])
            except (KeyError, TypeError, ValueError):
                words.append(word)
                low_activity.append(False)
                continue
            score = evidence.mean_score(start, end)
            coverage = evidence.speech_coverage(start, end)
            # These two flags are derived from the current audio evidence. Remove
            # stale values first so a cache re-enrichment can also clear a former
            # false positive after the detector/model/threshold changes.
            flags = [
                value
                for value in dict.fromkeys(
                    str(value) for value in word.get("quality_flags") or []
                )
                if value not in VAD_OWNED_FLAGS
            ]
            is_low = score < evidence.threshold and coverage < maximum_coverage
            if is_low and LOW_VOICE_ACTIVITY_FLAG not in flags:
                flags.append(LOW_VOICE_ACTIVITY_FLAG)
            word.update({
                "voice_activity_score": round(score, 4),
                "voice_activity_coverage": round(coverage, 4),
                "quality_flags": flags,
            })
            words.append(word)
            low_activity.append(is_low)

        suspicious_indices: set[int] = set()
        run_start = None
        for index, is_low in enumerate([*low_activity, False]):
            if is_low and run_start is None:
                run_start = index
            if not is_low and run_start is not None:
                if index - run_start >= minimum_run:
                    suspicious_indices.update(range(run_start, index))
                run_start = None
        for index in suspicious_indices:
            flags = words[index].setdefault("quality_flags", [])
            if INSTRUMENTAL_HALLUCINATION_FLAG not in flags:
                flags.append(INSTRUMENTAL_HALLUCINATION_FLAG)

        # A separated vocal track can still retain a short pitched residue that
        # Tencent renders as "BB .", "DD ." or "E." between real verses. Silero's
        # padded interval may cover that residue even when every raw score is weak.
        # Keep this extra gate narrow so ordinary short words and character names
        # are not suppressed.
        lexical_tokens = [
            "".join(
                character
                for character in str(word.get("text") or "").casefold()
                if character.isalnum()
            )
            for word in words
        ]
        substantive = [
            (token, word)
            for token, word in zip(lexical_tokens, words)
            if token
        ]
        common_short_words = {"a", "i", "he", "she", "we", "you", "me", "go", "no", "yes"}
        weak_isolated_residue = (
            evidence.scope == "vocal_stem_gate"
            and 0 < len(words) <= 2
            and bool(substantive)
            and all(
                word.get("voice_activity_score") is not None
                and float(word["voice_activity_score"]) < evidence.threshold
                for word in words
            )
            and all(
                (len(token) >= 2 and len(set(token)) == 1)
                or (len(token) == 1 and token not in {"a", "i"})
                or (
                    len(token) <= 3
                    and token not in common_short_words
                    and float(word.get("voice_activity_coverage") or 0)
                    < maximum_coverage
                )
                for token, word in substantive
            )
        )
        if weak_isolated_residue:
            suspicious_indices.update(range(len(words)))
            for word in words:
                flags = word.setdefault("quality_flags", [])
                if INSTRUMENTAL_HALLUCINATION_FLAG not in flags:
                    flags.append(INSTRUMENTAL_HALLUCINATION_FLAG)

        segment_flags = [
            value
            for value in dict.fromkeys(
                str(value) for value in segment.get("quality_flags") or []
            )
            if value not in VAD_OWNED_FLAGS
        ]
        if suspicious_indices and INSTRUMENTAL_HALLUCINATION_FLAG not in segment_flags:
            segment_flags.append(INSTRUMENTAL_HALLUCINATION_FLAG)
        segment.update({
            "words": words,
            "voice_activity_detector": evidence.detector,
            "voice_activity_scope": evidence.scope,
            "quality_flags": segment_flags,
        })
        annotated_segments.append(segment)
    return annotated_segments


def voice_activity_summary(segments: list[dict]) -> dict | None:
    words = [word for segment in segments for word in segment.get("words") or []]
    analyzed = [word for word in words if word.get("voice_activity_score") is not None]
    if not analyzed:
        return None
    low_count = sum(
        LOW_VOICE_ACTIVITY_FLAG in (word.get("quality_flags") or [])
        for word in analyzed
    )
    suspicious_count = sum(
        INSTRUMENTAL_HALLUCINATION_FLAG in (word.get("quality_flags") or [])
        for word in analyzed
    )
    first_segment = next(
        (segment for segment in segments if segment.get("voice_activity_detector")),
        {},
    )
    return {
        "status": "advisory",
        "detector": str(first_segment.get("voice_activity_detector") or "unknown"),
        "scope": str(first_segment.get("voice_activity_scope") or "mixed_audio_advisory"),
        "analyzed_word_count": len(analyzed),
        "low_activity_word_count": low_count,
        "suspicious_word_count": suspicious_count,
    }


__all__ = [
    "INSTRUMENTAL_HALLUCINATION_FLAG",
    "LOW_VOICE_ACTIVITY_FLAG",
    "SileroVoiceActivityDetector",
    "VoiceActivityEvidence",
    "annotate_asr_segments",
    "voice_activity_summary",
]
