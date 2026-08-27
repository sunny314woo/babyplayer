from dataclasses import replace
from pathlib import Path
import wave

import pytest

from app.config import Settings
from app.local_analysis import (
    LocalMediaAudioExtractor,
    LocalNoVocalsDetectedError,
)
from app.models import LocalAnalysisJobRequest
from app.vocal_separation import (
    LocalVocalStemSeparator,
    VocalSeparationError,
    VocalStem,
)
from app.voice_activity import VoiceActivityEvidence


def write_wave(path: Path, *, duration_seconds: float = 2.0) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(2)
        audio.setsampwidth(2)
        audio.setframerate(44_100)
        audio.writeframes(b"\0\0\0\0" * int(44_100 * duration_seconds))


class FakeSeparatorEngine:
    instances = []

    def __init__(self, **arguments):
        self.arguments = arguments
        self.output_dir = arguments["output_dir"]
        self.model_instance = type("Model", (), {"output_dir": self.output_dir})()
        self.loaded = []
        self.separated = []
        self.__class__.instances.append(self)

    def load_model(self, *, model_filename):
        self.loaded.append(model_filename)

    def separate(self, source, *, custom_output_names):
        self.separated.append(source)
        output = Path(self.output_dir) / f"{custom_output_names['Vocals']}.wav"
        write_wave(output)
        return [str(output)]


def configured(tmp_path):
    return replace(
        Settings(),
        local_media_roots=(str(tmp_path),),
        local_vocal_separation_enabled=True,
        local_vocal_separation_model="Kim_Vocal_2.onnx",
        local_vocal_separation_model_directory=str(tmp_path / "models"),
        local_preprocessed_audio_cache_directory=str(
            tmp_path / "preprocessed-audio"
        ),
        local_voice_activity_enabled=True,
        max_audio_bytes=1024 * 1024,
    )


def test_separator_loads_model_once_and_moves_each_output_safely(tmp_path) -> None:
    FakeSeparatorEngine.instances.clear()
    config = configured(tmp_path)
    separator = LocalVocalStemSeparator(
        config,
        separator_factory=FakeSeparatorEngine,
    )
    source = tmp_path / "source.wav"
    write_wave(source)

    first = separator.separate(
        source,
        output_directory=tmp_path / "first",
        expected_duration_seconds=2,
    )
    second = separator.separate(
        source,
        output_directory=tmp_path / "second",
        expected_duration_seconds=2,
    )

    engine = FakeSeparatorEngine.instances[0]
    assert len(FakeSeparatorEngine.instances) == 1
    assert engine.loaded == ["Kim_Vocal_2.onnx"]
    assert len(engine.separated) == 2
    assert first.path.parent == (tmp_path / "first").resolve()
    assert second.path.parent == (tmp_path / "second").resolve()
    assert first.separator == "python-audio-separator-0.44.5"


def test_separator_rejects_a_truncated_timeline(tmp_path) -> None:
    class TruncatedEngine(FakeSeparatorEngine):
        def separate(self, source, *, custom_output_names):
            output = Path(self.output_dir) / "vocal-stem.wav"
            write_wave(output, duration_seconds=0.25)
            return [str(output)]

    separator = LocalVocalStemSeparator(
        configured(tmp_path),
        separator_factory=TruncatedEngine,
    )
    source = tmp_path / "source.wav"
    write_wave(source)

    with pytest.raises(VocalSeparationError, match="时长"):
        separator.separate(
            source,
            output_directory=tmp_path / "output",
            expected_duration_seconds=2,
        )


class FakeStemSeparator:
    def __init__(self):
        self.calls = 0

    def separate(self, source, *, output_directory, expected_duration_seconds):
        self.calls += 1
        output = output_directory / "vocal-stem.wav"
        write_wave(output, duration_seconds=expected_duration_seconds)
        return VocalStem(
            path=output,
            duration_seconds=expected_duration_seconds,
            separator="fake-separator",
            model="fake-vocals.onnx",
        )


class FakeVoiceActivityDetector:
    def __init__(self, *, probability=0.8, speech=True):
        self.probability = probability
        self.speech = speech

    def analyze(self, audio, *, duration_seconds):
        assert audio.startswith(b"RIFF")
        return VoiceActivityEvidence(
            detector="fake-vad",
            scope="mixed_audio_advisory",
            threshold=0.15,
            frame_seconds=1,
            probabilities=(self.probability,) * max(1, int(duration_seconds)),
            speech_intervals=((0, duration_seconds),) if self.speech else (),
        )


class IntervalVoiceActivityDetector:
    def __init__(self, intervals):
        self.intervals = tuple(intervals)

    def analyze(self, audio, *, duration_seconds):
        assert audio.startswith(b"RIFF")
        return VoiceActivityEvidence(
            detector="fake-vad",
            scope="mixed_audio_advisory",
            threshold=0.15,
            frame_seconds=1,
            probabilities=(0.8,) * max(1, int(duration_seconds)),
            speech_intervals=self.intervals,
        )


class RecordingExtractor(LocalMediaAudioExtractor):
    def __init__(self, *arguments, **keywords):
        super().__init__(*arguments, **keywords)
        self.commands = []

    def _run_ffmpeg(self, command, output, *, error_message):
        del error_message
        self.commands.append(command)
        if output.suffix == ".wav":
            write_wave(output)
        else:
            output.write_bytes(b"audio-" + output.name.encode())


def local_request(source: Path) -> LocalAnalysisJobRequest:
    return LocalAnalysisJobRequest(
        media_fingerprint="local-vocal-pipeline",
        media_path=str(source),
        duration_seconds=2,
    )


def test_extractor_builds_complete_and_chunk_audio_from_lossless_vocal_stem(
    tmp_path,
) -> None:
    source = tmp_path / "song.mp4"
    source.write_bytes(b"video")
    extractor = RecordingExtractor(
        configured(tmp_path),
        vocal_stem_separator=FakeStemSeparator(),
        voice_activity_detector=FakeVoiceActivityDetector(),
    )

    extracted = extractor.extract(local_request(source))

    assert extracted.data == b"audio-analysis.m4a"
    assert {
        key: extracted.audio_preprocessing[key]
        for key in (
            "source", "decode", "separator", "model",
            "vocal_coverage", "vocal_mean_probability",
        )
    } == {
        "source": "vocal_stem",
        "decode": "pcm_s16le_44100_stereo",
        "separator": "fake-separator",
        "model": "fake-vocals.onnx",
        "vocal_coverage": 1.0,
        "vocal_mean_probability": 0.8,
    }
    assert extracted.audio_preprocessing["planner_status"] == "full_coverage"
    assert extracted.audio_preprocessing["planned_asr_seconds"] == 2
    assert extracted.voice_activity.scope == "vocal_stem_gate"
    assert "pcm_s16le" in extractor.commands[0]
    assert all(
        any(value.endswith("vocal-stem.wav") for value in command)
        for command in extractor.commands[1:]
    )


def test_extractor_vad_sees_full_media_but_chunks_keep_song_relative_offsets(
    tmp_path,
) -> None:
    source = tmp_path / "bounded-song.mp4"
    source.write_bytes(b"video")
    extractor = RecordingExtractor(
        configured(tmp_path),
        vocal_stem_separator=FakeStemSeparator(),
        voice_activity_detector=IntervalVoiceActivityDetector((
            (6.0, 9.0),
            (15.0, 16.0),
        )),
    )
    request = LocalAnalysisJobRequest(
        media_fingerprint="bounded-vocal-pipeline",
        media_path=str(source),
        duration_seconds=20,
        song_start_seconds=5,
        song_end_seconds=18,
    )

    extracted = extractor.extract(request)

    assert extractor.commands[0][extractor.commands[0].index("-t") + 1] == "20.000"
    assert extracted.duration_seconds == 13
    assert [chunk.offset_seconds for chunk in extracted.chunks] == [0, 8.5]
    chunk_commands = [
        command for command in extractor.commands
        if command[-1].endswith(("chunk-000.m4a", "chunk-001.m4a"))
    ]
    assert [
        command[command.index("-ss") + 1] for command in chunk_commands
    ] == ["5.000", "13.500"]
    assert extracted.audio_preprocessing["planned_asr_seconds"] == 9.5
    assert extracted.audio_preprocessing["saved_asr_seconds"] == 3.5


def test_extractor_stops_before_asr_when_vocal_stem_has_no_voice(tmp_path) -> None:
    source = tmp_path / "instrumental.mp4"
    source.write_bytes(b"video")
    extractor = RecordingExtractor(
        configured(tmp_path),
        vocal_stem_separator=FakeStemSeparator(),
        voice_activity_detector=FakeVoiceActivityDetector(
            probability=0.01,
            speech=False,
        ),
    )

    with pytest.raises(LocalNoVocalsDetectedError, match="停止 ASR"):
        extractor.extract(local_request(source))

    # Lossless decode completes, but no provider input chunks are encoded.
    assert len(extractor.commands) == 1


def test_force_refresh_reuses_preprocessed_chunks_across_extractor_restart(
    tmp_path,
) -> None:
    source = tmp_path / "cached-song.mp4"
    source.write_bytes(b"same-video-content")
    config = configured(tmp_path)
    first_separator = FakeStemSeparator()
    first_extractor = RecordingExtractor(
        config,
        vocal_stem_separator=first_separator,
        voice_activity_detector=FakeVoiceActivityDetector(),
    )
    first = first_extractor.extract(local_request(source))

    second_separator = FakeStemSeparator()
    restarted_extractor = RecordingExtractor(
        config,
        vocal_stem_separator=second_separator,
        voice_activity_detector=FakeVoiceActivityDetector(),
    )
    forced_request = local_request(source).model_copy(
        update={"force_refresh": True}
    )
    reused = restarted_extractor.extract(forced_request)

    assert first_separator.calls == 1
    assert second_separator.calls == 0
    assert restarted_extractor.commands == []
    assert reused.data == first.data
    assert reused.chunks == first.chunks
    assert reused.voice_activity == first.voice_activity
    assert first.audio_preprocessing["preprocessing_cache_hit"] is False
    assert reused.audio_preprocessing["preprocessing_cache_hit"] is True
    cache_root = Path(config.local_preprocessed_audio_cache_directory)
    assert len([value for value in cache_root.iterdir() if value.is_dir()]) == 1


def test_preprocessed_audio_cache_invalidates_for_content_or_pipeline_change(
    tmp_path,
) -> None:
    source = tmp_path / "changing-song.mp4"
    source.write_bytes(b"video-v1")
    config = configured(tmp_path)
    initial_separator = FakeStemSeparator()
    RecordingExtractor(
        config,
        vocal_stem_separator=initial_separator,
        voice_activity_detector=FakeVoiceActivityDetector(),
    ).extract(local_request(source))

    source.write_bytes(b"video-v2")
    content_separator = FakeStemSeparator()
    changed_content = RecordingExtractor(
        config,
        vocal_stem_separator=content_separator,
        voice_activity_detector=FakeVoiceActivityDetector(),
    ).extract(local_request(source))

    changed_config = replace(
        config,
        local_vocal_separation_version="separator-pipeline-v-next",
    )
    version_separator = FakeStemSeparator()
    changed_version = RecordingExtractor(
        changed_config,
        vocal_stem_separator=version_separator,
        voice_activity_detector=FakeVoiceActivityDetector(),
    ).extract(local_request(source))

    assert initial_separator.calls == 1
    assert content_separator.calls == 1
    assert version_separator.calls == 1
    assert changed_content.audio_preprocessing["preprocessing_cache_hit"] is False
    assert changed_version.audio_preprocessing["preprocessing_cache_hit"] is False
