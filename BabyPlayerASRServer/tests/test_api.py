from dataclasses import replace
import time

from fastapi.testclient import TestClient
import pytest

from app.config import Settings
from app.database import AsrRepository
from app.local_analysis import (
    ExtractedAudio,
    LocalMediaAudioExtractor,
    LocalMediaValidationError,
)
from app.main import create_app
from app.models import LocalAnalysisJobRequest
from app.service import AsrAudioChunk
from app.tencent_asr import Recognition


class FakeProvider:
    def __init__(self):
        self.calls = 0

    def recognize(self, audio, voice_format):
        self.calls += 1
        assert audio.startswith(b"audio")
        assert voice_format == "m4a"
        return Recognition(
            request_id="request-1",
            duration_seconds=2.0,
            transcript="twinkle twinkle little star",
            segments=[{
                "text": "twinkle twinkle little star",
                "start_seconds": 0.0,
                "end_seconds": 2.0,
                "words": [],
            }],
        )


class FakeLocalMediaExtractor:
    def __init__(self):
        self.calls = 0
        self.audio = b"audio"
        self.media_content_sha256 = "source-content-hash"

    def extract(self, request):
        self.calls += 1
        assert request.media_path == "/allowed/song.mp4"
        return ExtractedAudio(
            data=self.audio,
            duration_seconds=2.0,
            media_content_sha256=self.media_content_sha256,
            chunks=(AsrAudioChunk(
                index=0,
                offset_seconds=0,
                duration_seconds=2,
                audio=self.audio + b"-chunk",
            ),),
        )


def wait_for_local_job(client, headers, job_id):
    for _ in range(100):
        response = client.get(
            f"/v1/local-analysis/jobs/{job_id}", headers=headers
        )
        assert response.status_code == 200
        if response.json()["status"] in {"completed", "failed"}:
            return response.json()
        time.sleep(0.01)
    raise AssertionError("local analysis job did not finish")


def configured(tmp_path, *, limit=18000):
    return replace(
        Settings(),
        api_token="test-babyplayer-token",
        app_id="1250000000",
        secret_id="secret-id",
        secret_key="secret-key",
        monthly_limit_seconds=limit,
        database_path=str(tmp_path / "asr.sqlite3"),
        product_env="test",
    )


def test_health_does_not_expose_secrets(tmp_path) -> None:
    client = TestClient(create_app(configured(tmp_path), provider_client=FakeProvider()))
    response = client.get("/health")
    assert response.status_code == 200
    assert "secret" not in response.text.lower()


def test_analysis_requires_independent_babyplayer_token(tmp_path) -> None:
    client = TestClient(create_app(configured(tmp_path), provider_client=FakeProvider()))
    response = client.get("/v1/usage")
    assert response.status_code == 401


def test_analysis_is_cached_without_second_provider_call(tmp_path) -> None:
    config = configured(tmp_path)
    provider = FakeProvider()
    client = TestClient(create_app(config, provider_client=provider))
    headers = {"Authorization": "Bearer test-babyplayer-token"}
    data = {
        "operation_id": "operation-0001",
        "media_fingerprint": "media-fingerprint-1",
        "duration_seconds": "2",
        "voice_format": "m4a",
    }
    first = client.post(
        "/v1/analyze", headers=headers, data=data,
        files={"audio": ("sample.m4a", b"audio", "audio/mp4")},
    )
    cached = client.get(
        "/v1/cache", headers=headers,
        params={"media_fingerprint": "media-fingerprint-1"},
    )
    assert first.status_code == 200
    assert first.json()["cache_hit"] is False
    assert cached.status_code == 200
    assert cached.json()["cache_hit"] is True
    assert provider.calls == 1


def test_force_refresh_explicitly_calls_provider_again(tmp_path) -> None:
    """只有显式 force_refresh 才得绕过同指纹与同音频缓存。"""
    config = configured(tmp_path)
    provider = FakeProvider()
    client = TestClient(create_app(config, provider_client=provider))
    headers = {"Authorization": "Bearer test-babyplayer-token"}
    common = {
        "media_fingerprint": "media-fingerprint-force",
        "duration_seconds": "2",
        "voice_format": "m4a",
    }
    first = client.post(
        "/v1/analyze",
        headers=headers,
        data={**common, "operation_id": "operation-force-1"},
        files={"audio": ("sample.m4a", b"audio", "audio/mp4")},
    )
    forced = client.post(
        "/v1/analyze",
        headers=headers,
        data={
            **common,
            "operation_id": "operation-force-2",
            "force_refresh": "true",
        },
        files={"audio": ("sample.m4a", b"audio", "audio/mp4")},
    )

    assert first.status_code == 200
    assert forced.status_code == 200
    assert forced.json()["cache_hit"] is False
    assert provider.calls == 2


def test_local_development_writes_asr_process_files(tmp_path) -> None:
    """本地模式保存音频、ASR JSON 和 SRT，响应不含密钥。"""
    output = tmp_path / "LyricsTestOutputs"
    config = replace(
        configured(tmp_path),
        development_artifacts_directory=str(output),
    )
    client = TestClient(create_app(config, provider_client=FakeProvider()))
    response = client.post(
        "/v1/analyze",
        headers={"Authorization": "Bearer test-babyplayer-token"},
        data={
            "operation_id": "operation-artifacts-1",
            "media_fingerprint": "media-fingerprint-artifacts",
            "media_title": "Twinkle Test",
            "duration_seconds": "2",
            "voice_format": "m4a",
        },
        files={"audio": ("sample.m4a", b"audio", "audio/mp4")},
    )

    assert response.status_code == 200
    folder = next(output.iterdir())
    assert (folder / "uploaded_audio.m4a").read_bytes() == b"audio"
    assert "twinkle twinkle" in (folder / "asr.srt").read_text()
    assert (folder / "asr_raw.json").is_file()
    assert "test-babyplayer-token" not in (folder / "request.json").read_text()


def test_identical_audio_under_new_fingerprint_does_not_consume_again(tmp_path) -> None:
    config = configured(tmp_path)
    provider = FakeProvider()
    client = TestClient(create_app(config, provider_client=provider))
    headers = {"Authorization": "Bearer test-babyplayer-token"}

    for number in (1, 2):
        response = client.post(
            "/v1/analyze",
            headers=headers,
            data={
                "operation_id": f"operation-000{number}",
                "media_fingerprint": f"media-fingerprint-{number}",
                "duration_seconds": "2",
                "voice_format": "m4a",
            },
            files={"audio": ("sample.m4a", b"audio", "audio/mp4")},
        )
        assert response.status_code == 200

    usage = client.get("/v1/usage", headers=headers).json()
    second_cache = client.get(
        "/v1/cache",
        headers=headers,
        params={"media_fingerprint": "media-fingerprint-2"},
    )
    assert provider.calls == 1
    assert usage["used_seconds"] == 2
    assert second_cache.status_code == 200
    assert second_cache.json()["cache_hit"] is True


def test_limit_error_includes_next_available_time(tmp_path) -> None:
    config = configured(tmp_path, limit=1)
    client = TestClient(create_app(config, provider_client=FakeProvider()))
    response = client.post(
        "/v1/analyze",
        headers={"Authorization": "Bearer test-babyplayer-token"},
        data={
            "operation_id": "operation-0001",
            "media_fingerprint": "media-fingerprint-1",
            "duration_seconds": "2",
            "voice_format": "m4a",
        },
        files={"audio": ("sample.m4a", b"audio", "audio/mp4")},
    )
    assert response.status_code == 429
    assert response.json()["detail"]["code"] == "MONTHLY_ASR_LIMIT_REACHED"
    assert response.json()["detail"]["next_available_at"].endswith("+08:00")


def test_local_analysis_job_extracts_on_mac_and_reuses_cache(tmp_path) -> None:
    """【MODIFIED】Apple TV 只传本机路径；Mac 提取一次后复用永久缓存。"""
    config = configured(tmp_path)
    provider = FakeProvider()
    extractor = FakeLocalMediaExtractor()
    client = TestClient(create_app(
        config,
        provider_client=provider,
        local_media_extractor=extractor,
    ))
    headers = {"Authorization": "Bearer test-babyplayer-token"}
    request = {
        "media_fingerprint": "media-local-analysis",
        "media_title": "Local Song",
        "media_path": "/allowed/song.mp4",
        "duration_seconds": 2,
        "song_start_seconds": 0,
    }

    submitted = client.post(
        "/v1/local-analysis/jobs", headers=headers, json=request
    )
    assert submitted.status_code == 200
    finished = wait_for_local_job(client, headers, submitted.json()["job_id"])
    assert finished["status"] == "completed"
    assert finished["analysis"]["transcript"] == "twinkle twinkle little star"

    cached = client.post(
        "/v1/local-analysis/jobs", headers=headers, json=request
    )
    assert cached.status_code == 200
    cached_finished = wait_for_local_job(
        client, headers, cached.json()["job_id"]
    )
    assert cached_finished["status"] == "completed"
    assert cached_finished["analysis"]["cache_hit"] is True
    assert cached_finished["analysis"]["media_content_sha256"] == "source-content-hash"
    assert extractor.calls == 2
    assert provider.calls == 1

    # 同一 Jellyfin ID 指向不同文件内容时，旧歌词不得继续命中。
    extractor.audio = b"audio-changed"
    extractor.media_content_sha256 = "changed-source-content-hash"
    changed = client.post(
        "/v1/local-analysis/jobs", headers=headers, json=request
    )
    changed_finished = wait_for_local_job(
        client, headers, changed.json()["job_id"]
    )
    assert changed_finished["status"] == "completed"
    assert changed_finished["analysis"]["cache_hit"] is False
    assert changed_finished["analysis"]["media_content_sha256"] == "changed-source-content-hash"
    assert provider.calls == 2


def test_local_analysis_is_disabled_in_production(tmp_path) -> None:
    config = replace(configured(tmp_path), product_env="production")
    client = TestClient(create_app(
        config,
        provider_client=FakeProvider(),
        local_media_extractor=FakeLocalMediaExtractor(),
    ))
    response = client.post(
        "/v1/local-analysis/jobs",
        headers={"Authorization": "Bearer test-babyplayer-token"},
        json={
            "media_fingerprint": "media-local-analysis",
            "media_path": "/allowed/song.mp4",
            "duration_seconds": 2,
        },
    )
    assert response.status_code == 404
    assert response.json()["detail"]["code"] == "LOCAL_ANALYSIS_DISABLED"


def test_local_extractor_rejects_path_outside_allowlist(tmp_path) -> None:
    allowed = tmp_path / "allowed"
    allowed.mkdir()
    outside = tmp_path / "outside.mp4"
    outside.write_bytes(b"video")
    config = replace(configured(tmp_path), local_media_roots=(str(allowed),))
    extractor = LocalMediaAudioExtractor(config)
    request = LocalAnalysisJobRequest(
        media_fingerprint="media-local-analysis",
        media_path=str(outside),
        duration_seconds=2,
    )

    with pytest.raises(LocalMediaValidationError, match="不在允许"):
        extractor.extract(request)
