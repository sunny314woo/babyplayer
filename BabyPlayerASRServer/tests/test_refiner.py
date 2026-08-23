"""BabyPlayer /v1/refine 的结构化 AI Lyrics 文本修复回归测试。

当前主要功能：验证 DeepSeek 只提交逐行文本建议，最终时间戳仍由确定性 alignment 证据控制。
最近修改：2026-08-23 将旧的 ASR-segment 自由改写 contract 收紧为 Version C limited repair。
"""

import json
from dataclasses import replace

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.deepseek_refiner import (
    DeepSeekLyricsRefinerClient,
    DeepSeekRefinement,
)
from app.lyrics_refiner import LyricsRefinementValidationError, LyricsRefinerService
from app.main import create_app
from app.models import LyricsRefineRequest
from tests.test_api import FakeProvider, configured


class FakeRefiner:
    def __init__(self, repairs=None):
        self.calls = 0
        self.repairs = repairs or [
            {
                "line_identifier": "line-0",
                "original_text": "Twinkle twinkle little star",
                "suggested_text": "Twinkle, twinkle, little star",
                "should_modify": True,
                "evidence": "Original lyric and aligned ASR words agree",
                "confidence": 0.91,
                "start_seconds": 999,
            },
            {
                "line_identifier": "line-1",
                "original_text": "How I wonder what you are",
                "suggested_text": "How I wonder what you are",
                "should_modify": False,
                "evidence": "No repair needed",
                "confidence": 0.95,
                "start_seconds": 999,
            },
        ]

    def refine(self, evidence):
        self.calls += 1
        assert "media_fingerprint" not in evidence
        return DeepSeekRefinement(
            overall_confidence=0.91,
            repairs=self.repairs,
        )


def request_payload():
    return {
        "media_fingerprint": "f" * 64,
        "transcript": "twinkle twinkle little star how I wonder what you are",
        "original_lines": [
            {
                "line_identifier": "line-0",
                "original_text": "Twinkle twinkle little star",
                "start_seconds": 0.4,
                "end_seconds": 2.0,
                "aligned_words": [
                    {"text": "twinkle", "start_seconds": 0.4, "end_seconds": 0.8},
                    {"text": "little", "start_seconds": 1.0, "end_seconds": 1.3},
                    {"text": "star", "start_seconds": 1.5, "end_seconds": 1.9},
                ],
            },
            {
                "line_identifier": "line-1",
                "original_text": "How I wonder what you are",
                "start_seconds": 2.2,
                "end_seconds": 4.0,
                "aligned_words": [
                    {"text": "how", "start_seconds": 2.2, "end_seconds": 2.5},
                    {"text": "wonder", "start_seconds": 2.8, "end_seconds": 3.2},
                    {"text": "you", "start_seconds": 3.4, "end_seconds": 3.6},
                    {"text": "are", "start_seconds": 3.7, "end_seconds": 4.0},
                ],
            },
        ],
        "evidence": {
            "normalized_text_similarity": 0.82,
            "ordered_token_similarity": 0.88,
            "title_similarity": 1.0,
            "asr_coverage": 0.84,
            "temporal_order": 1.0,
            "same_song_confidence": 0.88,
        },
    }


def test_refiner_endpoint_preserves_asr_timestamps(tmp_path) -> None:
    """【MODIFIED】Version C requirements replaced previous behavior.

    职责：验证 repair 响应仅返回文本建议，并使用请求中 deterministic alignment 的时间证据。
    输入：原歌词行、ASR 证据和对齐时间；输出：结构化 repairs 及未被 AI 改写的时间；不修改持久状态。
    """
    config = replace(configured(tmp_path), deepseek_api_key="test-deepseek-key")
    refiner = FakeRefiner()
    client = TestClient(create_app(
        config,
        provider_client=FakeProvider(),
        refiner_client=refiner,
    ))
    response = client.post(
        "/v1/refine",
        headers={"Authorization": "Bearer test-babyplayer-token"},
        json=request_payload(),
    )

    assert response.status_code == 200
    assert response.json()["model"] == "deepseek-v4-flash"
    assert refiner.calls == 1
    assert "repairs" in response.json()
    assert all("suggested_text" in repair for repair in response.json()["repairs"])
    assert all("start_seconds" not in repair for repair in response.json()["repairs"])
    assert response.json()["repairs"][1]["suggested_text"] == "How I wonder what you are"


def test_audio_evidence_outweighs_unrelated_candidate() -> None:
    payload = request_payload()
    request = LyricsRefineRequest.model_validate(payload)
    refiner = FakeRefiner(repairs=[
        {
            "line_identifier": "line-0",
            "original_text": "Twinkle twinkle little star",
            "suggested_text": "drive the car",
            "should_modify": True,
            "evidence": "unsupported",
            "confidence": 0.99,
        },
        {
            "line_identifier": "line-1",
            "original_text": "How I wonder what you are",
            "suggested_text": "rob the bank",
            "should_modify": True,
            "evidence": "unsupported",
            "confidence": 0.99,
        },
    ])

    with pytest.raises(LyricsRefinementValidationError):
        LyricsRefinerService(refiner, "deepseek-v4-flash").refine(request)


def test_deepseek_flash_request_uses_json_and_non_thinking_mode() -> None:
    captured = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["authorization"] = request.headers["Authorization"]
        captured["payload"] = json.loads(request.read())
        return httpx.Response(200, request=request, json={
            "choices": [{"message": {"content": json.dumps({
                "overall_confidence": 0.9,
                "repairs": [
                    {
                        "line_identifier": "line-0",
                        "original_text": "hello world",
                        "suggested_text": "Hello, world!",
                        "should_modify": True,
                        "evidence": "punctuation repair",
                        "confidence": 0.9,
                    },
                ],
            })}}],
        })

    client = DeepSeekLyricsRefinerClient(
        api_key="test-key",
        endpoint="https://api.deepseek.com/chat/completions",
        model="deepseek-v4-flash",
        timeout_seconds=5,
        client_factory=lambda **_kwargs: httpx.Client(transport=httpx.MockTransport(handler)),
    )
    result = client.refine({"original_lines": []})

    assert captured["authorization"] == "Bearer test-key"
    assert captured["payload"]["model"] == "deepseek-v4-flash"
    assert captured["payload"]["thinking"] == {"type": "disabled"}
    assert captured["payload"]["response_format"] == {"type": "json_object"}
    assert "Never return timestamps" in captured["payload"]["messages"][0]["content"]
    assert result.overall_confidence == 0.9
    assert result.repairs[0]["line_identifier"] == "line-0"
