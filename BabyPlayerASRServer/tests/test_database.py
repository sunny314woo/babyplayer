from datetime import datetime, timezone

import pytest

from app.database import (
    AnalysisInProgressError,
    AsrRepository,
    MonthlyLimitReachedError,
    next_reset_at,
)


NOW = datetime(2026, 8, 23, 8, 0, tzinfo=timezone.utc)


def repository(tmp_path):
    result = AsrRepository(str(tmp_path / "asr.sqlite3"))
    result.initialize()
    return result


def claim(target, operation_id="operation-0001", reserve=120, audio_sha="a" * 64):
    target.claim(
        operation_id=operation_id,
        subject_hash="subject",
        fingerprint_hash="f" * 64,
        audio_sha256=audio_sha,
        reserve_seconds=reserve,
        monthly_limit=18000,
        requests_per_minute=10,
        now=NOW,
    )


def test_monthly_limit_counts_used_and_reserved_seconds(tmp_path) -> None:
    target = repository(tmp_path)
    claim(target, reserve=17900)

    with pytest.raises(MonthlyLimitReachedError):
        claim(target, operation_id="operation-0002", reserve=101, audio_sha="b" * 64)


def test_completion_releases_reservation_and_stores_transcript_cache(tmp_path) -> None:
    target = repository(tmp_path)
    claim(target)
    usage = target.complete(
        operation_id="operation-0001",
        subject_hash="subject",
        fingerprint_hash="f" * 64,
        analysis_version="v1",
        audio_sha256="a" * 64,
        engine_type="16k_en",
        duration_seconds=118.4,
        transcript="hello song",
        segments=[{"text": "hello song", "start_seconds": 1.0, "end_seconds": 2.0, "words": []}],
        monthly_limit=18000,
        now=NOW,
    )

    assert usage.used_seconds == 119
    assert usage.reserved_seconds == 0
    assert target.cached("subject", "f" * 64, "v1")["transcript"] == "hello song"


def test_failed_request_releases_all_reserved_time(tmp_path) -> None:
    target = repository(tmp_path)
    claim(target)
    target.release("operation-0001", NOW)

    usage = target.usage(18000, NOW)
    assert usage.used_seconds == 0
    assert usage.reserved_seconds == 0


def test_same_audio_cannot_be_claimed_twice_while_analysis_is_in_progress(tmp_path) -> None:
    target = repository(tmp_path)
    claim(target)

    with pytest.raises(AnalysisInProgressError):
        claim(target, operation_id="operation-0002")

    usage = target.usage(18000, NOW)
    assert usage.used_seconds == 0
    assert usage.reserved_seconds == 120


def test_next_reset_is_first_day_in_beijing_time() -> None:
    assert next_reset_at(NOW) == "2026-09-01T00:00:00+08:00"


def test_ai_lyrics_cache_is_versioned_and_replaced_atomically(tmp_path) -> None:
    target = repository(tmp_path)
    first = {"status": "completed", "lines": [{"text": "first"}]}
    second = {"status": "completed", "lines": [{"text": "second"}]}

    target.store_ai_lyrics(
        subject_hash="subject",
        fingerprint_hash="f" * 64,
        reconciliation_version="d3-v1",
        result=first,
        now=NOW,
    )
    assert target.cached_ai_lyrics("subject", "f" * 64, "d3-v1") == first
    assert target.cached_ai_lyrics("subject", "f" * 64, "d3-v2") is None

    target.store_ai_lyrics(
        subject_hash="subject",
        fingerprint_hash="f" * 64,
        reconciliation_version="d3-v1",
        result=second,
        now=NOW,
    )
    assert target.cached_ai_lyrics("subject", "f" * 64, "d3-v1") == second
    assert target.latest_cached_ai_lyrics("subject", "f" * 64) == second
