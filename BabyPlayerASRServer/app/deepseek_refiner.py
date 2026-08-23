"""DeepSeek 的 BabyPlayer AI Lyrics 有限文本修复客户端。

当前主要功能：发送结构化原歌词/alignment/ASR 证据，并解码逐行 repair 建议。
最近修改：2026-08-23 禁止模型重建整首歌或产生任何时间戳。
"""

import json
from dataclasses import dataclass
from typing import Callable

import httpx


class DeepSeekRefinerError(Exception):
    pass


@dataclass(frozen=True)
class DeepSeekRefinement:
    overall_confidence: float
    repairs: list[dict]


SYSTEM_PROMPT = """You perform limited textual repair on an existing children's-song lyric timeline.
The original_lines are the primary text and deterministic source of line identity/order.
ASR transcript and aligned_words are noisy audio evidence, not final lyrics.
Never add a verse, line, or wording unsupported by original_text or aligned ASR words.
Do not rewrite a correct line. Prefer should_modify=false when evidence is weak.
You may repair obvious recognition/source errors, capitalization, punctuation, contractions, and spelling.
Return JSON only with overall_confidence and one repair for every original line.
Each repair must contain line_identifier, original_text, suggested_text, should_modify,
evidence, and confidence. Copy line_identifier and original_text exactly.
Never return timestamps, timing suggestions, segment boundaries, or a replacement song."""


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
        # 【MODIFIED】固定为非思考 JSON repair contract，不接受自由文本或时间轴输出。
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
                overall_confidence=float(result.get("overall_confidence", 0)),
                repairs=list(result.get("repairs") or []),
            )
        except (TypeError, ValueError) as exc:
            raise DeepSeekRefinerError("DeepSeek returned invalid refinement JSON") from exc
