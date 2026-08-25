"""DeepSeek JSON adapter for the reusable Version D3 lyrics reconciler."""

from __future__ import annotations

import json
from typing import Callable

import httpx

from app.deepseek_refiner import DeepSeekRefinerError


ASSESSMENT_SYSTEM_PROMPT = """You are BabyPlayer's candidate evidence assessor.
Compare every supplied children's-song lyric candidate with the current Tencent ASR transcript,
indexed words, song title, phrase order, coverage, and repeated-chorus structure. ASR wording can
be noisy. Do not write final lyrics and do not use song memory. Return JSON only:
{"candidate_scores":[{"candidate_id":"...","confidence":0.0}],
"need_web_search":false,"reason_code":"existing_candidate_reliable|all_candidates_weak|no_candidates"}.
Request web search only when all supplied candidates are clearly weak for this actual audio."""


RECONCILIATION_SYSTEM_PROMPT = """You are BabyPlayer's Lyrics Evidence Reconciler, not a lyric creator.
Reconstruct lyrics for the current audio using the song title, Tencent ASR transcript/indexed words,
existing candidates, and any separately retrieved web candidates. ASR word timing is the only timing
truth. Candidate timestamps are weak and must not control order. Never use memory to add lyrics.
Each ASR word may include voice_activity_score, voice_activity_coverage, and quality_flags. These are
conservative mixed-audio advisory signals, not absolute truth: candidate-supported sung words can
survive low activity, but an ASR-only run flagged possible_instrumental_hallucination must be omitted.
Choose wording supported by ASR or supplied candidate evidence; tolerate obvious ASR mishearing such
as 'clap your heads' versus strongly supported 'Clap your hands'. Omit unsupported candidate lines.
Preserve repeated performances at distinct ASR positions. Each final line must map to one contiguous,
inclusive, monotonic, non-overlapping ASR word range. Never output a timestamp.
Return JSON only:
{"song_match_confidence":0.0,"primary_source":"candidate_id|web_id|mixed|asr_only",
"lines":[{"text":"...","asr_word_start_index":0,"asr_word_end_index":0,
"source":"candidate_id|web_id|mixed|asr_only","source_line_ids":["candidate_id:line_id"],
"confidence":0.0,"text_corrected":false}],
"discarded_lines":[]}.
Always return discarded_lines as an empty array; do not enumerate rejected candidate lines.
Keep source_line_ids minimal and include at most three identifiers per final line.
For a web candidate, copy its exact source_line_id (for example web_1:retrieved_text);
never invent line identifiers inside retrieved_text.
The goal is the most faithful lyric for this audio, not the prettiest standard version."""


class DeepSeekLyricsReconcilerClient:
    """Two small model operations behind one reusable evidence-model interface."""

    def __init__(
        self,
        *,
        api_key: str,
        endpoint: str,
        model: str,
        timeout_seconds: float,
        client_factory: Callable[..., httpx.Client] = httpx.Client,
    ) -> None:
        self.api_key = api_key
        self.endpoint = endpoint
        self.model = model
        self.timeout_seconds = timeout_seconds
        self.client_factory = client_factory

    def assess(self, evidence: dict) -> dict:
        return self._complete_json(ASSESSMENT_SYSTEM_PROMPT, evidence, max_tokens=1200)

    def reconcile(self, evidence: dict) -> dict:
        return self._complete_json(RECONCILIATION_SYSTEM_PROMPT, evidence, max_tokens=8000)

    def _complete_json(self, system_prompt: str, evidence: dict, *, max_tokens: int) -> dict:
        request_body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {
                    "role": "user",
                    "content": json.dumps(evidence, ensure_ascii=False, separators=(",", ":")),
                },
            ],
            "thinking": {"type": "disabled"},
            "response_format": {"type": "json_object"},
            "temperature": 0,
            "max_tokens": max_tokens,
            "stream": False,
        }
        try:
            with self.client_factory(timeout=self.timeout_seconds) as client:
                response = client.post(
                    self.endpoint,
                    headers={
                        "Authorization": f"Bearer {self.api_key}",
                        "Content-Type": "application/json",
                    },
                    json=request_body,
                )
            response.raise_for_status()
            payload = response.json()
            choice = payload["choices"][0]
            if choice.get("finish_reason") == "length":
                raise DeepSeekRefinerError("DeepSeek lyrics JSON was truncated")
            result = json.loads(choice["message"]["content"])
            if not isinstance(result, dict):
                raise TypeError("lyrics response must be a JSON object")
            return result
        except DeepSeekRefinerError:
            raise
        except (httpx.HTTPError, KeyError, IndexError, TypeError, ValueError) as exc:
            raise DeepSeekRefinerError("DeepSeek lyrics reconciliation failed") from exc


__all__ = [
    "ASSESSMENT_SYSTEM_PROMPT",
    "DeepSeekLyricsReconcilerClient",
    "RECONCILIATION_SYSTEM_PROMPT",
]
