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
    def __init__(self, lines=None):
        self.calls = 0
        self.lines = lines or [
            {"segment_index": 0, "text": "twinkle twinkle little star"},
            {"segment_index": 1, "text": "how I wonder what you are"},
        ]

    def refine(self, evidence):
        self.calls += 1
        assert "media_fingerprint" not in evidence
        return DeepSeekRefinement(
            confidence=0.91,
            selected_candidate_identifier="candidate-1",
            lines=self.lines,
        )


def request_payload():
    return {
        "media_fingerprint": "f" * 64,
        "transcript": "twinkle twinkle little star how I wonder what you are",
        "segments": [
            {"index": 0, "text": "twinkle twinkle little star", "start_seconds": 0.4, "end_seconds": 2.0},
            {"index": 1, "text": "how I wonder what you are", "start_seconds": 2.2, "end_seconds": 4.0},
        ],
        "candidates": [{
            "identifier": "candidate-1",
            "title": "Twinkle Twinkle",
            "artist": "Kids",
            "source": "LRCLIB",
            "lines": ["Twinkle twinkle little star", "How I wonder what you are"],
        }],
    }


def test_refiner_endpoint_preserves_asr_timestamps(tmp_path) -> None:
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
    assert response.json()["lines"][0]["start_seconds"] == 0.4
    assert response.json()["lines"][1]["end_seconds"] == 4.0
    assert response.json()["model"] == "deepseek-v4-flash"
    assert refiner.calls == 1


def test_audio_evidence_outweighs_unrelated_candidate() -> None:
    payload = request_payload()
    payload["candidates"][0]["lines"] = ["drive the car", "rob the bank"]
    request = LyricsRefineRequest.model_validate(payload)
    refiner = FakeRefiner(lines=[
        {"segment_index": 0, "text": "drive the car"},
        {"segment_index": 1, "text": "rob the bank"},
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
                "confidence": 0.9,
                "selected_candidate_identifier": "candidate-1",
                "lines": [
                    {"segment_index": 0, "text": "hello world"},
                    {"segment_index": 1, "text": "hello song"},
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
    result = client.refine({"segments": []})

    assert captured["authorization"] == "Bearer test-key"
    assert captured["payload"]["model"] == "deepseek-v4-flash"
    assert captured["payload"]["thinking"] == {"type": "disabled"}
    assert captured["payload"]["response_format"] == {"type": "json_object"}
    assert result.confidence == 0.9
