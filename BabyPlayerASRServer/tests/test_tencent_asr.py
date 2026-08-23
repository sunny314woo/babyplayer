import httpx

from app.tencent_asr import TencentFlashAsrClient


def test_client_signs_flash_request_and_converts_milliseconds() -> None:
    captured = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["authorization"] = request.headers["Authorization"]
        captured["url"] = str(request.url)
        captured["body"] = request.read()
        return httpx.Response(200, request=request, json={
            "code": 0,
            "request_id": "request-1",
            "audio_duration": 2386,
            "flash_result": [{
                "text": "hello world",
                "sentence_list": [{
                    "text": "hello world",
                    "start_time": 100,
                    "end_time": 2200,
                    "word_list": [{"word": "hello", "start_time": 100, "end_time": 800}],
                }],
            }],
        })

    client = TencentFlashAsrClient(
        app_id="1250000000",
        secret_id="secret-id",
        secret_key="secret-key",
        endpoint="https://asr.cloud.tencent.com",
        engine_type="16k_en",
        timeout_seconds=5,
        client_factory=lambda **_kwargs: httpx.Client(transport=httpx.MockTransport(handler)),
        timestamp_factory=lambda: 1770000000,
    )
    result = client.recognize(b"m4a-data", "m4a")

    assert captured["authorization"]
    assert "engine_type=16k_en" in captured["url"]
    assert captured["body"] == b"m4a-data"
    assert result.duration_seconds == 2.386
    assert result.segments[0]["start_seconds"] == 0.1
