import base64
import hashlib
import hmac
import logging
import time
from dataclasses import dataclass
from typing import Callable
from urllib.parse import urlencode, urlparse

import httpx


logger = logging.getLogger("babyplayer.tencent_asr")


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
        except httpx.HTTPStatusError as exc:
            response_preview = exc.response.text[:500].replace("\n", " ")
            logger.error(
                "Tencent Flash ASR HTTP failure status=%s body=%s",
                exc.response.status_code,
                response_preview,
            )
            raise TencentAsrError("Tencent ASR HTTP request failed") from exc
        except (httpx.HTTPError, TypeError, ValueError) as exc:
            logger.error(
                "Tencent Flash ASR transport/JSON failure type=%s",
                type(exc).__name__,
            )
            raise TencentAsrError("Tencent ASR request failed") from exc
        if payload.get("code") != 0:
            code = payload.get("code")
            message = str(payload.get("message") or "Tencent ASR rejected audio")
            request_id = str(payload.get("request_id") or "")
            # No audio, transcript, authorization signature, AppID or secret is logged.
            logger.error(
                "Tencent Flash ASR rejected request code=%s message=%s request_id=%s",
                code,
                message[:300],
                request_id[:100],
            )
            raise TencentAsrError(message)

        results = payload.get("flash_result") or []
        first = results[0] if results else {}
        transcript = str(first.get("text") or "").strip()
        segments = []
        for sentence in first.get("sentence_list") or []:
            text = str(sentence.get("text") or "").strip()
            if not text:
                continue
            sentence_start = milliseconds(sentence.get("start_time"))
            sentence_end = milliseconds(sentence.get("end_time"))
            raw_words = sentence.get("word_list") or []
            word_offset = relative_word_offset(
                raw_words,
                sentence_start=sentence_start,
                sentence_end=sentence_end,
            )
            if word_offset > 0:
                logger.info(
                    "Tencent Flash ASR normalized sentence-relative word times "
                    "sentence_start=%s word_count=%s",
                    sentence_start,
                    len(raw_words),
                )
            words = []
            for word in raw_words:
                word_text = str(word.get("word") or "").strip()
                if word_text:
                    words.append({
                        "text": word_text,
                        "start_seconds": milliseconds(word.get("start_time")) + word_offset,
                        "end_seconds": milliseconds(word.get("end_time")) + word_offset,
                    })
            segments.append({
                "text": text,
                "start_seconds": sentence_start,
                "end_seconds": sentence_end,
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


def relative_word_offset(
    words: list[dict], *, sentence_start: float, sentence_end: float
) -> float:
    """Choose absolute or sentence-relative Tencent word times without moving ambiguous data."""
    if sentence_start <= 0 or sentence_end <= sentence_start or not words:
        return 0.0
    tolerance = 0.5
    raw_ranges = [
        (milliseconds(word.get("start_time")), milliseconds(word.get("end_time")))
        for word in words
    ]

    def fit_count(offset: float) -> int:
        return sum(
            1
            for start, end in raw_ranges
            if start + offset >= sentence_start - tolerance
            and end + offset <= sentence_end + tolerance
        )

    absolute_fit = fit_count(0.0)
    relative_fit = fit_count(sentence_start)
    return sentence_start if relative_fit > absolute_fit else 0.0
