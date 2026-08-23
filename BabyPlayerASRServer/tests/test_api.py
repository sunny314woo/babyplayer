"""
BabyPlayerASRServer/tests/test_api.py

用途：验证 BabyPlayer 独立 ASR HTTP API 的鉴权、缓存、音频去重和月度硬限制。
主要功能：
1. 健康检查不泄露凭据。
2. 独立 Bearer Token 鉴权。
3. media fingerprint 与音频 SHA-256 缓存不重复调用提供方。
4. 月度额度拒绝返回 next_available_at。
5. 冻结版本 B 不再暴露 /v1/refine。
最近修改：2026-08-23 【MODIFIED】增加 ASR-only 路由边界与健康响应回归测试。
"""

from dataclasses import replace

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.tencent_asr import Recognition


class FakeProvider:
    """测试用腾讯 ASR 替身；只记录调用次数，不访问网络。"""

    def __init__(self):
        self.calls = 0

    def recognize(self, audio, voice_format):
        """返回固定转写；输入必须是单测构造的 M4A 占位字节。"""
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


# 【MODIFIED】生成完全隔离的测试配置；占位凭据只用于让 fake provider 路径通过配置门。
def configured(tmp_path, *, limit=18000):
    """返回使用临时 SQLite 和测试 Token 的 Settings，不读取生产环境 Secret。"""
    return replace(
        Settings(),
        api_token="test-babyplayer-token",
        app_id="1250000000",
        secret_id="test-secret-id",
        secret_key="test-secret-key",
        monthly_limit_seconds=limit,
        database_path=str(tmp_path / "asr.sqlite3"),
        product_env="test",
    )


def test_health_does_not_expose_secrets(tmp_path) -> None:
    """健康检查只暴露配置状态与额度，不返回 Secret 或旧 LLM 状态。"""
    client = TestClient(create_app(configured(tmp_path), provider_client=FakeProvider()))
    response = client.get("/health")
    assert response.status_code == 200
    payload = response.json()
    assert "secret" not in response.text.lower()
    assert payload["provider_configured"] is True
    assert payload["monthly_limit_seconds"] == 18000
    assert "lyrics_refiner_configured" not in payload


def test_analysis_requires_independent_babyplayer_token(tmp_path) -> None:
    """未带 BabyPlayer 独立 Bearer Token 时额度 API 必须拒绝访问。"""
    client = TestClient(create_app(configured(tmp_path), provider_client=FakeProvider()))
    response = client.get("/v1/usage")
    assert response.status_code == 401


def test_analysis_is_cached_without_second_provider_call(tmp_path) -> None:
    """同一 media fingerprint 的缓存查询不得第二次调用腾讯提供方。"""
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
    """不同媒体指纹但音频 SHA-256 相同时只识别/计费一次。"""
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
    """服务端最终硬限制必须返回 429 和北京时间下一次可用时间。"""
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


# 【MODIFIED】冻结版本 B 禁止服务端歌词/LLM 路由重新出现。
def test_refine_route_is_removed(tmp_path) -> None:
    """旧 /v1/refine 必须为 404，确保服务器职责仅限 ASR。"""
    client = TestClient(create_app(configured(tmp_path), provider_client=FakeProvider()))
    response = client.post(
        "/v1/refine",
        headers={"Authorization": "Bearer test-babyplayer-token"},
        json={},
    )
    assert response.status_code == 404
