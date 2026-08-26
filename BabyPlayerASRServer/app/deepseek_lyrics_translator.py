"""Timestamp-free DeepSeek adapter for line-preserving Simplified Chinese translation."""

from __future__ import annotations

import json
from typing import Callable

import httpx

from app.deepseek_refiner import DeepSeekRefinerError


TRANSLATION_SYSTEM_PROMPT = """You translate verified English children's-song lyrics into clear,
natural Simplified Chinese for young viewers. Translate each input line independently without
merging, splitting, reordering, adding, or dropping lines. Copy every line_identifier exactly.
Never output timestamps, English text, explanations, markdown, or additional keys. Return JSON only:
{"lines":[{"line_identifier":"...","chinese_text":"...","confidence":0.0}]}.
Use concise Simplified Chinese that can be read during the original English line's display time."""


class DeepSeekLyricsTranslatorClient:
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

    def translate(self, evidence: dict) -> dict:
        request_body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": TRANSLATION_SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": json.dumps(evidence, ensure_ascii=False, separators=(",", ":")),
                },
            ],
            "thinking": {"type": "disabled"},
            "response_format": {"type": "json_object"},
            "temperature": 0,
            "max_tokens": 6000,
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
                raise DeepSeekRefinerError("DeepSeek translation JSON was truncated")
            result = json.loads(choice["message"]["content"])
            if not isinstance(result, dict):
                raise TypeError("translation response must be a JSON object")
            return result
        except DeepSeekRefinerError:
            raise
        except (httpx.HTTPError, KeyError, IndexError, TypeError, ValueError) as exc:
            raise DeepSeekRefinerError("DeepSeek lyrics translation failed") from exc


__all__ = ["DeepSeekLyricsTranslatorClient", "TRANSLATION_SYSTEM_PROMPT"]
