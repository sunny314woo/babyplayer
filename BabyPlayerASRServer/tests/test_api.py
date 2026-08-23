from dataclasses import replace

from fastapi.testclient import TestClient

from app.config import Settings
from app.database import AsrRepository
from app.main import create_app
from app.tencent_asr import Recognition


class FakeProvider:
    def __init__(self):
        self.calls = 0

    def recognize(self, audio, voice_format):
        self.calls += 1
        assert audio == b"audio"
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
