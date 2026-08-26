"""Pure VAD window planning for sparse ASR and conservative skip candidates.

The planner owns no audio, network, database, or playback state.  Its ASR windows
remain on the original media timeline; callers may later clip them to an analysis
window without concatenating away the gaps.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from app.voice_activity import VoiceActivityEvidence


PLANNER_VERSION = "voice-window-planner-v1"


@dataclass(frozen=True)
class VoiceWindowPlannerConfig:
    minimum_speech_seconds: float = 0.18
    merge_gap_seconds: float = 2.0
    padding_before_seconds: float = 1.5
    padding_after_seconds: float = 1.5
    stable_body_gap_seconds: float = 4.0
    stable_body_minimum_span_seconds: float = 10.0
    stable_body_minimum_speech_seconds: float = 6.0
    stable_body_minimum_density: float = 0.35
    boundary_safety_seconds: float = 1.0
    minimum_skip_seconds: float = 3.0
    maximum_window_count: int = 32


@dataclass(frozen=True)
class VoiceWindow:
    start_seconds: float
    end_seconds: float

    @property
    def duration_seconds(self) -> float:
        return self.end_seconds - self.start_seconds

    @property
    def offset_seconds(self) -> float:
        return self.start_seconds


@dataclass(frozen=True)
class VoiceWindowPlan:
    media_duration_seconds: float
    smart_intro_end_seconds: float | None
    smart_outro_start_seconds: float | None
    asr_windows: tuple[VoiceWindow, ...]
    raw_vocal_seconds: float
    planned_asr_seconds: float
    planner_status: str
    fallback_reason: str | None = None

    @property
    def saved_asr_seconds(self) -> float:
        return max(0.0, self.media_duration_seconds - self.planned_asr_seconds)

    def diagnostics(self) -> dict:
        return {
            "planner_version": PLANNER_VERSION,
            "planner_status": self.planner_status,
            "planner_fallback_reason": self.fallback_reason,
            "media_duration_seconds": round(self.media_duration_seconds, 3),
            "raw_vocal_seconds": round(self.raw_vocal_seconds, 3),
            "planned_asr_seconds": round(self.planned_asr_seconds, 3),
            "saved_asr_seconds": round(self.saved_asr_seconds, 3),
            "asr_window_count": len(self.asr_windows),
            "smart_intro_end_seconds": self.smart_intro_end_seconds,
            "smart_outro_start_seconds": self.smart_outro_start_seconds,
        }


class VoiceWindowPlanner:
    def __init__(self, config: VoiceWindowPlannerConfig | None = None) -> None:
        raw = config or VoiceWindowPlannerConfig()
        self.config = VoiceWindowPlannerConfig(
            minimum_speech_seconds=max(0.0, raw.minimum_speech_seconds),
            merge_gap_seconds=max(0.0, raw.merge_gap_seconds),
            padding_before_seconds=max(0.0, raw.padding_before_seconds),
            padding_after_seconds=max(0.0, raw.padding_after_seconds),
            stable_body_gap_seconds=max(0.0, raw.stable_body_gap_seconds),
            stable_body_minimum_span_seconds=max(
                0.0, raw.stable_body_minimum_span_seconds
            ),
            stable_body_minimum_speech_seconds=max(
                0.0, raw.stable_body_minimum_speech_seconds
            ),
            stable_body_minimum_density=min(
                1.0, max(0.0, raw.stable_body_minimum_density)
            ),
            boundary_safety_seconds=max(0.0, raw.boundary_safety_seconds),
            minimum_skip_seconds=max(0.0, raw.minimum_skip_seconds),
            maximum_window_count=max(1, raw.maximum_window_count),
        )

    def plan(
        self,
        *,
        media_duration_seconds: float,
        evidence: VoiceActivityEvidence,
    ) -> VoiceWindowPlan:
        duration = float(media_duration_seconds)
        if not math.isfinite(duration) or duration <= 0:
            return self._fallback(max(0.0, duration), "invalid_media_duration")

        normalized = _normalized_intervals(
            evidence.speech_intervals,
            duration_seconds=duration,
        )
        retained = tuple(
            window for window in normalized
            if window.duration_seconds >= self.config.minimum_speech_seconds
        )
        if not retained:
            return self._fallback(duration, "no_valid_speech_intervals")

        raw_vocal_seconds = sum(window.duration_seconds for window in retained)
        merged = _merge_windows(retained, self.config.merge_gap_seconds)
        padded = tuple(
            VoiceWindow(
                max(0.0, window.start_seconds - self.config.padding_before_seconds),
                min(duration, window.end_seconds + self.config.padding_after_seconds),
            )
            for window in merged
        )
        # Padding can leave a tiny residual gap (for example a 4.8 s raw gap
        # becomes 1.8 s). Sending a separate provider request to save that sliver
        # is both inefficient and more likely to cut a lyric boundary.
        asr_windows = _merge_windows(padded, self.config.merge_gap_seconds)
        if (
            not asr_windows
            or len(asr_windows) > self.config.maximum_window_count
            or any(
                window.start_seconds < 0
                or window.end_seconds > duration + 0.001
                or window.duration_seconds <= 0
                for window in asr_windows
            )
        ):
            return self._fallback(duration, "invalid_window_plan")

        planned_seconds = sum(window.duration_seconds for window in asr_windows)
        stable_bodies = tuple(
            window
            for window in _merge_windows(
                retained,
                self.config.stable_body_gap_seconds,
            )
            if self._is_stable_body(window, retained)
        )
        intro, outro = self._smart_boundaries(stable_bodies, duration)
        status = "sparse" if planned_seconds < duration - 0.05 else "full_coverage"
        return VoiceWindowPlan(
            media_duration_seconds=duration,
            smart_intro_end_seconds=intro,
            smart_outro_start_seconds=outro,
            asr_windows=asr_windows,
            raw_vocal_seconds=raw_vocal_seconds,
            planned_asr_seconds=planned_seconds,
            planner_status=status,
        )

    def _is_stable_body(
        self,
        body: VoiceWindow,
        speech: tuple[VoiceWindow, ...],
    ) -> bool:
        speech_seconds = sum(
            max(
                0.0,
                min(body.end_seconds, item.end_seconds)
                - max(body.start_seconds, item.start_seconds),
            )
            for item in speech
        )
        density = speech_seconds / max(0.001, body.duration_seconds)
        return (
            body.duration_seconds >= self.config.stable_body_minimum_span_seconds
            and speech_seconds >= self.config.stable_body_minimum_speech_seconds
            and density >= self.config.stable_body_minimum_density
        )

    def _smart_boundaries(
        self,
        stable_bodies: tuple[VoiceWindow, ...],
        duration_seconds: float,
    ) -> tuple[float | None, float | None]:
        if not stable_bodies:
            return None, None
        first = stable_bodies[0]
        last = stable_bodies[-1]
        intro = max(0.0, first.start_seconds - self.config.boundary_safety_seconds)
        outro = min(
            duration_seconds,
            last.end_seconds + self.config.boundary_safety_seconds,
        )
        if intro < self.config.minimum_skip_seconds:
            intro = None
        if duration_seconds - outro < self.config.minimum_skip_seconds:
            outro = None
        return intro, outro

    @staticmethod
    def _fallback(duration_seconds: float, reason: str) -> VoiceWindowPlan:
        return VoiceWindowPlan(
            media_duration_seconds=duration_seconds,
            smart_intro_end_seconds=None,
            smart_outro_start_seconds=None,
            asr_windows=(),
            raw_vocal_seconds=0.0,
            planned_asr_seconds=duration_seconds,
            planner_status="fallback",
            fallback_reason=reason,
        )


def _normalized_intervals(
    intervals: tuple[tuple[float, float], ...],
    *,
    duration_seconds: float,
) -> tuple[VoiceWindow, ...]:
    values = []
    for raw_start, raw_end in intervals:
        try:
            start = float(raw_start)
            end = float(raw_end)
        except (TypeError, ValueError):
            continue
        if not math.isfinite(start) or not math.isfinite(end):
            continue
        start = min(duration_seconds, max(0.0, start))
        end = min(duration_seconds, max(0.0, end))
        if end > start:
            values.append(VoiceWindow(start, end))
    return _merge_windows(tuple(values), 0.0)


def _merge_windows(
    windows: tuple[VoiceWindow, ...],
    maximum_gap_seconds: float,
) -> tuple[VoiceWindow, ...]:
    if not windows:
        return ()
    ordered = sorted(windows, key=lambda value: (value.start_seconds, value.end_seconds))
    merged = [ordered[0]]
    for window in ordered[1:]:
        previous = merged[-1]
        if window.start_seconds <= previous.end_seconds + max(0.0, maximum_gap_seconds):
            merged[-1] = VoiceWindow(
                previous.start_seconds,
                max(previous.end_seconds, window.end_seconds),
            )
        else:
            merged.append(window)
    return tuple(merged)


__all__ = [
    "PLANNER_VERSION",
    "VoiceWindow",
    "VoiceWindowPlan",
    "VoiceWindowPlanner",
    "VoiceWindowPlannerConfig",
]
