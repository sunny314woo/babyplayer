"""BabyPlayer AI Lyrics 逐行文本 repair 验证服务。

当前主要功能：将受限证据发给 DeepSeek，验证每行建议，并仅返回不含时间戳的 repairs。
最近修改：2026-08-23 以 Version C original-line contract 取代自由 ASR segment 改写。
"""

import re
from difflib import SequenceMatcher

from app.deepseek_refiner import DeepSeekRefinerError
from app.models import LyricsRefineRequest


class LyricsRefinementValidationError(Exception):
    pass


class RepairValidationPolicy:
    minimum_modification_confidence = 0.55
    maximum_length_multiplier = 1.35
    maximum_length_slack = 20
    minimum_single_source_similarity = 0.45
    minimum_combined_support = 0.40
    original_text_weight = 0.60
    aligned_asr_weight = 0.40


class LyricsRefinerService:
    def __init__(self, client, model: str) -> None:
        self.client = client
        self.model = model

    def refine(self, request: LyricsRefineRequest) -> dict:
        # 【MODIFIED】只解析逐行文本 repair 字段，任何模型返回的时间字段都不进入响应。
        evidence = request.model_dump()
        # The media fingerprint is useful for client correlation, not model evidence.
        evidence.pop("media_fingerprint", None)
        refinement = self.client.refine(evidence)
        original_by_id = {line.line_identifier: line for line in request.original_lines}
        repairs_by_id: dict[str, dict] = {}
        for repair in refinement.repairs:
            try:
                if not isinstance(repair["should_modify"], bool):
                    raise TypeError("should_modify must be boolean")
                line_identifier = str(repair["line_identifier"])
                original_text = str(repair["original_text"])
                suggested_text = str(repair["suggested_text"]).strip()
                should_modify = repair["should_modify"]
                repair_evidence = str(repair["evidence"]).strip()
                confidence = float(repair["confidence"])
            except (KeyError, TypeError, ValueError) as exc:
                raise LyricsRefinementValidationError("Invalid lyric repair") from exc
            if line_identifier not in original_by_id or line_identifier in repairs_by_id:
                raise LyricsRefinementValidationError("Invalid repair line mapping")
            original_line = original_by_id[line_identifier]
            if original_text != original_line.original_text:
                raise LyricsRefinementValidationError("Original lyric text was not copied exactly")
            if not suggested_text or not repair_evidence or not 0.0 <= confidence <= 1.0:
                raise LyricsRefinementValidationError("Invalid repair evidence")
            if should_modify:
                self._validate_modified_text(
                    original_line=original_line,
                    suggested_text=suggested_text,
                    confidence=confidence,
                )
            else:
                suggested_text = original_line.original_text
            repairs_by_id[line_identifier] = {
                "line_identifier": line_identifier,
                "original_text": original_line.original_text,
                "suggested_text": suggested_text,
                "should_modify": should_modify,
                "evidence": repair_evidence,
                "confidence": confidence,
            }

        if set(repairs_by_id) != set(original_by_id):
            raise LyricsRefinementValidationError("Every original lyric line must be preserved")
        if not 0.0 <= refinement.overall_confidence <= 1.0:
            raise LyricsRefinementValidationError("Invalid overall confidence")

        return {
            "status": "completed",
            "model": self.model,
            "overall_confidence": refinement.overall_confidence,
            "repairs": [repairs_by_id[line.line_identifier] for line in request.original_lines],
        }

    # 【MODIFIED】只有同时受原文或对齐 ASR words 支持的小范围修复才能通过。
    def _validate_modified_text(self, *, original_line, suggested_text: str, confidence: float) -> None:
        """验证一行修复；输入为原行、建议文本和置信度，输出为 None/异常，不修改数据库或请求状态。"""
        if confidence < RepairValidationPolicy.minimum_modification_confidence:
            raise LyricsRefinementValidationError("Modification confidence is too low")
        maximum_length = (
            len(original_line.original_text) * RepairValidationPolicy.maximum_length_multiplier
            + RepairValidationPolicy.maximum_length_slack
        )
        if len(suggested_text) > maximum_length:
            raise LyricsRefinementValidationError("Repair added unsupported content")
        original_similarity = similarity(original_line.original_text, suggested_text)
        aligned_asr_text = " ".join(word.text for word in original_line.aligned_words)
        asr_similarity = similarity(aligned_asr_text, suggested_text) if aligned_asr_text else 0
        combined_support = (
            original_similarity * RepairValidationPolicy.original_text_weight
            + asr_similarity * RepairValidationPolicy.aligned_asr_weight
        )
        if (
            max(original_similarity, asr_similarity)
            < RepairValidationPolicy.minimum_single_source_similarity
            or combined_support < RepairValidationPolicy.minimum_combined_support
        ):
            raise LyricsRefinementValidationError("Repair is not supported by lyric/ASR evidence")


def similarity(left: str, right: str) -> float:
    normalize = lambda value: " ".join(re.findall(r"[a-z0-9]+", value.lower()))
    return SequenceMatcher(None, normalize(left), normalize(right)).ratio()


__all__ = [
    "DeepSeekRefinerError",
    "LyricsRefinementValidationError",
    "LyricsRefinerService",
]
