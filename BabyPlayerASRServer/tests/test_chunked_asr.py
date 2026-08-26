from dataclasses import replace
from datetime import datetime, timezone

import pytest

from app.config import Settings
from app.database import AsrRepository, MonthlyLimitReachedError
from app.local_analysis import plan_audio_chunks
from app.service import (
    AsrAudioChunk,
    AsrService,
    ProviderRequestLimiter,
    fingerprint,
    merge_chunk_recognitions,
)
from app.tencent_asr import Recognition, TencentAsrError
from app.voice_activity import VoiceActivityEvidence


NOW = datetime(2026, 8, 24, 8, 0, tzinfo=timezone.utc)


def recognition(duration, words):
    return Recognition(
        request_id="fake-request",
        duration_seconds=duration,
        transcript=" ".join(word[0] for word in words),
        segments=[{
            "text": " ".join(word[0] for word in words),
            "start_seconds": words[0][1] if words else 0,
            "end_seconds": words[-1][2] if words else duration,
            "words": [
                {"text": text, "start_seconds": start, "end_seconds": end}
                for text, start, end in words
            ],
        }],
    )


def chunks():
    return (
        AsrAudioChunk(0, 0, 60, b"chunk-0"),
        AsrAudioChunk(1, 55, 60, b"chunk-1"),
        AsrAudioChunk(2, 110, 47.184, b"chunk-2"),
    )


def chunk_recognitions():
    return (
        recognition(60, [
            ("opening", 10.0, 10.4),
            ("round", 56.0, 56.4),
            ("edge", 57.2, 57.6),
            ("again", 58.0, 58.4),
        ]),
        recognition(60, [
            ("round", 1.0, 1.4),
            ("edge", 2.4, 2.8),
            ("again", 3.0, 3.4),
            ("round", 25.0, 25.4),
            ("chorus", 57.0, 57.4),
        ]),
        recognition(47.184, [
            ("chorus", 2.0, 2.4),
            ("round", 20.0, 20.4),
            ("finished", 46.0, 46.4),
        ]),
    )


def configured(tmp_path, *, monthly_limit=18_000):
    return replace(
        Settings(),
        database_path=str(tmp_path / "chunked.sqlite3"),
        analysis_version="test-asr-v1",
        asr_timeline_version="test-chunked-v1",
        local_asr_chunk_seconds=60,
        local_asr_chunk_overlap_seconds=5,
        max_audio_seconds=300,
        max_audio_bytes=1024,
        max_concurrency=1,
        requests_per_minute=100,
        monthly_limit_seconds=monthly_limit,
    )


class FakeChunkProvider:
    def __init__(self, *, fail_at=None):
        self.calls = []
        self.fail_at = fail_at
        self.responses = dict(zip(
            (b"chunk-0", b"chunk-1", b"chunk-2"),
            chunk_recognitions(),
        ))

    def recognize(self, audio, voice_format):
        self.calls.append(audio)
        assert voice_format == "m4a"
        if self.fail_at == len(self.calls):
            raise TencentAsrError("fake provider failure")
        return self.responses[audio]


def test_plans_the_wheels_as_three_overlapping_requests() -> None:
    windows = plan_audio_chunks(
        157.184,
        chunk_seconds=60,
        overlap_seconds=5,
    )

    assert [(value.offset_seconds, value.duration_seconds) for value in windows] == [
        (0.0, 60),
        (55.0, 60),
        (110.0, pytest.approx(47.184)),
    ]
    assert all(
        left.end_seconds - right.offset_seconds == pytest.approx(5)
        for left, right in zip(windows, windows[1:])
    )


def test_merge_offsets_words_deduplicates_only_overlap_and_keeps_real_repeats() -> None:
    transcript, segments = merge_chunk_recognitions(
        chunks(),
        chunk_recognitions(),
        duration_seconds=157.184,
    )
    words = [word for segment in segments for word in segment["words"]]

    assert [word["text"] for word in words] == [
        "opening", "round", "edge", "again", "round", "chorus", "round", "finished"
    ]
    assert transcript == "opening round edge again round chorus round finished"
    assert [word["start_seconds"] for word in words if word["text"] == "round"] == [
        pytest.approx(56.0), pytest.approx(80.0), pytest.approx(130.0)
    ]
    assert all(
        left["end_seconds"] <= right["start_seconds"]
        for left, right in zip(words, words[1:])
    )
    assert all(
        left["end_seconds"] <= right["start_seconds"]
        for left, right in zip(segments, segments[1:])
    )
    assert segments[-1]["end_seconds"] <= 157.184


def test_sparse_gap_keeps_later_provider_timestamp_on_original_timeline() -> None:
    sparse_chunks = (
        AsrAudioChunk(0, 13.5, 33.0, b"window-a"),
        AsrAudioChunk(1, 58.5, 30.0, b"window-b"),
    )
    transcript, segments = merge_chunk_recognitions(
        sparse_chunks,
        (
            recognition(33.0, [("first", 2.0, 2.5)]),
            recognition(30.0, [("later", 3.2, 3.7)]),
        ),
        duration_seconds=120,
    )
    words = [word for segment in segments for word in segment["words"]]

    assert transcript == "first later"
    assert words[0]["start_seconds"] == pytest.approx(15.5)
    assert words[1]["start_seconds"] == pytest.approx(61.7)
    assert words[1]["end_seconds"] == pytest.approx(62.2)
    assert segments[0]["end_seconds"] < segments[1]["start_seconds"]


def test_chunked_service_calls_provider_sequentially_then_reuses_merged_cache(tmp_path) -> None:
    config = configured(tmp_path)
    repository = AsrRepository(config.database_path)
    repository.initialize()
    provider = FakeChunkProvider()
    service = AsrService(repository, provider, config)
    arguments = {
        "subject_hash": "subject",
        "operation_id": "operation-chunked-1",
        "media_fingerprint": "media-fingerprint-chunked",
        "duration_seconds": 157.184,
        "audio": b"complete-song-audio",
        "chunks": chunks(),
        "force_refresh": False,
        "now": NOW,
        "media_content_sha256": "source-video-sha256",
    }

    first = service.analyze_chunked(**arguments)
    cached = service.analyze_chunked(**{
        **arguments,
        "operation_id": "operation-chunked-2",
    })

    assert provider.calls == [b"chunk-0", b"chunk-1", b"chunk-2"]
    assert first["cache_hit"] is False
    assert first["audio_duration_seconds"] == pytest.approx(157.184)
    assert first["monthly_used_seconds"] == 168
    assert cached["cache_hit"] is True
    assert cached["segments"] == first["segments"]
    assert service.analysis_version.endswith("test-chunked-v1|60s-5s")


def test_vocal_separation_pipeline_has_a_distinct_asr_cache_identity(tmp_path) -> None:
    mixed = AsrService(
        AsrRepository(str(tmp_path / "mixed.sqlite3")),
        FakeChunkProvider(),
        configured(tmp_path),
    )
    vocal_config = replace(
        configured(tmp_path),
        local_vocal_separation_enabled=True,
        local_vocal_separation_version="separator-model-v2",
    )
    vocal = AsrService(
        AsrRepository(str(tmp_path / "vocal.sqlite3")),
        FakeChunkProvider(),
        vocal_config,
    )

    assert mixed.analysis_version != vocal.analysis_version
    assert "source:separator-model-v2" in vocal.analysis_version


def test_cached_tencent_timeline_can_gain_vad_evidence_without_provider_charge(tmp_path) -> None:
    config = configured(tmp_path)
    repository = AsrRepository(config.database_path)
    repository.initialize()
    provider = FakeChunkProvider()
    service = AsrService(repository, provider, config)
    arguments = {
        "subject_hash": "subject",
        "media_fingerprint": "media-fingerprint-quality",
        "duration_seconds": 157.184,
        "audio": b"complete-song-audio-quality",
        "chunks": chunks(),
        "force_refresh": False,
        "now": NOW,
        "media_content_sha256": "source-video-quality-sha256",
    }
    first = service.analyze_chunked(
        **arguments,
        operation_id="operation-quality-1",
    )
    evidence = VoiceActivityEvidence(
        detector="test-vad",
        scope="mixed_audio_advisory",
        threshold=0.15,
        frame_seconds=1.0,
        probabilities=(0.01,) * 158,
        speech_intervals=(),
    )
    enriched = service.analyze_chunked(
        **arguments,
        operation_id="operation-quality-2",
        voice_activity=evidence,
    )

    assert first["voice_activity"] is None
    assert enriched["cache_hit"] is True
    assert enriched["voice_activity"]["detector"] == "test-vad"
    assert enriched["voice_activity"]["analyzed_word_count"] == 8
    assert provider.calls == [b"chunk-0", b"chunk-1", b"chunk-2"]
    assert repository.usage(config.monthly_limit_seconds, NOW).used_seconds == 168


def test_chunked_service_reserves_overlap_before_any_provider_call(tmp_path) -> None:
    config = configured(tmp_path, monthly_limit=167)
    repository = AsrRepository(config.database_path)
    repository.initialize()
    provider = FakeChunkProvider()
    service = AsrService(repository, provider, config)

    with pytest.raises(MonthlyLimitReachedError):
        service.analyze_chunked(
            subject_hash="subject",
            operation_id="operation-chunked-limit",
            media_fingerprint="media-fingerprint-chunked",
            duration_seconds=157.184,
            audio=b"complete-song-audio",
            chunks=chunks(),
            force_refresh=False,
            now=NOW,
            media_content_sha256="source-video-sha256",
        )

    assert provider.calls == []


def test_provider_limiter_delays_fourth_request_until_next_rolling_minute() -> None:
    current = [100.0]
    delays = []

    def sleep(seconds):
        delays.append(seconds)
        current[0] += seconds

    limiter = ProviderRequestLimiter(
        3,
        clock=lambda: current[0],
        sleeper=sleep,
    )
    for _ in range(4):
        limiter.wait_for_slot()

    assert delays == [pytest.approx(60.0)]


def test_chunked_failure_keeps_partial_provider_usage_without_incomplete_cache(tmp_path) -> None:
    config = configured(tmp_path)
    repository = AsrRepository(config.database_path)
    repository.initialize()
    provider = FakeChunkProvider(fail_at=2)
    service = AsrService(repository, provider, config)

    with pytest.raises(TencentAsrError, match="fake provider failure"):
        service.analyze_chunked(
            subject_hash="subject",
            operation_id="operation-chunked-fail",
            media_fingerprint="media-fingerprint-chunked",
            duration_seconds=157.184,
            audio=b"complete-song-audio",
            chunks=chunks(),
            force_refresh=False,
            now=NOW,
            media_content_sha256="source-video-sha256",
        )

    usage = repository.usage(config.monthly_limit_seconds, NOW)
    assert provider.calls == [b"chunk-0", b"chunk-1"]
    assert usage.used_seconds == 60
    assert usage.reserved_seconds == 0
    assert repository.cached(
        "subject",
        fingerprint("media-fingerprint-chunked"),
        service.analysis_version,
    ) is None
