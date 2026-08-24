"""Reusable Version D3 lyrics evidence orchestration and validation.

This module is deliberately independent of FastAPI and DeepSeek's transport. Callers provide an
evidence model, a retriever, a repository, and cached ASR data; the service returns audited lyrics.
"""

from __future__ import annotations

import re
from datetime import datetime
from difflib import SequenceMatcher
from typing import Protocol

from app.models import LyricsReconcileRequest
from app.service import fingerprint


class LyricsReconciliationError(Exception):
    pass


class LyricsEvidenceModel(Protocol):
    def assess(self, evidence: dict) -> dict: ...
    def reconcile(self, evidence: dict) -> dict: ...


class LyricsReconcilerService:
    search_gate_confidence = 0.72
    forced_search_confidence = 0.28
    maximum_words_per_line = 100
    minimum_text_support = 0.45
    allowed_discard_reasons = {
        "no_audio_evidence",
        "wrong_version",
        "duplicate_error",
        "unsupported",
    }

    def __init__(
        self,
        *,
        repository,
        model: LyricsEvidenceModel,
        retriever,
        model_name: str,
        analysis_version: str,
        reconciliation_version: str,
    ) -> None:
        self.repository = repository
        self.model = model
        self.retriever = retriever
        self.model_name = model_name
        self.analysis_version = analysis_version
        self.reconciliation_version = reconciliation_version
        # DeepSeek output maps ASR word indices. A new ASR timeline version must not
        # reuse lyrics calibrated against the previous whole-song/partial timeline.
        self.cache_version = f"{reconciliation_version}|asr:{analysis_version}"

    def reconcile(
        self,
        *,
        subject_hash: str,
        request: LyricsReconcileRequest,
        asr_analysis: dict,
        now: datetime,
    ) -> dict:
        fingerprint_hash = fingerprint(request.media_fingerprint)
        if not request.force_refresh:
            cached = self.repository.cached_ai_lyrics(
                subject_hash, fingerprint_hash, self.cache_version
            )
            if cached:
                return {**cached, "status": "cached", "cache_hit": True}

        asr_words = self._indexed_asr_words(asr_analysis)
        candidates, line_text_by_id = self._candidate_evidence(request)
        base_evidence = {
            "song_title": request.song_title,
            "tencent_asr": {
                "transcript": str(asr_analysis.get("transcript") or ""),
                "words": asr_words,
            },
            "candidate_lyrics": candidates,
        }
        local_scores = {
            candidate["candidate_id"]: evidence_similarity(
                str(asr_analysis.get("transcript") or ""),
                "\n".join(line["text"] for line in candidate["lines"]),
            )
            for candidate in candidates
        }
        best_local_score = max(local_scores.values(), default=0.0)
        assessment = self.model.assess(base_evidence) if candidates else {
            "candidate_scores": [],
            "need_web_search": True,
            "reason_code": "no_candidates",
        }
        model_requests_search = assessment.get("need_web_search") is True
        should_search = not candidates or best_local_score < self.forced_search_confidence or (
            model_requests_search and best_local_score < self.search_gate_confidence
        )

        web_candidates = self.retriever.search(request.song_title) if should_search else []
        for candidate in web_candidates:
            candidates.append({
                "candidate_id": candidate.candidate_id,
                "source": candidate.source,
                "url": candidate.url,
                "retrieved_text": candidate.text,
            })
        final_evidence = {
            **base_evidence,
            "candidate_lyrics": candidates,
            "assessment": self._bounded_assessment(assessment),
            "web_search_performed": bool(should_search),
            "web_candidates_found": len(web_candidates),
        }
        model_result = self.model.reconcile(final_evidence)
        result = self._validated_result(
            model_result=model_result,
            asr_words=asr_words,
            candidates=candidates,
            line_text_by_id=line_text_by_id,
            web_search_used=bool(web_candidates),
        )
        self.repository.store_ai_lyrics(
            subject_hash=subject_hash,
            fingerprint_hash=fingerprint_hash,
            reconciliation_version=self.cache_version,
            result=result,
            now=now,
        )
        return result

    def _validated_result(
        self,
        *,
        model_result: dict,
        asr_words: list[dict],
        candidates: list[dict],
        line_text_by_id: dict[str, str],
        web_search_used: bool,
    ) -> dict:
        try:
            song_confidence = float(model_result["song_match_confidence"])
            primary_source = str(model_result["primary_source"]).strip()
            raw_lines = list(model_result["lines"])
            raw_discarded = list(model_result.get("discarded_lines") or [])
        except (KeyError, TypeError, ValueError) as exc:
            raise LyricsReconciliationError("Invalid reconciliation result") from exc
        if not 0 <= song_confidence <= 1 or not primary_source:
            raise LyricsReconciliationError("Invalid song confidence/source")
        if not 2 <= len(raw_lines) <= 300:
            raise LyricsReconciliationError("Reconciled lyrics require 2...300 lines")

        candidate_ids = {str(candidate["candidate_id"]) for candidate in candidates}
        allowed_sources = candidate_ids | {"mixed", "asr_only"}
        if primary_source not in allowed_sources:
            raise LyricsReconciliationError("Unknown primary lyric source")
        web_text_by_id = {
            str(candidate["candidate_id"]): str(candidate.get("retrieved_text") or "")
            for candidate in candidates
            if candidate.get("retrieved_text")
        }
        all_candidate_text = "\n".join(line_text_by_id.values()) + "\n" + "\n".join(
            web_text_by_id.values()
        )

        previous_end = -1
        lines = []
        for raw in raw_lines:
            if not isinstance(raw, dict):
                raise LyricsReconciliationError("Invalid reconciled lyric line")
            try:
                text = " ".join(str(raw["text"]).split())
                start_index = raw["asr_word_start_index"]
                end_index = raw["asr_word_end_index"]
                source = str(raw["source"]).strip()
                source_line_ids = [str(value) for value in raw.get("source_line_ids") or []]
                confidence = float(raw["confidence"])
                text_corrected = raw["text_corrected"]
            except (KeyError, TypeError, ValueError) as exc:
                raise LyricsReconciliationError("Invalid reconciled lyric line") from exc
            if (
                isinstance(start_index, bool)
                or isinstance(end_index, bool)
                or not isinstance(start_index, int)
                or not isinstance(end_index, int)
            ):
                raise LyricsReconciliationError("Lyric line requires integer ASR indices")
            if not isinstance(text_corrected, bool) or not text or len(text) > 500:
                raise LyricsReconciliationError("Invalid reconciled lyric text")
            if source not in allowed_sources or not 0 <= confidence <= 1:
                raise LyricsReconciliationError("Invalid reconciled line source/confidence")
            if (
                start_index <= previous_end
                or end_index < start_index
                or end_index - start_index >= self.maximum_words_per_line
                or end_index >= len(asr_words)
            ):
                raise LyricsReconciliationError("ASR word ranges must be monotonic and bounded")
            if len(source_line_ids) > 20 or any(
                source_id not in line_text_by_id for source_id in source_line_ids
            ):
                raise LyricsReconciliationError("Unknown candidate line evidence")
            selected_words = asr_words[start_index:end_index + 1]
            asr_text = " ".join(word["text"] for word in selected_words)
            references = [asr_text]
            references.extend(line_text_by_id[source_id] for source_id in source_line_ids)
            if source in web_text_by_id:
                references.append(web_text_by_id[source])
            if source == "mixed":
                references.append(all_candidate_text)
            if max((token_coverage(text, value) for value in references), default=0) < self.minimum_text_support:
                raise LyricsReconciliationError("Lyric text lacks ASR/candidate support")
            lines.append({
                "text": text,
                "asr_word_start_index": start_index,
                "asr_word_end_index": end_index,
                "start_seconds": selected_words[0]["start_seconds"],
                "end_seconds": selected_words[-1]["end_seconds"],
                "source": source,
                "source_line_ids": source_line_ids,
                "confidence": confidence,
                "text_corrected": text_corrected,
            })
            previous_end = end_index

        discarded = []
        for raw in raw_discarded[:300]:
            if not isinstance(raw, dict):
                raise LyricsReconciliationError("Invalid discarded lyric line")
            try:
                source_line_id = raw.get("source_line_id")
                text = " ".join(str(raw["text"]).split())
                reason = str(raw["reason"])
            except (KeyError, TypeError, ValueError) as exc:
                raise LyricsReconciliationError("Invalid discarded lyric line") from exc
            if source_line_id is not None and str(source_line_id) not in line_text_by_id:
                raise LyricsReconciliationError("Unknown discarded candidate line")
            if not text or len(text) > 500 or reason not in self.allowed_discard_reasons:
                raise LyricsReconciliationError("Invalid discarded lyric evidence")
            discarded.append({
                "source_line_id": str(source_line_id) if source_line_id is not None else None,
                "text": text,
                "reason": reason,
            })
        return {
            "status": "completed",
            "cache_hit": False,
            "model": self.model_name,
            "reconciliation_version": self.reconciliation_version,
            "song_match_confidence": song_confidence,
            "primary_source": primary_source,
            "web_search_used": web_search_used,
            "lines": lines,
            "discarded_lines": discarded,
        }

    @staticmethod
    def _candidate_evidence(request: LyricsReconcileRequest):
        candidates = []
        line_text_by_id = {}
        for candidate in request.candidates:
            lines = []
            for line in candidate.lines:
                source_line_id = f"{candidate.candidate_id}:{line.line_identifier}"
                line_text_by_id[source_line_id] = line.text
                lines.append({
                    "source_line_id": source_line_id,
                    "text": line.text,
                    "original_start_seconds": line.original_start_seconds,
                    "original_end_seconds": line.original_end_seconds,
                })
            candidates.append({
                "candidate_id": candidate.candidate_id,
                "source": candidate.source,
                "title": candidate.title,
                "artist": candidate.artist,
                "lines": lines,
            })
        return candidates, line_text_by_id

    @staticmethod
    def _indexed_asr_words(asr_analysis: dict) -> list[dict]:
        words = []
        for segment in asr_analysis.get("segments") or []:
            for word in segment.get("words") or []:
                text = " ".join(str(word.get("text") or "").split())
                try:
                    start = float(word["start_seconds"])
                    end = float(word["end_seconds"])
                except (KeyError, TypeError, ValueError) as exc:
                    raise LyricsReconciliationError("Invalid cached ASR word timing") from exc
                if not text or start < 0 or end < start:
                    raise LyricsReconciliationError("Invalid cached ASR word")
                words.append({
                    "index": len(words),
                    "text": text,
                    "start_seconds": start,
                    "end_seconds": end,
                })
        if len(words) < 3:
            raise LyricsReconciliationError("Cached ASR has insufficient word timestamps")
        if any(left["start_seconds"] > right["start_seconds"] for left, right in zip(words, words[1:])):
            raise LyricsReconciliationError("Cached ASR word timestamps are not monotonic")
        return words

    @staticmethod
    def _bounded_assessment(assessment: dict) -> dict:
        scores = []
        for raw in list(assessment.get("candidate_scores") or [])[:3]:
            try:
                confidence = max(0.0, min(1.0, float(raw["confidence"])))
                candidate_id = str(raw["candidate_id"])[:128]
            except (KeyError, TypeError, ValueError):
                continue
            scores.append({"candidate_id": candidate_id, "confidence": confidence})
        return {
            "candidate_scores": scores,
            "need_web_search": assessment.get("need_web_search") is True,
            "reason_code": str(assessment.get("reason_code") or "unspecified")[:128],
        }


def normalized_tokens(value: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", value.lower())


def token_coverage(query: str, reference: str) -> float:
    query_tokens = normalized_tokens(query)
    reference_tokens = normalized_tokens(reference)
    if not query_tokens or not reference_tokens:
        return 0.0
    counts = {}
    for token in reference_tokens:
        counts[token] = counts.get(token, 0) + 1
    matches = 0
    for token in query_tokens:
        if counts.get(token, 0) > 0:
            matches += 1
            counts[token] -= 1
    return matches / len(query_tokens)


def evidence_similarity(left: str, right: str) -> float:
    normalized_left = " ".join(normalized_tokens(left))
    normalized_right = " ".join(normalized_tokens(right))
    if not normalized_left or not normalized_right:
        return 0.0
    sequence = SequenceMatcher(None, normalized_left, normalized_right).ratio()
    return max(sequence, token_coverage(left, right), token_coverage(right, left))


__all__ = [
    "LyricsEvidenceModel",
    "LyricsReconciliationError",
    "LyricsReconcilerService",
    "evidence_similarity",
    "token_coverage",
]
