"""Independent, cached, line-preserving Chinese translation service."""

from __future__ import annotations

import hashlib
from datetime import datetime

from pydantic import TypeAdapter, ValidationError

from app.models import LyricsTranslateRequest, LyricsTranslatedLine


class LyricsTranslationValidationError(ValueError):
    pass


class LyricsTranslationService:
    def __init__(self, *, repository, model, model_name: str) -> None:
        self.repository = repository
        self.model = model
        self.model_name = model_name

    def translate(
        self,
        *,
        subject_hash: str,
        request: LyricsTranslateRequest,
        now: datetime,
    ) -> dict:
        fingerprint_hash = hashlib.sha256(
            request.media_fingerprint.strip().encode("utf-8")
        ).hexdigest()
        cached = self.repository.cached_lyrics_translation(
            subject_hash=subject_hash,
            fingerprint_hash=fingerprint_hash,
            english_lyrics_content_hash=request.english_lyrics_content_hash,
            translation_version=request.translation_version,
            target_language=request.target_language,
            model_name=self.model_name,
        )
        if cached:
            return {**cached, "cache_hit": True}

        evidence = {
            "media_fingerprint": request.media_fingerprint,
            "english_lyrics_content_hash": request.english_lyrics_content_hash,
            "translation_version": request.translation_version,
            "target_language": request.target_language,
            "lines": [line.model_dump(mode="json") for line in request.lines],
        }
        raw = self.model.translate(evidence)
        try:
            translated = self._validated_lines(raw, request)
        except LyricsTranslationValidationError:
            # DeepSeek occasionally drifts from JSON schema on a longer song. One bounded
            # retry is allowed only before anything is cached; the same strict validator
            # still decides whether the result is accepted.
            retry_evidence = {
                **evidence,
                "contract_retry": (
                    "The previous response violated the exact schema. Return every input "
                    "line_identifier once, in order, with only chinese_text and optional "
                    "confidence. Do not return timestamps or any additional keys."
                ),
            }
            translated = self._validated_lines(
                self.model.translate(retry_evidence),
                request,
            )
        result = {
            "status": "completed",
            "cache_hit": False,
            "model": self.model_name,
            "translation_version": request.translation_version,
            "target_language": request.target_language,
            "english_lyrics_content_hash": request.english_lyrics_content_hash,
            "lines": [line.model_dump(mode="json") for line in translated],
        }
        self.repository.store_lyrics_translation(
            subject_hash=subject_hash,
            fingerprint_hash=fingerprint_hash,
            english_lyrics_content_hash=request.english_lyrics_content_hash,
            translation_version=request.translation_version,
            target_language=request.target_language,
            model_name=self.model_name,
            result=result,
            now=now,
        )
        return result

    @staticmethod
    def _validated_lines(raw: dict, request: LyricsTranslateRequest) -> list[LyricsTranslatedLine]:
        if set(raw) != {"lines"} or not isinstance(raw.get("lines"), list):
            raise LyricsTranslationValidationError("translation must contain only lines")
        try:
            lines = TypeAdapter(list[LyricsTranslatedLine]).validate_python(raw["lines"])
        except ValidationError as exc:
            safe_issues = [
                {
                    "loc": list(issue.get("loc") or []),
                    "type": issue.get("type"),
                }
                for issue in exc.errors()
            ]
            raise LyricsTranslationValidationError(
                f"invalid translated line schema issues={safe_issues}"
            ) from exc

        expected = [line.line_identifier for line in request.lines]
        identifiers = [line.line_identifier for line in lines]
        if len(set(identifiers)) != len(identifiers):
            raise LyricsTranslationValidationError("duplicate translated line identifier")
        if any(identifier not in set(expected) for identifier in identifiers):
            raise LyricsTranslationValidationError("unknown translated line identifier")
        if identifiers != expected:
            raise LyricsTranslationValidationError(
                "translated lines must cover every input identifier in order"
            )
        if any(not line.chinese_text.strip() for line in lines):
            raise LyricsTranslationValidationError("translated text must not be blank")
        return lines


__all__ = ["LyricsTranslationService", "LyricsTranslationValidationError"]
