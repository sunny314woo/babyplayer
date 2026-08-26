"""Phase 3A independent Simplified Chinese translation contract tests."""

from dataclasses import replace
from datetime import datetime, timezone
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.database import AsrRepository
from app.deepseek_lyrics_translator import (
    DeepSeekLyricsTranslatorClient,
    TRANSLATION_SYSTEM_PROMPT,
)
from app.lyrics_translation import (
    LyricsTranslationService,
    LyricsTranslationValidationError,
)
from app.main import create_app
from app.models import LyricsTranslateRequest


NOW = datetime(2026, 8, 26, 8, 0, tzinfo=timezone.utc)
HASH_A = "a" * 64
HASH_B = "b" * 64


class FakeTranslator:
    def __init__(self, lines=None):
        self.calls = 0
        self.lines = lines

    def translate(self, evidence):
        self.calls += 1
        lines = self.lines or [
            {
                "line_identifier": line["line_identifier"],
                "chinese_text": f"中文 {index + 1}",
                "confidence": 0.9,
            }
            for index, line in enumerate(evidence["lines"])
        ]
        return {"lines": lines}


class OneTimeSchemaDriftTranslator:
    def __init__(self):
        self.calls = 0

    def translate(self, evidence):
        self.calls += 1
        lines = [
            {
                "line_identifier": line["line_identifier"],
                "chinese_text": f"中文 {index + 1}",
            }
            for index, line in enumerate(evidence["lines"])
        ]
        if self.calls == 1:
            lines[0]["start_seconds"] = 1
        return {"lines": lines}


class UnusedProvider:
    def recognize(self, *_args, **_kwargs):
        raise AssertionError("translation endpoint must not invoke ASR")


def request(english_hash=HASH_A):
    return LyricsTranslateRequest.model_validate({
        "media_fingerprint": "stable-media-fingerprint",
        "english_lyrics_content_hash": english_hash,
        "translation_version": "zh-hans-v1",
        "target_language": "zh-Hans",
        "lines": [
            {"line_identifier": "line-0", "english_text": "Twinkle little star"},
            {"line_identifier": "line-1", "english_text": "How I wonder what you are"},
        ],
    })


def repository(tmp_path):
    target = AsrRepository(str(tmp_path / "translation.sqlite3"))
    target.initialize()
    return target


def service(tmp_path, model):
    return LyricsTranslationService(
        repository=repository(tmp_path),
        model=model,
        model_name="deepseek-test",
    )


def test_translation_is_cached_by_exact_english_hash_and_model_version(tmp_path) -> None:
    model = FakeTranslator()
    target = service(tmp_path, model)

    first = target.translate(subject_hash="subject", request=request(), now=NOW)
    cached = target.translate(subject_hash="subject", request=request(), now=NOW)
    changed = target.translate(subject_hash="subject", request=request(HASH_B), now=NOW)

    assert first["cache_hit"] is False
    assert cached["cache_hit"] is True
    assert changed["cache_hit"] is False
    assert cached["english_lyrics_content_hash"] == HASH_A
    assert model.calls == 2


@pytest.mark.parametrize("bad_lines", [
    [
        {"line_identifier": "line-0", "chinese_text": "第一行"},
        {"line_identifier": "unknown", "chinese_text": "第二行"},
    ],
    [
        {"line_identifier": "line-0", "chinese_text": "第一行"},
        {"line_identifier": "line-0", "chinese_text": "重复"},
    ],
    [{"line_identifier": "line-0", "chinese_text": "缺少第二行"}],
])
def test_unknown_duplicate_or_missing_identifier_is_rejected(tmp_path, bad_lines) -> None:
    target = service(tmp_path, FakeTranslator(lines=bad_lines))

    with pytest.raises(LyricsTranslationValidationError):
        target.translate(subject_hash="subject", request=request(), now=NOW)


def test_translation_output_cannot_contain_timestamps(tmp_path) -> None:
    model = FakeTranslator(lines=[
        {
            "line_identifier": "line-0",
            "chinese_text": "第一行",
            "start_seconds": 12,
        },
        {"line_identifier": "line-1", "chinese_text": "第二行"},
    ])

    with pytest.raises(LyricsTranslationValidationError):
        service(tmp_path, model).translate(
            subject_hash="subject", request=request(), now=NOW
        )


def test_one_schema_drift_gets_one_strict_retry_then_caches(tmp_path) -> None:
    model = OneTimeSchemaDriftTranslator()
    target = service(tmp_path, model)

    result = target.translate(subject_hash="subject", request=request(), now=NOW)
    cached = target.translate(subject_hash="subject", request=request(), now=NOW)

    assert result["status"] == "completed"
    assert cached["cache_hit"] is True
    assert model.calls == 2


def test_translation_endpoint_uses_no_asr_or_reconciliation(tmp_path) -> None:
    config = replace(
        Settings(),
        api_token="test-babyplayer-token",
        app_id="configured",
        secret_id="configured",
        secret_key="configured",
        deepseek_api_key="test-deepseek-key",
        deepseek_model="deepseek-test",
        database_path=str(tmp_path / "endpoint.sqlite3"),
        product_env="test",
    )
    model = FakeTranslator()
    client = TestClient(create_app(
        config,
        provider_client=UnusedProvider(),
        translator_client=model,
    ))

    response = client.post(
        "/v1/lyrics/translate/zh-Hans",
        headers={"Authorization": "Bearer test-babyplayer-token"},
        json=request().model_dump(mode="json"),
    )

    assert response.status_code == 200
    assert response.json()["english_lyrics_content_hash"] == HASH_A
    assert model.calls == 1


def test_deepseek_translation_prompt_forbids_timestamps_and_resegmentation() -> None:
    captured = {}

    def handler(http_request: httpx.Request) -> httpx.Response:
        captured.update(json.loads(http_request.read()))
        content = {
            "lines": [
                {"line_identifier": "line-0", "chinese_text": "小星星"},
            ]
        }
        return httpx.Response(200, request=http_request, json={
            "choices": [{"finish_reason": "stop", "message": {"content": json.dumps(content)}}]
        })

    client = DeepSeekLyricsTranslatorClient(
        api_key="test-key",
        endpoint="https://api.deepseek.com/chat/completions",
        model="deepseek-test",
        timeout_seconds=5,
        client_factory=lambda **_kwargs: httpx.Client(transport=httpx.MockTransport(handler)),
    )
    client.translate({"lines": [{"line_identifier": "line-0", "english_text": "star"}]})

    assert "Never output timestamps" in TRANSLATION_SYSTEM_PROMPT
    assert "merging, splitting, reordering" in TRANSLATION_SYSTEM_PROMPT
    assert captured["temperature"] == 0
