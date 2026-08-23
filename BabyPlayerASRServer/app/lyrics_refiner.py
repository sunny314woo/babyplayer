import re
from difflib import SequenceMatcher

from app.deepseek_refiner import DeepSeekRefinerError
from app.models import LyricsRefineRequest


class LyricsRefinementValidationError(Exception):
    pass


class LyricsRefinerService:
    def __init__(self, client, model: str) -> None:
        self.client = client
        self.model = model

    def refine(self, request: LyricsRefineRequest) -> dict:
        evidence = request.model_dump()
        # The media fingerprint is useful for client correlation, not model evidence.
        evidence.pop("media_fingerprint", None)
        refinement = self.client.refine(evidence)
        segment_by_index = {segment.index: segment for segment in request.segments}
        corrected_by_index: dict[int, str] = {}
        for line in refinement.lines:
            try:
                index = int(line["segment_index"])
                text = str(line["text"]).strip()
            except (KeyError, TypeError, ValueError) as exc:
                raise LyricsRefinementValidationError("Invalid corrected line") from exc
            if index not in segment_by_index or index in corrected_by_index or not text:
                raise LyricsRefinementValidationError("Invalid corrected segment mapping")
            if len(text) > 500:
                raise LyricsRefinementValidationError("Corrected line is too long")
            corrected_by_index[index] = text

        if set(corrected_by_index) != set(segment_by_index):
            raise LyricsRefinementValidationError("Every ASR segment must be preserved")
        if not 0.0 <= refinement.confidence <= 1.0:
            raise LyricsRefinementValidationError("Invalid confidence")
        if refinement.selected_candidate_identifier is not None:
            available_ids = {candidate.identifier for candidate in request.candidates}
            if refinement.selected_candidate_identifier not in available_ids:
                raise LyricsRefinementValidationError("Unknown candidate identifier")

        original = " ".join(segment.text for segment in request.segments)
        corrected = " ".join(corrected_by_index[index] for index in sorted(corrected_by_index))
        if len(corrected) > len(original) * 1.6 + 80:
            raise LyricsRefinementValidationError("Correction added unsupported content")
        audio_similarity = similarity(original, corrected)
        candidate_similarity = max(
            (similarity(" ".join(candidate.lines), corrected) for candidate in request.candidates),
            default=0,
        )
        # Audio is the primary evidence. Candidate agreement can rescue ASR spelling
        # errors, but cannot justify text unrelated to what was heard.
        if audio_similarity < 0.32 or (audio_similarity * 0.7 + candidate_similarity * 0.3) < 0.42:
            raise LyricsRefinementValidationError("Correction is not supported by audio evidence")

        lines = []
        for index in sorted(segment_by_index):
            segment = segment_by_index[index]
            lines.append({
                "segment_index": index,
                "start_seconds": segment.start_seconds,
                "end_seconds": segment.end_seconds,
                "text": corrected_by_index[index],
            })
        return {
            "status": "completed",
            "model": self.model,
            "confidence": refinement.confidence,
            "selected_candidate_identifier": refinement.selected_candidate_identifier,
            "lines": lines,
        }


def similarity(left: str, right: str) -> float:
    normalize = lambda value: " ".join(re.findall(r"[a-z0-9]+", value.lower()))
    return SequenceMatcher(None, normalize(left), normalize(right)).ratio()


__all__ = [
    "DeepSeekRefinerError",
    "LyricsRefinementValidationError",
    "LyricsRefinerService",
]
