import json
from dataclasses import dataclass
from typing import Callable

import httpx


class DeepSeekRefinerError(Exception):
    pass


@dataclass(frozen=True)
class DeepSeekRefinement:
    confidence: float
    selected_candidate_identifier: str | None
    lines: list[dict]


SYSTEM_PROMPT = """You correct children's song lyrics using two evidence sources.
The ASR transcript is primary evidence and its segment order is immutable.
Candidate lyrics are secondary reference data for spelling, missing words, and repeated phrases.
Never add a verse or line that is not supported by the audio transcript.
Return JSON only with confidence, selected_candidate_identifier, and lines.
lines must contain exactly one object for every ASR segment: segment_index and corrected text.
Do not return or modify timestamps."""


class DeepSeekLyricsRefinerClient:
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

    def refine(self, evidence: dict) -> DeepSeekRefinement:
        request_body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": json.dumps(evidence, ensure_ascii=False, separators=(",", ":")),
                },
            ],
            "thinking": {"type": "disabled"},
            "response_format": {"type": "json_object"},
            "temperature": 0,
            "max_tokens": 4096,
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
            content = payload["choices"][0]["message"]["content"]
            result = json.loads(content)
        except (httpx.HTTPError, KeyError, IndexError, TypeError, ValueError) as exc:
            raise DeepSeekRefinerError("DeepSeek lyrics refinement failed") from exc
        try:
            return DeepSeekRefinement(
                confidence=float(result.get("confidence", 0)),
                selected_candidate_identifier=result.get("selected_candidate_identifier"),
                lines=list(result.get("lines") or []),
            )
        except (TypeError, ValueError) as exc:
            raise DeepSeekRefinerError("DeepSeek returned invalid refinement JSON") from exc
