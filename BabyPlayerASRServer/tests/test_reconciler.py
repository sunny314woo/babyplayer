"""Version D3 reusable lyrics evidence reconciler tests."""

import json
from dataclasses import replace
from datetime import datetime, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.deepseek_lyrics_reconciler import DeepSeekLyricsReconcilerClient
from app.lyrics_reconciler import LyricsReconciliationError, LyricsReconcilerService
from app.lyrics_retriever import AllowlistedWebLyricsRetriever, RetrievedLyricsEvidence
from app.main import create_app
from app.models import LyricsReconcileRequest
from tests.test_api import FakeProvider, configured


NOW = datetime(2026, 8, 23, 9, 0, tzinfo=timezone.utc)


def asr_analysis():
    words = [
        ("twinkle", 0.4, 0.8),
        ("twinkle", 0.9, 1.2),
        ("little", 1.3, 1.6),
        ("star", 1.7, 2.0),
        ("how", 2.2, 2.5),
        ("I", 2.6, 2.7),
        ("wonder", 2.8, 3.2),
        ("what", 3.3, 3.5),
        ("you", 3.6, 3.8),
        ("are", 3.9, 4.1),
    ]
    return {
        "transcript": "twinkle twinkle little star how I wonder what you are",
        "segments": [{
            "text": "twinkle twinkle little star how I wonder what you are",
            "start_seconds": 0.4,
            "end_seconds": 4.1,
            "words": [
                {"text": text, "start_seconds": start, "end_seconds": end}
                for text, start, end in words
            ],
        }],
    }


def request(candidate_text=("Twinkle, twinkle, little star", "How I wonder what you are")):
    return LyricsReconcileRequest.model_validate({
        "media_fingerprint": "media-fingerprint-0001",
        "song_title": "Twinkle Twinkle Little Star",
        "candidates": [{
            "candidate_id": "candidate_1",
            "source": "LRCLIB",
            "title": "Twinkle Twinkle Little Star",
            "artist": "Traditional",
            "lines": [
                {"line_identifier": f"line_{index}", "text": text}
                for index, text in enumerate(candidate_text)
            ],
        }],
    })


class MemoryRepository:
    def __init__(self):
        self.cached_result = None
        self.store_calls = 0

    def cached_ai_lyrics(self, subject_hash, fingerprint_hash, reconciliation_version):
        del subject_hash, fingerprint_hash, reconciliation_version
        return self.cached_result

    def store_ai_lyrics(self, **kwargs):
        self.store_calls += 1
        self.cached_result = kwargs["result"]


class FakeD3Model:
    def __init__(self, *, need_web_search=False, result=None):
        self.need_web_search = need_web_search
        self.result = result or {
            "song_match_confidence": 0.94,
            "primary_source": "candidate_1",
            "lines": [
                {
                    "text": "Twinkle, twinkle, little star",
                    "asr_word_start_index": 0,
                    "asr_word_end_index": 3,
                    "source": "candidate_1",
                    "source_line_ids": ["candidate_1:line_0"],
                    "confidence": 0.97,
                    "text_corrected": False,
                },
                {
                    "text": "How I wonder what you are",
                    "asr_word_start_index": 4,
                    "asr_word_end_index": 9,
                    "source": "candidate_1",
                    "source_line_ids": ["candidate_1:line_1"],
                    "confidence": 0.96,
                    "text_corrected": False,
                },
            ],
            "discarded_lines": [],
        }
        self.assess_calls = 0
        self.reconcile_calls = 0

    def assess(self, evidence):
        self.assess_calls += 1
        assert evidence["song_title"] == "Twinkle Twinkle Little Star"
        return {
            "candidate_scores": [{"candidate_id": "candidate_1", "confidence": 0.9}],
            "need_web_search": self.need_web_search,
            "reason_code": "all_candidates_weak" if self.need_web_search else "existing_candidate_reliable",
        }

    def reconcile(self, evidence):
        self.reconcile_calls += 1
        assert evidence["tencent_asr"]["words"][0]["index"] == 0
        return self.result


class FakeRetriever:
    def __init__(self, results=None):
        self.calls = 0
        self.results = results or []

    def search(self, song_title):
        self.calls += 1
        assert song_title == "Twinkle Twinkle Little Star"
        return self.results


def service(repository, model, retriever):
    return LyricsReconcilerService(
        repository=repository,
        model=model,
        retriever=retriever,
        model_name="deepseek-v4-flash",
        analysis_version="asr-v1",
        reconciliation_version="d3-v1",
    )


def test_reconciler_uses_candidate_without_unnecessary_web_search_and_caches() -> None:
    repository = MemoryRepository()
    model = FakeD3Model()
    retriever = FakeRetriever()
    target = service(repository, model, retriever)

    first = target.reconcile(
        subject_hash="subject", request=request(), asr_analysis=asr_analysis(), now=NOW
    )
    second = target.reconcile(
        subject_hash="subject", request=request(), asr_analysis=asr_analysis(), now=NOW
    )

    assert retriever.calls == 0
    assert model.assess_calls == 1
    assert model.reconcile_calls == 1
    assert first["lines"][0]["start_seconds"] == 0.4
    assert first["lines"][0]["end_seconds"] == 2.0
    assert first["cache_hit"] is False
    assert second["cache_hit"] is True
    assert repository.store_calls == 1


def test_reconciler_searches_when_all_existing_candidates_are_weak() -> None:
    web = RetrievedLyricsEvidence(
        candidate_id="web_1",
        source="supersimple.com",
        url="https://supersimple.com/song/twinkle-twinkle-little-star/",
        text="Twinkle, twinkle, little star\nHow I wonder what you are",
    )
    result = {
        "song_match_confidence": 0.92,
        "primary_source": "web_1",
        "lines": [
            {
                "text": "Twinkle, twinkle, little star",
                "asr_word_start_index": 0,
                "asr_word_end_index": 3,
                "source": "web_1",
                "source_line_ids": [],
                "confidence": 0.95,
                "text_corrected": True,
            },
            {
                "text": "How I wonder what you are",
                "asr_word_start_index": 4,
                "asr_word_end_index": 9,
                "source": "web_1",
                "source_line_ids": [],
                "confidence": 0.94,
                "text_corrected": True,
            },
        ],
        "discarded_lines": [{
            "source_line_id": "candidate_1:line_0",
            "text": "Drive the red car",
            "reason": "wrong_version",
        }],
    }
    repository = MemoryRepository()
    model = FakeD3Model(need_web_search=True, result=result)
    retriever = FakeRetriever([web])

    reconciled = service(repository, model, retriever).reconcile(
        subject_hash="subject",
        request=request(("Drive the red car", "Stop at the bank")),
        asr_analysis=asr_analysis(),
        now=NOW,
    )

    assert retriever.calls == 1
    assert reconciled["web_search_used"] is True
    assert reconciled["primary_source"] == "web_1"


def test_reconciler_rejects_model_generated_timestamps_or_nonmonotonic_ranges() -> None:
    invalid = FakeD3Model().result
    invalid["lines"][1]["asr_word_start_index"] = 2
    invalid["lines"][1]["asr_word_end_index"] = 5
    target = service(MemoryRepository(), FakeD3Model(result=invalid), FakeRetriever())

    with pytest.raises(LyricsReconciliationError, match="monotonic"):
        target.reconcile(
            subject_hash="subject", request=request(), asr_analysis=asr_analysis(), now=NOW
        )


def test_deepseek_d3_client_uses_separate_assessment_and_reconciliation_prompts() -> None:
    prompts = []

    def handler(http_request: httpx.Request) -> httpx.Response:
        payload = json.loads(http_request.read())
        prompts.append(payload["messages"][0]["content"])
        content = {"candidate_scores": [], "need_web_search": False, "reason_code": "no_candidates"}
        if "Lyrics Evidence Reconciler" in prompts[-1]:
            content = {
                "song_match_confidence": 0.8,
                "primary_source": "asr_only",
                "lines": [],
                "discarded_lines": [],
            }
        return httpx.Response(200, request=http_request, json={
            "choices": [{"finish_reason": "stop", "message": {"content": json.dumps(content)}}]
        })

    client = DeepSeekLyricsReconcilerClient(
        api_key="test-key",
        endpoint="https://api.deepseek.com/chat/completions",
        model="deepseek-v4-flash",
        timeout_seconds=5,
        client_factory=lambda **_kwargs: httpx.Client(transport=httpx.MockTransport(handler)),
    )

    client.assess({"candidate_lyrics": []})
    client.reconcile({"candidate_lyrics": []})

    assert "do not use song memory" in prompts[0]
    assert "Never output a timestamp" in prompts[1]


def test_d3_endpoint_requires_cached_asr_before_calling_deepseek(tmp_path) -> None:
    config = replace(configured(tmp_path), deepseek_api_key="test-deepseek-key")
    model = FakeD3Model()
    client = TestClient(create_app(
        config,
        provider_client=FakeProvider(),
        reconciler_client=model,
        lyrics_retriever=FakeRetriever(),
    ))

    response = client.post(
        "/v1/lyrics/reconcile",
        headers={"Authorization": "Bearer test-babyplayer-token"},
        json=request().model_dump(),
    )

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "ASR_CACHE_REQUIRED"
    assert model.assess_calls == 0


def test_web_retriever_fetches_only_bounded_allowlisted_https_evidence() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "html.duckduckgo.com":
            html = """
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fsupersimple.com%2Fsong%2Ftwinkle">
              Official Twinkle song
            </a>
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fevil.example%2Flyrics">
              Untrusted lyrics
            </a>
            """
            return httpx.Response(
                200, request=request, headers={"content-type": "text/html"}, text=html
            )
        assert request.url.host == "supersimple.com"
        return httpx.Response(
            200,
            request=request,
            headers={"content-type": "text/html; charset=utf-8"},
            text="<main><p>Twinkle twinkle little star</p><p>How I wonder what you are tonight</p></main>",
        )

    retriever = AllowlistedWebLyricsRetriever(
        timeout_seconds=2,
        max_results=3,
        client_factory=lambda **_kwargs: httpx.Client(transport=httpx.MockTransport(handler)),
    )

    results = retriever.search("Twinkle Twinkle Little Star")

    assert len(results) == 1
    assert results[0].candidate_id == "web_1"
    assert results[0].url.startswith("https://supersimple.com/")
    assert "How I wonder" in results[0].text
    assert AllowlistedWebLyricsRetriever._allowed_url("https://songs.supersimple.com/a")
    assert not AllowlistedWebLyricsRetriever._allowed_url("http://supersimple.com/a")
    assert not AllowlistedWebLyricsRetriever._allowed_url("https://supersimple.com.evil.example/a")
