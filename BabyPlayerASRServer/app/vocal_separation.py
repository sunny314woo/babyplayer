"""Local vocal-stem separation for the Mac development analysis pipeline.

The model is loaded lazily and retained for subsequent songs.  Separation is
serialized because the upstream model instance mutates per-file paths while it
is running and is not safe to share concurrently.
"""

from __future__ import annotations

import logging
import threading
import wave
from dataclasses import dataclass
from importlib.util import find_spec
from pathlib import Path

from app.config import Settings


logger = logging.getLogger("babyplayer.vocal_separation")


class VocalSeparationError(Exception):
    pass


@dataclass(frozen=True)
class VocalStem:
    path: Path
    duration_seconds: float
    separator: str
    model: str


class LocalVocalStemSeparator:
    """Keep one Apple-Silicon-accelerated Audio Separator model in memory."""

    separator_name = "python-audio-separator-0.44.5"

    def __init__(self, config: Settings, *, separator_factory=None) -> None:
        self.model_filename = config.local_vocal_separation_model
        self.model_directory = Path(
            config.local_vocal_separation_model_directory
        ).expanduser().resolve()
        self._separator_factory = separator_factory
        self._separator = None
        self._lock = threading.Lock()

    @staticmethod
    def available() -> bool:
        return find_spec("audio_separator") is not None

    def model_ready(self) -> bool:
        return (self.model_directory / self.model_filename).is_file()

    def separate(
        self,
        source: Path,
        *,
        output_directory: Path,
        expected_duration_seconds: float,
    ) -> VocalStem:
        output_directory.mkdir(parents=True, exist_ok=True)
        with self._lock:
            separator = self._loaded_separator(output_directory)
            # Audio Separator copies output_dir into the loaded architecture object.
            # Both values must move together before processing the next unique file.
            separator.output_dir = str(output_directory)
            model_instance = getattr(separator, "model_instance", None)
            if model_instance is not None:
                model_instance.output_dir = str(output_directory)
            try:
                outputs = separator.separate(
                    str(source),
                    custom_output_names={"Vocals": "vocal-stem"},
                )
            except Exception as exc:
                raise VocalSeparationError("Mac 人声分离执行失败") from exc

        vocal_path = self._resolve_output(outputs, output_directory)
        duration = self._validated_wave_duration(
            vocal_path,
            expected_duration_seconds=expected_duration_seconds,
        )
        return VocalStem(
            path=vocal_path,
            duration_seconds=duration,
            separator=self.separator_name,
            model=self.model_filename,
        )

    def _loaded_separator(self, output_directory: Path):
        if self._separator is not None:
            return self._separator
        if self._separator_factory is None:
            if not self.available():
                raise VocalSeparationError("Mac 尚未安装人声分离依赖")
            from audio_separator.separator import Separator

            factory = Separator
        else:
            factory = self._separator_factory
        self.model_directory.mkdir(parents=True, exist_ok=True)
        try:
            separator = factory(
                log_level=logging.WARNING,
                model_file_dir=str(self.model_directory),
                output_dir=str(output_directory),
                output_format="WAV",
                output_single_stem="Vocals",
                sample_rate=44_100,
                mdx_params={
                    "hop_length": 1024,
                    "segment_size": 256,
                    "overlap": 0.25,
                    "batch_size": 1,
                    "enable_denoise": False,
                },
            )
            separator.load_model(model_filename=self.model_filename)
        except Exception as exc:
            logger.exception(
                "Local vocal separation model load failed model=%s",
                self.model_filename,
            )
            raise VocalSeparationError("Mac 无法加载人声分离模型") from exc
        self._separator = separator
        logger.info("Local vocal separation model loaded model=%s", self.model_filename)
        return separator

    @staticmethod
    def _resolve_output(outputs, output_directory: Path) -> Path:
        root = output_directory.resolve()
        candidates = []
        for raw_path in outputs or []:
            candidate = Path(raw_path)
            if not candidate.is_absolute():
                candidate = root / candidate
            try:
                resolved = candidate.resolve(strict=True)
            except OSError:
                continue
            if resolved.is_file() and resolved.is_relative_to(root):
                candidates.append(resolved)
        if not candidates:
            raise VocalSeparationError("Mac 人声分离未生成有效人声轨")
        named = next(
            (value for value in candidates if "vocal" in value.name.casefold()),
            candidates[0],
        )
        return named

    @staticmethod
    def _validated_wave_duration(
        path: Path,
        *,
        expected_duration_seconds: float,
    ) -> float:
        try:
            with wave.open(str(path), "rb") as audio:
                sample_rate = audio.getframerate()
                frame_count = audio.getnframes()
                channel_count = audio.getnchannels()
        except (OSError, EOFError, wave.Error) as exc:
            raise VocalSeparationError("Mac 人声轨格式无效") from exc
        if sample_rate <= 0 or frame_count <= 0 or channel_count <= 0:
            raise VocalSeparationError("Mac 人声轨为空")
        duration = frame_count / sample_rate
        tolerance = max(1.0, expected_duration_seconds * 0.01)
        if abs(duration - expected_duration_seconds) > tolerance:
            raise VocalSeparationError("Mac 人声轨时长与原音频不一致")
        return duration


__all__ = [
    "LocalVocalStemSeparator",
    "VocalSeparationError",
    "VocalStem",
]
