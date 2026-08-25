"""Mac 本地歌词测试过程文件输出。

只在非 production 且显式配置输出目录时启用；不记录任何 token 或云服务密钥。
"""

import hashlib
import json
import re
from pathlib import Path


class DevelopmentArtifactWriter:
    """保存 ASR/DeepSeek 可观察文件；输入已校验 API 数据，副作用仅限开发输出目录。"""

    def __init__(self, directory: str, *, enabled: bool) -> None:
        self.root = Path(directory).expanduser() if directory else None
        self.enabled = bool(enabled and self.root)

    def store_asr(
        self,
        *,
        media_fingerprint: str,
        media_title: str,
        audio: bytes,
        response: dict,
        force_refresh: bool,
        audio_file_name: str = "uploaded_audio.m4a",
    ) -> None:
        if not self.enabled:
            return
        folder = self._folder(media_fingerprint, media_title)
        self._write_json(folder / "request.json", {
            "media_fingerprint_hash": hashlib.sha256(
                media_fingerprint.encode("utf-8")
            ).hexdigest(),
            "media_title": media_title,
            "force_refresh": force_refresh,
            "audio_bytes": len(audio),
            "audio_preprocessing": response.get("audio_preprocessing"),
        })
        self._write_bytes(folder / audio_file_name, audio)
        self._write_json(folder / "asr_raw.json", response)
        self._write_text(folder / "asr.srt", self._segments_srt(response.get("segments") or []))
        self._write_text(
            folder / "asr_quality_filtered.srt",
            self._quality_filtered_segments_srt(response.get("segments") or []),
        )
        self._write_json(folder / "voice_activity.json", {
            "summary": response.get("voice_activity"),
            "flagged_words": [
                {
                    "text": word.get("text"),
                    "start_seconds": word.get("start_seconds"),
                    "end_seconds": word.get("end_seconds"),
                    "voice_activity_score": word.get("voice_activity_score"),
                    "voice_activity_coverage": word.get("voice_activity_coverage"),
                    "quality_flags": word.get("quality_flags") or [],
                }
                for segment in response.get("segments") or []
                for word in segment.get("words") or []
                if word.get("quality_flags")
            ],
        })
        self._write_json(
            folder / "audio_preprocessing.json",
            response.get("audio_preprocessing"),
        )

    def store_deepseek(
        self,
        *,
        media_fingerprint: str,
        media_title: str,
        request: dict,
        response: dict,
    ) -> None:
        if not self.enabled:
            return
        folder = self._folder(media_fingerprint, media_title)
        self._write_json(folder / "candidates.json", request.get("candidates") or [])
        self._write_json(folder / "deepseek_input.json", request)
        self._write_json(folder / "deepseek_raw.json", response)
        self._write_text(folder / "ai.srt", self._lines_srt(response.get("lines") or []))

    def _folder(self, media_fingerprint: str, media_title: str) -> Path:
        assert self.root is not None
        safe_title = re.sub(r"[^\w\-\u4e00-\u9fff]+", "-", media_title).strip("-")
        digest = hashlib.sha256(media_fingerprint.encode("utf-8")).hexdigest()[:12]
        folder = self.root / f"{safe_title[:80] or 'untitled'}-{digest}"
        folder.mkdir(parents=True, exist_ok=True)
        return folder

    @staticmethod
    def _segments_srt(segments: list[dict]) -> str:
        entries = [
            (segment.get("start_seconds"), segment.get("end_seconds"), segment.get("text"))
            for segment in segments
        ]
        return DevelopmentArtifactWriter._srt(entries)

    @staticmethod
    def _quality_filtered_segments_srt(segments: list[dict]) -> str:
        entries = []
        for segment in segments:
            raw_words = segment.get("words") or []
            visible_words = [
                word for word in raw_words
                if "possible_instrumental_hallucination"
                not in (word.get("quality_flags") or [])
            ]
            if raw_words and not visible_words:
                continue
            if visible_words:
                entries.append((
                    visible_words[0].get("start_seconds"),
                    visible_words[-1].get("end_seconds"),
                    " ".join(
                        str(word.get("text") or "").strip()
                        for word in visible_words
                        if str(word.get("text") or "").strip()
                    ),
                ))
            else:
                entries.append((
                    segment.get("start_seconds"),
                    segment.get("end_seconds"),
                    segment.get("text"),
                ))
        return DevelopmentArtifactWriter._srt(entries)

    @staticmethod
    def _lines_srt(lines: list[dict]) -> str:
        entries = [
            (line.get("start_seconds"), line.get("end_seconds"), line.get("text"))
            for line in lines
        ]
        return DevelopmentArtifactWriter._srt(entries)

    @staticmethod
    def _srt(entries) -> str:
        rows: list[str] = []
        index = 1
        for start, end, text in entries:
            if not isinstance(text, str) or not text.strip():
                continue
            try:
                start_value = max(0.0, float(start))
                end_value = max(start_value, float(end))
            except (TypeError, ValueError):
                continue
            rows.extend([
                str(index),
                f"{DevelopmentArtifactWriter._timestamp(start_value)} --> "
                f"{DevelopmentArtifactWriter._timestamp(end_value)}",
                text.strip(),
                "",
            ])
            index += 1
        return "\n".join(rows)

    @staticmethod
    def _timestamp(seconds: float) -> str:
        milliseconds = int(round(seconds * 1000))
        hours, remainder = divmod(milliseconds, 3_600_000)
        minutes, remainder = divmod(remainder, 60_000)
        whole_seconds, milliseconds = divmod(remainder, 1000)
        return f"{hours:02d}:{minutes:02d}:{whole_seconds:02d},{milliseconds:03d}"

    @staticmethod
    def _write_json(path: Path, value) -> None:
        DevelopmentArtifactWriter._write_text(
            path,
            json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        )

    @staticmethod
    def _write_text(path: Path, value: str) -> None:
        DevelopmentArtifactWriter._write_bytes(path, value.encode("utf-8"))

    @staticmethod
    def _write_bytes(path: Path, value: bytes) -> None:
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_bytes(value)
        temporary.replace(path)


__all__ = ["DevelopmentArtifactWriter"]
