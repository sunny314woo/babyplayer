import pytest

from app.local_analysis import plan_audio_chunks_for_windows
from app.voice_activity import VoiceActivityEvidence
from app.voice_window_planner import (
    VoiceWindow,
    VoiceWindowPlanner,
    VoiceWindowPlannerConfig,
)


def evidence(duration, intervals, *, probability=0.8):
    return VoiceActivityEvidence(
        detector="test-vad",
        scope="vocal_stem_gate",
        threshold=0.15,
        frame_seconds=1.0,
        probabilities=(probability,) * int(duration),
        speech_intervals=tuple(intervals),
    )


def test_planner_filters_noise_merges_short_gaps_and_adds_padding() -> None:
    plan = VoiceWindowPlanner().plan(
        media_duration_seconds=180,
        evidence=evidence(180, (
            (2.0, 2.05),
            (12.1, 18.4),
            (18.9, 24.7),
            (25.5, 31.3),
            (60.0, 120.0),
        )),
    )

    assert plan.planner_status == "sparse"
    assert plan.asr_windows == (
        VoiceWindow(10.6, 32.8),
        VoiceWindow(58.5, 121.5),
    )
    assert plan.raw_vocal_seconds == pytest.approx(77.9)
    assert plan.planned_asr_seconds == pytest.approx(85.2)


def test_stable_body_ignores_logo_and_isolated_tail_voice() -> None:
    planner = VoiceWindowPlanner(VoiceWindowPlannerConfig(
        stable_body_minimum_span_seconds=10,
        stable_body_minimum_speech_seconds=6,
        stable_body_minimum_density=0.35,
    ))
    plan = planner.plan(
        media_duration_seconds=190,
        evidence=evidence(190, (
            (0.0, 1.2),
            (10.0, 35.0),
            (36.0, 70.0),
            (75.0, 110.0),
            (115.0, 164.0),
            (176.0, 178.0),
        )),
    )

    assert plan.smart_intro_end_seconds == pytest.approx(9.0)
    assert plan.smart_outro_start_seconds == pytest.approx(165.0)


def test_boundary_candidates_are_nil_when_only_short_voice_exists() -> None:
    plan = VoiceWindowPlanner().plan(
        media_duration_seconds=30,
        evidence=evidence(30, ((1.0, 2.0), (25.0, 26.0))),
    )

    assert plan.planner_status == "sparse"
    assert plan.smart_intro_end_seconds is None
    assert plan.smart_outro_start_seconds is None


def test_padding_residual_short_gap_does_not_create_extra_provider_window() -> None:
    plan = VoiceWindowPlanner().plan(
        media_duration_seconds=100,
        evidence=evidence(100, ((10.0, 30.0), (34.8, 60.0))),
    )

    assert plan.asr_windows == (VoiceWindow(8.5, 61.5),)


def test_no_valid_window_requests_complete_asr_fallback() -> None:
    plan = VoiceWindowPlanner().plan(
        media_duration_seconds=30,
        evidence=evidence(30, ((1.0, 1.05),)),
    )

    assert plan.planner_status == "fallback"
    assert plan.fallback_reason == "no_valid_speech_intervals"
    assert plan.asr_windows == ()
    assert plan.planned_asr_seconds == 30


def test_sparse_chunk_offsets_remain_relative_to_existing_song_timeline() -> None:
    chunks = plan_audio_chunks_for_windows(
        (VoiceWindow(13.5, 46.5), VoiceWindow(68.5, 141.5)),
        timeline_start_seconds=10,
        timeline_end_seconds=150,
        chunk_seconds=60,
        overlap_seconds=5,
    )

    assert [
        (value.index, value.offset_seconds, value.source_start_seconds, value.duration_seconds)
        for value in chunks
    ] == [
        (0, 3.5, 13.5, 33.0),
        (1, 58.5, 68.5, 60),
        (2, 113.5, 123.5, 18.0),
    ]
