"""Conservative VAD evidence must suppress phrases without deleting isolated sung words."""

from app.voice_activity import (
    INSTRUMENTAL_HALLUCINATION_FLAG,
    LOW_VOICE_ACTIVITY_FLAG,
    VoiceActivityEvidence,
    annotate_asr_segments,
    voice_activity_summary,
)


def test_contiguous_low_activity_phrase_is_flagged_but_isolated_word_is_preserved() -> None:
    evidence = VoiceActivityEvidence(
        detector="test-vad",
        scope="mixed_audio_advisory",
        threshold=0.15,
        frame_seconds=1.0,
        probabilities=(0.01,) * 8,
        speech_intervals=(),
    )
    segments = [
        {
            "text": "thank you for",
            "start_seconds": 0,
            "end_seconds": 3,
            "words": [
                {"text": "thank", "start_seconds": 0, "end_seconds": 1},
                {"text": "you", "start_seconds": 1, "end_seconds": 2},
                {"text": "for", "start_seconds": 2, "end_seconds": 3},
            ],
        },
        {
            "text": "Bear",
            "start_seconds": 5,
            "end_seconds": 6,
            "words": [
                {"text": "Bear", "start_seconds": 5, "end_seconds": 6},
            ],
        },
    ]

    annotated = annotate_asr_segments(
        segments,
        evidence,
        minimum_suspicious_words=3,
        maximum_low_activity_coverage=0.25,
    )

    phrase_words = annotated[0]["words"]
    isolated_word = annotated[1]["words"][0]
    assert all(
        INSTRUMENTAL_HALLUCINATION_FLAG in word["quality_flags"]
        for word in phrase_words
    )
    assert LOW_VOICE_ACTIVITY_FLAG in isolated_word["quality_flags"]
    assert INSTRUMENTAL_HALLUCINATION_FLAG not in isolated_word["quality_flags"]
    assert voice_activity_summary(annotated) == {
        "status": "advisory",
        "detector": "test-vad",
        "scope": "mixed_audio_advisory",
        "analyzed_word_count": 4,
        "low_activity_word_count": 4,
        "suspicious_word_count": 3,
    }


def test_active_interval_prevents_low_activity_flag_even_with_low_mean_score() -> None:
    evidence = VoiceActivityEvidence(
        detector="test-vad",
        scope="mixed_audio_advisory",
        threshold=0.15,
        frame_seconds=1.0,
        probabilities=(0.01, 0.01),
        speech_intervals=((0.0, 2.0),),
    )
    annotated = annotate_asr_segments(
        [{
            "text": "hello",
            "start_seconds": 0,
            "end_seconds": 1,
            "words": [{"text": "hello", "start_seconds": 0, "end_seconds": 1}],
        }],
        evidence,
        minimum_suspicious_words=3,
        maximum_low_activity_coverage=0.25,
    )

    assert annotated[0]["words"][0]["quality_flags"] == []


def test_vocal_stem_filters_weak_repeated_letter_residue_inside_padded_vad() -> None:
    evidence = VoiceActivityEvidence(
        detector="test-vad",
        scope="vocal_stem_gate",
        threshold=0.15,
        frame_seconds=1.0,
        probabilities=(0.08, 0.08),
        speech_intervals=((0.0, 2.0),),
    )
    annotated = annotate_asr_segments(
        [{
            "text": "BB .",
            "start_seconds": 0,
            "end_seconds": 2,
            "words": [
                {"text": "BB", "start_seconds": 0, "end_seconds": 1},
                {"text": ".", "start_seconds": 1, "end_seconds": 2},
            ],
        }],
        evidence,
        minimum_suspicious_words=3,
        maximum_low_activity_coverage=0.25,
    )

    assert all(
        INSTRUMENTAL_HALLUCINATION_FLAG in word["quality_flags"]
        for word in annotated[0]["words"]
    )


def test_vocal_stem_keeps_real_short_words_and_isolated_names() -> None:
    evidence = VoiceActivityEvidence(
        detector="test-vad",
        scope="vocal_stem_gate",
        threshold=0.15,
        frame_seconds=1.0,
        probabilities=(0.01, 0.01),
        speech_intervals=((0.0, 2.0),),
    )
    annotated = annotate_asr_segments(
        [
            {
                "text": "He he",
                "start_seconds": 0,
                "end_seconds": 1,
                "words": [
                    {"text": "He", "start_seconds": 0, "end_seconds": 0.5},
                    {"text": "he", "start_seconds": 0.5, "end_seconds": 1},
                ],
            },
            {
                "text": "Bear",
                "start_seconds": 1,
                "end_seconds": 2,
                "words": [
                    {"text": "Bear", "start_seconds": 1, "end_seconds": 2},
                ],
            },
        ],
        evidence,
        minimum_suspicious_words=3,
        maximum_low_activity_coverage=0.25,
    )

    assert all(
        INSTRUMENTAL_HALLUCINATION_FLAG not in word["quality_flags"]
        for segment in annotated
        for word in segment["words"]
    )


def test_vocal_stem_filters_short_low_coverage_sound_effect_token() -> None:
    evidence = VoiceActivityEvidence(
        detector="test-vad",
        scope="vocal_stem_gate",
        threshold=0.15,
        frame_seconds=1.0,
        probabilities=(0.01,),
        speech_intervals=(),
    )
    annotated = annotate_asr_segments(
        [{
            "text": "Dee.",
            "start_seconds": 0,
            "end_seconds": 1,
            "words": [{"text": "Dee.", "start_seconds": 0, "end_seconds": 1}],
        }],
        evidence,
        minimum_suspicious_words=3,
        maximum_low_activity_coverage=0.25,
    )

    assert INSTRUMENTAL_HALLUCINATION_FLAG in annotated[0]["words"][0][
        "quality_flags"
    ]


def test_reannotation_clears_stale_vad_flags_but_preserves_other_flags() -> None:
    evidence = VoiceActivityEvidence(
        detector="test-vad",
        scope="vocal_stem_gate",
        threshold=0.15,
        frame_seconds=1.0,
        probabilities=(0.9,),
        speech_intervals=((0.0, 1.0),),
    )
    annotated = annotate_asr_segments(
        [{
            "text": "hello",
            "start_seconds": 0,
            "end_seconds": 1,
            "quality_flags": [INSTRUMENTAL_HALLUCINATION_FLAG, "provider_warning"],
            "words": [{
                "text": "hello",
                "start_seconds": 0,
                "end_seconds": 1,
                "quality_flags": [
                    LOW_VOICE_ACTIVITY_FLAG,
                    INSTRUMENTAL_HALLUCINATION_FLAG,
                    "provider_warning",
                ],
            }],
        }],
        evidence,
        minimum_suspicious_words=3,
        maximum_low_activity_coverage=0.25,
    )

    assert annotated[0]["quality_flags"] == ["provider_warning"]
    assert annotated[0]["words"][0]["quality_flags"] == ["provider_warning"]
