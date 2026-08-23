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


def test_client_normalizes_sentence_relative_word_timestamps() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, request=request, json={
            "code": 0,
            "request_id": "request-relative-words",
            "audio_duration": 145_000,
            "flash_result": [{
                "text": "first second third",
                "sentence_list": [
                    {
                        "text": "first",
                        "start_time": 8_380,
                        "end_time": 68_860,
                        "word_list": [
                            {"word": "first", "start_time": 14_050, "end_time": 14_425},
                        ],
                    },
                    {
                        "text": "second",
                        "start_time": 68_860,
                        "end_time": 128_900,
                        "word_list": [
                            {"word": "second", "start_time": 900, "end_time": 1_350},
                        ],
                    },
                    {
                        "text": "third",
                        "start_time": 128_900,
                        "end_time": 143_900,
                        "word_list": [
                            {"word": "third", "start_time": 9_100, "end_time": 9_900},
                        ],
                    },
                ],
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
    )

    result = client.recognize(b"m4a-data", "m4a")

    assert result.segments[0]["words"][0]["start_seconds"] == 14.05
    assert result.segments[1]["words"][0]["start_seconds"] == 69.76
    assert result.segments[2]["words"][0]["start_seconds"] == 138.0
