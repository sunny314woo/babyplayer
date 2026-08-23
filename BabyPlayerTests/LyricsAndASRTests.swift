//
// LyricsAndASRTests.swift
// BabyPlayer 歌词、ASR、AI 校时、持久化与额度策略的回归测试。
// 当前主要功能：保护普通歌词默认绑定、AI Lyrics 渐进结果、人工优先、稳定 identity 和全局单调对齐。
// 最近修改：2026-08-23 为 Version C — AI Lyrics Repair 建立冻结行为测试。
// 最近修改：2026-08-23 验证 AI 进度卡会展示完整的 ASR、时间轴和字幕内容里程碑。
// 最近修改：2026-08-23 覆盖单曲循环退避与片头边界不得导致音频导出作废。
// 最近修改：2026-08-23 冻结 ASR 临时分段、全局时间戳合并、首段早停与同 fingerprint 任务复用行为。
//

import XCTest
@testable import BabyPlayer

final class LyricsAndASRTests: XCTestCase {
    /// 验证 ASR 计划只包含临时短分段；输入为 320 秒歌曲，输出为多个不超过集中时长的 segment，不修改状态。
    // 【MODIFIED】Tencent ASR 不得再等待完整歌曲 M4A 建立完成。
    func testASRPlanningUsesTemporarySegmentsInsteadOfCompleteM4A() {
        let segments = BabyPlayerASRSegmentPolicy.segments(forSongDuration: 320)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.durationSeconds <= BabyPlayerASRSegmentPolicy.durationSeconds })
        XCTAssertTrue(segments.allSatisfy(\.isTemporary))
        XCTAssertEqual(segments.first?.startSeconds, 0)
    }

    /// 验证第一段可独立成为一次识别工作；输入为 150 秒歌曲，输出第一段元数据，不依赖后续 segment 或完整音频状态。
    // 【MODIFIED】首段生成和上传必须可先于整首其余分段完成。
    func testFirstASRSegmentCanBePreparedIndependently() {
        let first = BabyPlayerASRSegmentPolicy.segments(forSongDuration: 150).first

        XCTAssertEqual(first?.index, 0)
        XCTAssertEqual(first?.startSeconds, 0)
        XCTAssertEqual(first?.durationSeconds, 60)
        XCTAssertEqual(first?.endSeconds, 60)
    }

    /// 验证分段参数集中管理；无输入，输出冻结初始值，不修改状态。
    // 【MODIFIED】60 秒与 3 秒 overlap 禁止散落在提取和合并代码中。
    func testASRSegmentDurationAndOverlapComeFromCentralPolicy() {
        XCTAssertEqual(BabyPlayerASRSegmentPolicy.durationSeconds, 60)
        XCTAssertEqual(BabyPlayerASRSegmentPolicy.overlapSeconds, 3)
        XCTAssertEqual(BabyPlayerASRSegmentPolicy.advanceSeconds, 57)
    }

    /// 验证所有分段连续覆盖整首歌曲；输入为 150 秒歌曲，输出含 overlap 但无缺口的 3 段，不修改状态。
    // 【MODIFIED】60 秒只是 segment 长度，匹配后仍须覆盖整首时间线。
    func testASRSegmentsCoverTheEntireSongWithoutGaps() {
        let segments = BabyPlayerASRSegmentPolicy.segments(forSongDuration: 150)

        XCTAssertEqual(segments.map(\.startSeconds), [0, 57, 114])
        XCTAssertEqual(segments.map(\.durationSeconds), [60, 60, 36])
        XCTAssertEqual(segments.last?.endSeconds, 150)
        for pair in zip(segments, segments.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.1.startSeconds, pair.0.endSeconds)
        }
    }

    /// 验证 segment 局部时间转换为歌曲全局时间；输入为从 57 秒开始的局部 ASR，输出为 58/59 秒全局 word 时间，不修改状态。
    // 【MODIFIED】Tencent timestamp 只在 segment 内有效，合并时必须加 segment start。
    func testSegmentLocalTimestampsConvertToSongGlobalTimeline() {
        let segment = BabyPlayerASRAudioSegment(index: 1, startSeconds: 57, durationSeconds: 60)
        let local = makeAnalysis(segments: [BabyPlayerASRSegment(
            text: "clap hands",
            startSeconds: 1,
            endSeconds: 2.3,
            words: [makeWord("clap", at: 1), makeWord("hands", at: 2)]
        )])

        let merged = BabyPlayerASRSegmentMerger.merge([
            BabyPlayerASRSegmentResult(segment: segment, analysis: local)
        ])

        XCTAssertEqual(merged.segments.flatMap(\.words).map(\.startSeconds), [58, 59])
        XCTAssertEqual(merged.segments.first?.startSeconds, 58)
    }

    /// 验证 overlap 内重复词按全局时间、规范化文本和顺序确定性去重；输入为两个重叠分段，输出单份连续词序列，不修改状态。
    // 【MODIFIED】DeepSeek 不参与 timestamp 合并或去重。
    func testOverlapMergeDeterministicallyDeduplicatesWords() {
        let first = BabyPlayerASRAudioSegment(index: 0, startSeconds: 0, durationSeconds: 60)
        let second = BabyPlayerASRAudioSegment(index: 1, startSeconds: 57, durationSeconds: 60)
        let firstAnalysis = makeAnalysis(segments: [BabyPlayerASRSegment(
            text: "hello little star",
            startSeconds: 56,
            endSeconds: 59.5,
            words: [makeWord("hello", at: 56), makeWord("little", at: 58), makeWord("star", at: 59)]
        )])
        let secondAnalysis = makeAnalysis(segments: [BabyPlayerASRSegment(
            text: "Little STAR shines",
            startSeconds: 1,
            endSeconds: 4.5,
            words: [makeWord("Little", at: 1), makeWord("STAR", at: 2), makeWord("shines", at: 4)]
        )])

        let merged = BabyPlayerASRSegmentMerger.merge([
            BabyPlayerASRSegmentResult(segment: first, analysis: firstAnalysis),
            BabyPlayerASRSegmentResult(segment: second, analysis: secondAnalysis)
        ])

        XCTAssertEqual(merged.segments.flatMap(\.words).map(\.text), ["hello", "little", "star", "shines"])
        XCTAssertEqual(merged.segments.flatMap(\.words).map(\.startSeconds), [56, 58, 59, 61])
    }

    /// 验证第一段明显不匹配时停止；输入为低文本/顺序/coverage 证据，输出 false，不修改状态。
    // 【MODIFIED】首段明确 mismatch 后不得继续消耗后续 Tencent 额度。
    func testClearlyMismatchedFirstSegmentStopsRemainingSegments() {
        let evidence = makeSameSongEvidence(text: 0.04, ordered: 0.05, coverage: 0.04, confidence: 0.18)

        XCTAssertFalse(BabyPlayerASRFirstSegmentPolicy.shouldContinue(after: evidence))
    }

    /// 验证第一段大致匹配时继续；输入为中等同歌证据，输出 true，不修改状态。
    // 【MODIFIED】首段确认大致同歌后必须继续覆盖整首歌曲。
    func testMatchingFirstSegmentContinuesRemainingSegments() {
        let evidence = makeSameSongEvidence(text: 0.45, ordered: 0.52, coverage: 0.48, confidence: 0.56)

        XCTAssertTrue(BabyPlayerASRFirstSegmentPolicy.shouldContinue(after: evidence))
        XCTAssertTrue(BabyPlayerASRFirstSegmentPolicy.shouldContinue(after: nil))
    }

    /// 验证同 fingerprint 并发请求复用同一工作；输入为两个相同 key 的调用，输出同一结果且 operation 只执行一次，只修改测试 registry。
    // 【MODIFIED】单曲循环不得重复创建或上传相同 analysis task。
    func testSameFingerprintReusesOneAnalysisTask() async throws {
        let registry = BabyPlayerASRTaskRegistry()
        let counter = ASRInvocationCounter()
        let operation: @Sendable () async throws -> BabyPlayerASRMatchOutcome = {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return BabyPlayerASRMatchOutcome(
                candidates: [], selected: nil, offsetSeconds: nil, message: "done"
            )
        }

        async let first = registry.value(for: "same-fingerprint", operation: operation)
        async let second = registry.value(for: "same-fingerprint", operation: operation)
        let (firstResult, secondResult) = try await (first, second)
        let messages = [firstResult.message, secondResult.message]
        let invocationCount = await counter.value

        XCTAssertEqual(messages, ["done", "done"])
        XCTAssertEqual(invocationCount, 1)
    }

    /// 验证切歌使用独立任务且旧 generation 失效；输入为两个 fingerprint 和一次媒体 reset，输出两次工作与旧结果禁止应用，只修改测试状态。
    // 【MODIFIED】旧曲后台结果不得污染新曲 UI。
    func testTrackSwitchUsesDifferentTaskAndInvalidatesOldGeneration() async throws {
        let registry = BabyPlayerASRTaskRegistry()
        let counter = ASRInvocationCounter()
        let guardState = LyricsAutomationGenerationGuard()
        let oldGeneration = guardState.resetForNewMedia()

        _ = try await registry.value(for: "track-a") {
            await counter.increment()
            return BabyPlayerASRMatchOutcome(candidates: [], selected: nil, offsetSeconds: nil, message: "a")
        }
        guardState.resetForNewMedia()
        _ = try await registry.value(for: "track-b") {
            await counter.increment()
            return BabyPlayerASRMatchOutcome(candidates: [], selected: nil, offsetSeconds: nil, message: "b")
        }
        let invocationCount = await counter.value

        XCTAssertEqual(invocationCount, 2)
        XCTAssertFalse(guardState.permitsAutomaticResult(startedAt: oldGeneration))
    }

    /// 验证 segment fingerprint 对同范围稳定、对不同范围区分；输入为媒体 fingerprint 和两个 segment，输出稳定且不同的缓存 key，不修改状态。
    // 【MODIFIED】服务端现有 cache 可按 segment 复用，不需要永久保存临时音频。
    func testSegmentFingerprintIsStableAndDistinctPerTimeRange() {
        let first = BabyPlayerASRAudioSegment(index: 0, startSeconds: 0, durationSeconds: 60)
        let second = BabyPlayerASRAudioSegment(index: 1, startSeconds: 57, durationSeconds: 60)

        XCTAssertEqual(
            first.fingerprint(mediaFingerprint: "media"),
            first.fingerprint(mediaFingerprint: "media")
        )
        XCTAssertNotEqual(
            first.fingerprint(mediaFingerprint: "media"),
            second.fingerprint(mediaFingerprint: "media")
        )
    }

    /// 验证完成卡包含用户可见的三个里程碑；输入为 completed 状态，输出文案断言，不修改状态。
    // 【MODIFIED】防止 AI 按钮再次只高亮而没有播放画面反馈。
    func testAIProgressCompletionShowsAllVisibleMilestones() {
        let text = BabyPlayerAILyricsProgress.completed.overlayText

        XCTAssertTrue(text.contains("腾讯云 ASR 比对已经完成"))
        XCTAssertTrue(text.contains("时间轴已重新完成对齐"))
        XCTAssertTrue(text.contains("字幕内容已完成对齐"))
    }

    /// 验证单曲重试使用封顶退避；输入为连续失败次数，输出时间序列，不修改状态。
    // 【MODIFIED】防止单曲循环每轮立即请求，同时确保后台能继续自愈。
    func testSingleRepeatUsesCappedBackoff() {
        let delays = (1...7).map(BabyPlayerAIAnalysisRetryPolicy.delay(afterFailureCount:))

        XCTAssertEqual(delays, [2, 5, 12, 30, 60, 60, 60])
        XCTAssertTrue(BabyPlayerAIAnalysisRetryPolicy.shouldRetry(BabyPlayerASRError.audioExportFailed))
        XCTAssertFalse(BabyPlayerAIAnalysisRetryPolicy.shouldRetry(BabyPlayerASRError.notConfigured))
    }

    /// 验证片头边界越界时回退完整媒体；输入为建议窗口和真实时长，输出安全窗口，不修改状态。
    // 【MODIFIED】片头片尾只影响首选音频片段，不得让 AI 歌词变为不可用。
    func testAudioExportWindowClampsOrFallsBackFromInvalidIntroBoundary() {
        let clamped = BabyPlayerAudioExportPolicy.clampedWindow(
            startSeconds: 15,
            durationSeconds: 100,
            assetDurationSeconds: 90
        )
        let fallback = BabyPlayerAudioExportPolicy.clampedWindow(
            startSeconds: 120,
            durationSeconds: 90,
            assetDurationSeconds: 90
        )

        XCTAssertEqual(clamped, BabyPlayerAudioExportWindow(startSeconds: 15, durationSeconds: 75))
        XCTAssertEqual(fallback, BabyPlayerAudioExportWindow(startSeconds: 0, durationSeconds: 90))
    }

    /// 验证人工点击会同步使已启动自动工作失效；输入是工作 generation，输出是禁止应用，只修改测试内存 guard。
    // 【MODIFIED】Version C 要求 manual lock 在 await repository 之前立即生效。
    func testManualLockImmediatelyInvalidatesInFlightAutomaticGeneration() {
        let guardState = LyricsAutomationGenerationGuard()
        let automaticGeneration = guardState.resetForNewMedia()
        XCTAssertTrue(guardState.permitsAutomaticResult(startedAt: automaticGeneration))

        guardState.lockManually()

        XCTAssertTrue(guardState.isManuallyLocked)
        XCTAssertFalse(guardState.permitsAutomaticResult(startedAt: automaticGeneration))
    }

    func testFirstCandidateIsDefaultAndPersists() async throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let repository = makeRepository(storage)
        let media = makeMedia()
        let first = makeCandidate(id: 1, title: "First", words: "one two three four")
        let second = makeCandidate(id: 2, title: "Second", words: "five six seven eight")

        let playback = await repository.resolvedLyrics(for: media, candidates: [first, second])

        XCTAssertEqual(playback?.candidateID, first.id)
        XCTAssertEqual(playback?.selectionOrigin, .automatic)
        XCTAssertEqual(playback?.isConfirmed, false)
        let reloaded = makeRepository(storage)
        let stored = await reloaded.storedLyrics(for: media)
        XCTAssertEqual(stored?.candidateID, first.id)
        XCTAssertEqual(stored?.isConfirmed, false)
    }

    func testManualBindingCannotBeOverwrittenByASRRecommendation() async throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let repository = makeRepository(storage)
        let media = makeMedia()
        let first = makeCandidate(id: 1, title: "First", words: "one two three four")
        let second = makeCandidate(id: 2, title: "Second", words: "five six seven eight")
        _ = await repository.resolvedLyrics(for: media, candidates: [first, second])
        let manual = await repository.playback(for: second, media: media, selectionOrigin: .manual)
        _ = try await repository.confirm(manual, for: media)

        let automatic = try await repository.applyAutomaticRecommendation(
            first,
            autoOffsetSeconds: 8,
            for: media
        )
        let stored = await repository.storedLyrics(for: media)

        XCTAssertNil(automatic)
        XCTAssertEqual(stored?.candidateID, second.id)
        XCTAssertEqual(stored?.selectionOrigin, .manual)
    }

    func testAutomaticFallbackCanBeReplacedByASRRecommendation() async throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let repository = makeRepository(storage)
        let media = makeMedia()
        let fallback = makeCandidate(id: 1, title: "Downloaded fallback", words: "one two three four")
        let asr = makeCandidate(id: 2, title: "ASR result", words: "five six seven eight")

        _ = await repository.resolvedLyrics(for: media, candidates: [fallback])
        let automatic = try await repository.applyAutomaticRecommendation(
            asr,
            autoOffsetSeconds: media.songStartSeconds,
            for: media
        )
        let stored = await repository.storedLyrics(for: media)

        XCTAssertEqual(automatic?.candidateID, asr.id)
        XCTAssertEqual(automatic?.selectionOrigin, .asr)
        XCTAssertEqual(automatic?.isConfirmed, true)
        XCTAssertEqual(stored?.candidateID, asr.id)
        XCTAssertEqual(stored?.selectionOrigin, .asr)
        XCTAssertEqual(stored?.isConfirmed, true)
    }

    // 【MODIFIED】Version C 保留原有累加与持久化要求，并使用 +0.5 +0.5 -0.1 的冻结示例。
    func testManualOffsetsAccumulatePerLyricAndSurviveReload() async throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let repository = makeRepository(storage)
        let media = makeMedia(songStart: 3)
        let first = makeCandidate(id: 1, title: "First", words: "one two three four")
        let second = makeCandidate(id: 2, title: "Second", words: "five six seven eight")
        _ = await repository.resolvedLyrics(for: media, candidates: [first, second])

        var firstPlayback = await repository.playback(for: first, media: media, selectionOrigin: .manual)
        firstPlayback.timingAdjustment.adjustManually(by: 0.5)
        firstPlayback.timingAdjustment.adjustManually(by: 0.5)
        firstPlayback.timingAdjustment.adjustManually(by: -0.1)
        _ = try await repository.confirm(firstPlayback, for: media)

        var secondPlayback = await repository.playback(for: second, media: media, selectionOrigin: .manual)
        secondPlayback.timingAdjustment.adjustManually(by: -0.5)
        _ = try await repository.confirm(secondPlayback, for: media)

        let firstRestored = await repository.playback(for: first, media: media, selectionOrigin: .manual)
        let reloaded = makeRepository(storage)
        let secondRestored = await reloaded.storedLyrics(for: media)
        let firstAfterReload = await reloaded.playback(for: first, media: media, selectionOrigin: .manual)

        XCTAssertEqual(firstRestored.autoOffsetSeconds, 3, accuracy: 0.0001)
        XCTAssertEqual(firstRestored.manualAdjustmentSeconds, 0.9, accuracy: 0.0001)
        XCTAssertEqual(firstRestored.offsetSeconds, 3.9, accuracy: 0.0001)
        XCTAssertEqual(secondRestored?.candidateID, second.id)
        XCTAssertEqual(secondRestored?.offsetSeconds ?? 0, 2.5, accuracy: 0.0001)
        XCTAssertEqual(firstAfterReload.offsetSeconds, 3.9, accuracy: 0.0001)
    }

    func testMatcherSelectsClearlyLeadingLyricsAndEstimatesOffset() {
        let correct = LyricsCandidate(
            id: 1,
            trackName: "Correct",
            artistName: "Kids",
            albumName: nil,
            duration: 30,
            lines: [
                TimedLyricLine(time: 0, text: "twinkle twinkle little star"),
                TimedLyricLine(time: 2, text: "how I wonder what you are"),
                TimedLyricLine(time: 4, text: "up above the world so high")
            ],
            matchScore: 0,
            providerName: "test"
        )
        let wrong = makeCandidate(
            id: 2,
            title: "Wrong",
            words: "old macdonald had a farm"
        )
        let segments = [
            makeSegment("twinkle twinkle little star", at: 0.5),
            makeSegment("how I wonder what you are", at: 2.5),
            makeSegment("up above the world so high", at: 4.5)
        ]
        let analysis = makeAnalysis(segments: segments)

        let outcome = BabyPlayerLyricsSoundMatcher.match(
            analysis: analysis,
            candidates: [wrong, correct],
            reference: nil,
            sampleStartSeconds: 5,
            preferSoundTimeline: false
        )

        XCTAssertEqual(outcome.selected?.id, correct.id)
        XCTAssertEqual(outcome.offsetSeconds ?? 0, 5.5, accuracy: 0.0001)
    }

    /// 验证儿童歌曲中少量 ASR 错词仍可通过综合 sameSongConfidence；输入是模糊 transcript、顺序、标题、coverage 和时间证据，输出是 AI v1，不修改状态。
    // 【MODIFIED】Version C 禁止仅用单一高阈值要求 ASR 与歌词逐字一致。
    func testSameSongConfidenceAllowsConservativeFuzzyASRMatch() {
        let candidate = LyricsCandidate(
            id: 88,
            trackName: "Twinkle Twinkle Little Star",
            artistName: "Kids",
            albumName: nil,
            duration: 30,
            lines: [
                TimedLyricLine(time: 0, text: "twinkle twinkle little star"),
                TimedLyricLine(time: 2, text: "how I wonder what you are"),
                TimedLyricLine(time: 4, text: "up above the world so high")
            ],
            matchScore: 0,
            providerName: "LRCLIB"
        )
        let words = [
            makeWord("twinkle", at: 1), makeWord("twinkle", at: 1.3),
            makeWord("little", at: 1.6), makeWord("sta", at: 1.9),
            makeWord("how", at: 3), makeWord("I", at: 3.2), makeWord("wonder", at: 3.4),
            makeWord("what", at: 3.6), makeWord("you", at: 3.8), makeWord("are", at: 4),
            makeWord("up", at: 5), makeWord("above", at: 5.2), makeWord("the", at: 5.4),
            makeWord("world", at: 5.6), makeWord("so", at: 5.8), makeWord("hi", at: 6)
        ]
        let analysis = BabyPlayerASRAnalysis(
            status: "completed",
            cacheHit: false,
            provider: "test",
            engineType: "16k_en",
            audioDurationSeconds: 8,
            transcript: "twinkle twinkle little sta how I wonder what you are up above the world so hi",
            segments: [BabyPlayerASRSegment(
                text: "twinkle twinkle little sta how I wonder what you are up above the world so hi",
                startSeconds: 1,
                endSeconds: 6.3,
                words: words
            )],
            monthlyUsedSeconds: 10,
            monthlyReservedSeconds: 0,
            monthlyLimitSeconds: 18_000
        )

        let outcome = BabyPlayerLyricsSoundMatcher.match(
            analysis: analysis,
            candidates: [candidate],
            reference: nil,
            sampleStartSeconds: 0,
            mediaTitle: "Twinkle Twinkle Little Star"
        )

        XCTAssertEqual(outcome.selected?.providerName, "AI 校时歌词")
        XCTAssertEqual(outcome.selected?.lines.map(\.text), candidate.lines.map(\.text))
        XCTAssertTrue(outcome.shouldAutomaticallyApply)
    }

    func testPlainTextSongbookCanGenerateTimedCandidate() {
        let words = [
            makeWord("clap", at: 0), makeWord("your", at: 0.4), makeWord("hands", at: 0.8),
            makeWord("stomp", at: 2), makeWord("your", at: 2.4), makeWord("feet", at: 2.8)
        ]
        let segment = BabyPlayerASRSegment(
            text: "clap your hands stomp your feet",
            startSeconds: 0,
            endSeconds: 3.2,
            words: words
        )
        let analysis = makeAnalysis(segments: [segment])
        let reference = LyricsPlainTextReference(
            id: -1001,
            title: "Action Song",
            artist: "Super Simple Songs",
            plainLyrics: "clap your hands\nstomp your feet"
        )

        let outcome = BabyPlayerLyricsSoundMatcher.match(
            analysis: analysis,
            candidates: [],
            reference: reference,
            sampleStartSeconds: 7
        )

        // 【MODIFIED】Version C requirements replaced previous behavior: 歌本生成独立但稳定的 AI Lyrics candidate。
        XCTAssertNotEqual(outcome.selected?.id, reference.id)
        XCTAssertEqual(outcome.selected?.providerName, "本地歌本·AI校准")
        XCTAssertEqual(outcome.selected?.lines.count, 2)
        XCTAssertEqual(outcome.offsetSeconds ?? 0, 7, accuracy: 0.0001)
    }

    /// 验证 AI v1 在 DeepSeek 之前就由原歌词和 ASR word timestamps 产生；输入是普通候选和词时间戳，输出是保留原文的 AI 校时候选，不修改 repository/UI。
    // 【MODIFIED】Version C requirements replaced previous behavior: 此阶段明确为 AI Lyrics v1，而不是腾讯原始字幕。
    func testNetworkTextIsRetimedIntoAILyricsV1BeforeDeepSeek() {
        let candidate = LyricsCandidate(
            id: 9,
            trackName: "Retimed",
            artistName: "Kids",
            albumName: nil,
            duration: 400,
            lines: [
                TimedLyricLine(time: 180, text: "clap your hands"),
                TimedLyricLine(time: 260, text: "stomp your feet")
            ],
            matchScore: 0,
            providerName: "LRCLIB"
        )
        let words = [
            makeWord("clap", at: 1), makeWord("your", at: 1.3), makeWord("hands", at: 1.6),
            makeWord("stomp", at: 4), makeWord("your", at: 4.3), makeWord("feet", at: 4.6)
        ]
        let segment = BabyPlayerASRSegment(
            text: "clap your hands stomp your feet",
            startSeconds: 1,
            endSeconds: 5,
            words: words
        )

        let outcome = BabyPlayerLyricsSoundMatcher.match(
            analysis: makeAnalysis(segments: [segment]),
            candidates: [candidate],
            reference: nil,
            sampleStartSeconds: 6
        )

        XCTAssertNotEqual(outcome.selected?.id, candidate.id)
        XCTAssertEqual(outcome.selected?.lines.map(\.time), [1, 4])
        XCTAssertEqual(outcome.offsetSeconds ?? 0, 6, accuracy: 0.0001)
        XCTAssertEqual(outcome.selected?.lines.map(\.text), ["clap your hands", "stomp your feet"])
        XCTAssertEqual(outcome.selected?.providerName, "AI 校时歌词")
    }

    /// 验证无法可靠逐行对齐时保留普通歌词；输入是不足以生成 AI 时间线的证据，输出不得包含腾讯 raw transcript 候选，不修改状态。
    // 【MODIFIED】Version C requirements replaced previous behavior: 废止“对齐失败即强制使用腾讯字幕”。
    func testAmbiguousASRPreservesOrdinaryLyricsInsteadOfRawTranscript() {
        let candidate = LyricsCandidate(
            id: 11,
            trackName: "Broken Timeline",
            artistName: "Kids",
            albumName: nil,
            duration: 1_000,
            lines: [TimedLyricLine(time: 999, text: "hello world again")],
            matchScore: 0,
            providerName: "LRCLIB"
        )
        let analysis = makeAnalysis(segments: [
            makeSegment("hello world again", at: 0),
            makeSegment("hello world again", at: 0.2),
            makeSegment("hello world again", at: 0.4)
        ])

        let outcome = BabyPlayerLyricsSoundMatcher.match(
            analysis: analysis,
            candidates: [candidate],
            reference: nil,
            sampleStartSeconds: 3
        )

        XCTAssertNil(outcome.selected)
        XCTAssertEqual(outcome.candidates.first?.id, candidate.id)
        XCTAssertFalse(outcome.candidates.contains { $0.providerName?.contains("腾讯 ASR") == true })
        XCTAssertNil(outcome.offsetSeconds)
    }

    /// 验证同一来源歌词只改时间戳和展示标签时 identity 不变；输入是两个同 candidate ID/文本的时间线，输出是相同 identifier，不修改状态。
    // 【MODIFIED】Version C 禁止 timestamp 参与 persistent identity。
    func testRetimingDoesNotChangePersistentIdentifier() {
        let original = LyricsCandidate(
            id: 42,
            trackName: "Action Song",
            artistName: "Kids",
            albumName: nil,
            duration: 30,
            lines: [
                TimedLyricLine(time: 0, text: "clap your hands"),
                TimedLyricLine(time: 2, text: "stomp your feet")
            ],
            matchScore: 0,
            providerName: "LRCLIB"
        )
        let retimed = LyricsCandidate(
            id: 42,
            trackName: "Action Song",
            artistName: "Kids",
            albumName: nil,
            duration: 30,
            lines: [
                TimedLyricLine(time: 7.2, text: "clap your hands"),
                TimedLyricLine(time: 9.7, text: "stomp your feet")
            ],
            matchScore: 0,
            providerName: "LRCLIB·AI校准"
        )

        XCTAssertEqual(original.persistentIdentifier, retimed.persistentIdentifier)
    }

    /// 验证旧 v1 timing key 在新 v2 候选上仍可恢复；输入是指定 legacy identifier 的已绑定 playback，输出保留人工增量，只修改测试临时 repository。
    // 【MODIFIED】Version C 对已有 v1 selection/timing 提供 candidate-ID fallback。
    func testV1TimingAdjustmentFallsBackByStableCandidateID() async throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let repository = makeRepository(storage)
        let media = makeMedia(songStart: 3)
        let candidate = makeCandidate(id: 23, title: "Legacy", words: "clap your hands")
        let legacy = LyricsPlayback(
            candidateID: candidate.id,
            trackName: candidate.trackName,
            artistName: candidate.artistName,
            sourceDuration: candidate.duration,
            lines: candidate.lines,
            autoOffsetSeconds: 3,
            manualAdjustmentSeconds: 0.7,
            isConfirmed: true,
            selectionOrigin: .manual,
            lyricIdentifier: "LRCLIB:23:legacy-v1-digest"
        )
        _ = try await repository.confirm(legacy, for: media)

        let restored = await repository.playback(for: candidate, media: media, selectionOrigin: .manual)

        XCTAssertEqual(restored.autoOffsetSeconds, 3, accuracy: 0.0001)
        XCTAssertEqual(restored.manualAdjustmentSeconds, 0.7, accuracy: 0.0001)
        XCTAssertEqual(restored.offsetSeconds, 3.7, accuracy: 0.0001)
    }

    /// 验证 AI v1 到 v2 的有限文本修复不创建新 identity；输入是同一 AI candidate ID 的两个文本版本，输出是相同 identifier，不修改状态。
    // 【MODIFIED】Version C 将 AI 校时与 AI 优化定义为同一 AI Lyrics object。
    func testAILyricsV1AndV2KeepTheSameIdentity() {
        let v1 = makeCandidate(id: -2_001, title: "AI Lyrics", words: "twinkel twinkel little star")
        let v2 = LyricsCandidate(
            id: v1.id,
            trackName: v1.trackName,
            artistName: v1.artistName,
            albumName: v1.albumName,
            duration: v1.duration,
            lines: [TimedLyricLine(time: 4.5, text: "Twinkle, twinkle, little star!")],
            matchScore: v1.matchScore,
            providerName: "AI 优化歌词"
        )
        let aiV1 = LyricsCandidate(
            id: v1.id,
            trackName: v1.trackName,
            artistName: v1.artistName,
            albumName: v1.albumName,
            duration: v1.duration,
            lines: v1.lines,
            matchScore: v1.matchScore,
            providerName: "AI 校时歌词"
        )

        XCTAssertEqual(aiV1.persistentIdentifier, v2.persistentIdentifier)
    }

    /// 验证 DeepSeek repair 只能替换文本；输入是带稳定 anchor/确定性时间线的 AI v1 和 repair，输出是同时间/同 identity 的 v2，不修改 repository/UI。
    // 【MODIFIED】Version C 禁止 DeepSeek 成为 timestamp source of truth。
    func testDeepSeekRepairChangesOnlyTextAndPreservesDeterministicTimeline() {
        let v1 = LyricsCandidate(
            id: -2_500,
            trackName: "Twinkle",
            artistName: "Kids",
            albumName: nil,
            duration: 10,
            lines: [
                TimedLyricLine(time: 1.25, text: "twinkel twinkel little star"),
                TimedLyricLine(time: 4.75, text: "how I wonder what you are")
            ],
            matchScore: 10,
            providerName: "AI 校时歌词",
            identityAnchor: "ai-source:stable-test"
        )
        let repairs = [
            BabyPlayerLyricsTextRepair(
                lineIdentifier: "line-0",
                originalText: "twinkel twinkel little star",
                suggestedText: "Twinkle, twinkle, little star",
                shouldModify: true,
                confidence: 0.94
            ),
            BabyPlayerLyricsTextRepair(
                lineIdentifier: "line-1",
                originalText: "how I wonder what you are",
                suggestedText: "invented unsupported verse",
                shouldModify: false,
                confidence: 0.2
            )
        ]

        let v2 = BabyPlayerLyricsRepairApplier.applying(
            repairs,
            to: v1,
            overallConfidence: 0.9
        )

        XCTAssertEqual(v2.lines.map(\.time), v1.lines.map(\.time))
        XCTAssertEqual(v2.lines.map(\.text), [
            "Twinkle, twinkle, little star",
            "how I wonder what you are"
        ])
        XCTAssertEqual(v2.persistentIdentifier, v1.persistentIdentifier)
        XCTAssertEqual(v2.id, v1.id)
    }

    /// 验证全局单调 alignment 会跳过孤立的重复前奏；输入是含额外首句的重复副歌，输出是连续完整副歌的时间轴，不修改状态。
    // 【MODIFIED】Version C 要求整首歌全局优化，不允许 cursor + local-window greedy。
    func testRepeatedChorusUsesGlobalMonotonicAlignment() {
        let candidate = LyricsCandidate(
            id: 77,
            trackName: "Action Song",
            artistName: "Kids",
            albumName: nil,
            duration: 30,
            lines: [
                TimedLyricLine(time: 0, text: "clap your hands"),
                TimedLyricLine(time: 2, text: "stomp your feet"),
                TimedLyricLine(time: 4, text: "clap your hands"),
                TimedLyricLine(time: 6, text: "stomp your feet")
            ],
            matchScore: 0,
            providerName: "LRCLIB"
        )
        let words = [
            makeWord("clap", at: 0), makeWord("your", at: 0.3), makeWord("hands", at: 0.6),
            makeWord("welcome", at: 1), makeWord("children", at: 1.3), makeWord("now", at: 1.6),
            makeWord("clap", at: 10), makeWord("your", at: 10.3), makeWord("hands", at: 10.6),
            makeWord("stomp", at: 12), makeWord("your", at: 12.3), makeWord("feet", at: 12.6),
            makeWord("clap", at: 14), makeWord("your", at: 14.3), makeWord("hands", at: 14.6),
            makeWord("stomp", at: 16), makeWord("your", at: 16.3), makeWord("feet", at: 16.6)
        ]
        let analysis = BabyPlayerASRAnalysis(
            status: "completed",
            cacheHit: false,
            provider: "test",
            engineType: "16k_en",
            audioDurationSeconds: 20,
            transcript: "clap your hands stomp your feet clap your hands stomp your feet",
            segments: [BabyPlayerASRSegment(
                text: "clap your hands stomp your feet clap your hands stomp your feet",
                startSeconds: 0,
                endSeconds: 17,
                words: words
            )],
            monthlyUsedSeconds: 10,
            monthlyReservedSeconds: 0,
            monthlyLimitSeconds: 18_000
        )

        let outcome = BabyPlayerLyricsSoundMatcher.match(
            analysis: analysis,
            candidates: [candidate],
            reference: nil,
            sampleStartSeconds: 0
        )

        XCTAssertEqual(outcome.selected?.lines.map(\.time), [10, 12, 14, 16])
    }

    /// 验证长歌曲只规划临时短分段；输入为片头后 320 秒歌曲，输出 6 段且单段不超过 60 秒，不创建完整音频前置条件。
    // 【MODIFIED】完整歌曲 M4A 音频库已经取消，长歌曲应直接进入短分段计划。
    func testLongSongUsesTemporarySegmentsWithoutCompleteAudioPrecondition() {
        let media = LyricsMediaDescriptor(
            id: "long-song",
            title: "Long Song",
            searchTitle: "Long Song",
            artistName: nil,
            sourceHint: nil,
            versionHint: nil,
            durationSeconds: 360,
            songStartSeconds: 10,
            songEndSeconds: 330,
            mediaSourceID: "source-long"
        )

        let segments = BabyPlayerASRSegmentPolicy.segments(for: media)

        XCTAssertEqual(segments.count, 6)
        XCTAssertEqual(segments.last?.endSeconds, 320, accuracy: 0.0001)
        XCTAssertTrue(segments.allSatisfy { $0.durationSeconds <= 60 })
        XCTAssertTrue(segments.allSatisfy(\.isTemporary))
    }

    func testQuotaPreflightRejectsBeforeUpload() {
        let usage = BabyPlayerASRUsage(
            month: "2026-08",
            usedSeconds: 17_990,
            reservedSeconds: 0,
            remainingSeconds: 10,
            limitSeconds: 18_000,
            nextResetAt: "2026-09-01T00:00:00+08:00"
        )

        XCTAssertThrowsError(try BabyPlayerASRQuotaPolicy.validate(usage, requestedSeconds: 11)) {
            guard case BabyPlayerASRError.monthlyLimit(let message) = $0 else {
                return XCTFail("Expected monthlyLimit, got \($0)")
            }
            XCTAssertTrue(message.contains("9月1日 00:00"))
        }
    }

    private func makeRepository(_ root: URL) -> BabyLyricsRepository {
        BabyLyricsRepository(
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true),
            applicationSupportDirectory: root.appendingPathComponent("Support", isDirectory: true),
            bundledCatalogData: Data(#"{"tracks":[]}"#.utf8)
        )
    }

    private func makeStorage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BabyPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMedia(songStart: Double = 0) -> LyricsMediaDescriptor {
        LyricsMediaDescriptor(
            id: "media-1",
            title: "Test Song",
            searchTitle: "Test Song",
            artistName: "Kids",
            sourceHint: nil,
            versionHint: nil,
            durationSeconds: 30,
            songStartSeconds: songStart,
            songEndSeconds: 25,
            mediaSourceID: "source-1"
        )
    }

    private func makeCandidate(id: Int, title: String, words: String) -> LyricsCandidate {
        LyricsCandidate(
            id: id,
            trackName: title,
            artistName: "Kids",
            albumName: nil,
            duration: 30,
            lines: [TimedLyricLine(time: 0, text: words)],
            matchScore: 0,
            providerName: "test"
        )
    }

    private func makeSegment(_ text: String, at start: Double) -> BabyPlayerASRSegment {
        BabyPlayerASRSegment(
            text: text,
            startSeconds: start,
            endSeconds: start + 1,
            words: []
        )
    }

    private func makeWord(_ text: String, at start: Double) -> BabyPlayerASRWord {
        BabyPlayerASRWord(text: text, startSeconds: start, endSeconds: start + 0.3)
    }

    private func makeAnalysis(segments: [BabyPlayerASRSegment]) -> BabyPlayerASRAnalysis {
        BabyPlayerASRAnalysis(
            status: "completed",
            cacheHit: false,
            provider: "test",
            engineType: "16k_en",
            audioDurationSeconds: 10,
            transcript: segments.map(\.text).joined(separator: " "),
            segments: segments,
            monthlyUsedSeconds: 10,
            monthlyReservedSeconds: 0,
            monthlyLimitSeconds: 18_000
        )
    }

    /// 建立首段决策测试证据；输入为核心相似度与置信度，输出不可变 evidence，不修改状态。
    // 【MODIFIED】测试只传业务相关维度，标题和时间证据固定为可信基线。
    private func makeSameSongEvidence(
        text: Double,
        ordered: Double,
        coverage: Double,
        confidence: Double
    ) -> BabyPlayerSameSongEvidence {
        BabyPlayerSameSongEvidence(
            normalizedTextSimilarity: text,
            orderedTokenSimilarity: ordered,
            titleSimilarity: 0.5,
            asrCoverage: coverage,
            temporalOrder: 1,
            sameSongConfidence: confidence
        )
    }
}

/// 记录测试 operation 执行次数；输入为 increment 调用，输出当前次数，只修改测试 actor 内存。
// 【MODIFIED】用于证明同 fingerprint registry 只启动一份真实工作。
private actor ASRInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
