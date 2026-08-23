import base64
import hashlib
import hmac
import time
from dataclasses import dataclass
from typing import Callable
from urllib.parse import urlencode, urlparse

import httpx


class TencentAsrError(Exception):
    pass


@dataclass(frozen=True)
class Recognition:
    request_id: str
    duration_seconds: float
    transcript: str
    segments: list[dict]


class TencentFlashAsrClient:
    def __init__(
        self,
        *,
        app_id: str,
        secret_id: str,
        secret_key: str,
        endpoint: str,
        engine_type: str,
        timeout_seconds: float,
        client_factory: Callable[..., httpx.Client] = httpx.Client,
        timestamp_factory: Callable[[], int] = lambda: int(time.time()),
    ) -> None:
        self.app_id = app_id
        self.secret_id = secret_id
        self.secret_key = secret_key
        self.endpoint = endpoint.rstrip("/")
        self.engine_type = engine_type
        self.timeout_seconds = timeout_seconds
        self.client_factory = client_factory
        self.timestamp_factory = timestamp_factory

    def recognize(self, audio: bytes, voice_format: str) -> Recognition:
        parsed = urlparse(self.endpoint)
        if parsed.scheme != "https" or not parsed.hostname:
            raise TencentAsrError("Invalid Tencent ASR endpoint")
        path = f"/asr/flash/v1/{self.app_id}"
        params = {
            "convert_num_mode": "1",
            "engine_type": self.engine_type,
            "filter_dirty": "0",
            "filter_modal": "0",
            "filter_punc": "0",
            "first_channel_only": "1",
            "secretid": self.secret_id,
            "timestamp": str(self.timestamp_factory()),
            "voice_format": voice_format,
            "word_info": "1",
        }
        query = urlencode(sorted(params.items()))
        signature_source = f"POST{parsed.hostname}{path}?{query}".encode("utf-8")
        signature = base64.b64encode(
            hmac.new(self.secret_key.encode("utf-8"), signature_source, hashlib.sha1).digest()
        ).decode("ascii")
        try:
            with self.client_factory(timeout=self.timeout_seconds) as client:
                response = client.post(
                    f"{self.endpoint}{path}?{query}",
                    headers={
                        "Authorization": signature,
                        "Content-Type": "application/octet-stream",
                    },
                    content=audio,
                )
            response.raise_for_status()
            payload = response.json()
        except (httpx.HTTPError, TypeError, ValueError) as exc:
            raise TencentAsrError("Tencent ASR request failed") from exc
        if payload.get("code") != 0:
            raise TencentAsrError(str(payload.get("message") or "Tencent ASR rejected audio"))

        results = payload.get("flash_result") or []
        first = results[0] if results else {}
        transcript = str(first.get("text") or "").strip()
        segments = []
        for sentence in first.get("sentence_list") or []:
            text = str(sentence.get("text") or "").strip()
            if not text:
                continue
            words = []
            for word in sentence.get("word_list") or []:
                word_text = str(word.get("word") or "").strip()
                if word_text:
                    words.append({
                        "text": word_text,
                        "start_seconds": milliseconds(word.get("start_time")),
                        "end_seconds": milliseconds(word.get("end_time")),
                    })
            segments.append({
                "text": text,
                "start_seconds": milliseconds(sentence.get("start_time")),
                "end_seconds": milliseconds(sentence.get("end_time")),
                "words": words,
            })
        return Recognition(
            request_id=str(payload.get("request_id") or ""),
            duration_seconds=milliseconds(payload.get("audio_duration")),
            transcript=transcript,
            segments=segments,
        )


def milliseconds(value) -> float:
    try:
        return max(0.0, float(value) / 1000.0)
    except (TypeError, ValueError):
        return 0.0
