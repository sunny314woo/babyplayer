//
// LyricsAndASRTests.swift
// BabyPlayer 歌词绑定、ASR 本地匹配、累计校时、纯文本歌本和额度策略回归测试。
// 主要功能：验证默认/人工优先级、持久化、单调时间对齐、稳定 identity、歌本和额度预检。
// 最近修改：2026-08-23 【MODIFIED】增加不明确保持当前歌词、重复副歌和稳定 identity 测试。
//

import XCTest
@testable import BabyPlayer

final class LyricsAndASRTests: XCTestCase {
    /// 默认首次绑定必须稳定选择第 1 份，并在重新创建 Repository 后仍存在。
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
        let reloaded = makeRepository(storage)
        let stored = await reloaded.storedLyrics(for: media)
        XCTAssertEqual(stored?.candidateID, first.id)
    }

    /// 人工选择第二/第三份后，Repository 层必须拒绝任何后续 ASR 自动覆盖。
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

    /// 多次提前/延后必须累计；不同歌词拥有独立调整，并且重启后恢复。
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
        XCTAssertEqual(firstRestored.manualAdjustmentSeconds, 0.4, accuracy: 0.0001)
        XCTAssertEqual(firstRestored.offsetSeconds, 3.4, accuracy: 0.0001)
        XCTAssertEqual(secondRestored?.candidateID, second.id)
        XCTAssertEqual(secondRestored?.offsetSeconds ?? 0, 2.5, accuracy: 0.0001)
        XCTAssertEqual(firstAfterReload.offsetSeconds, 3.4, accuracy: 0.0001)
    }

    /// 明显领先且句级数据足够时，可用确定性算法估计整体偏移。
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

    /// 纯文本歌本可利用腾讯单词时间戳生成临时时间轴。
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

        XCTAssertEqual(outcome.selected?.id, reference.id)
        XCTAssertEqual(outcome.selected?.providerName, "本地歌本·自动校时")
        XCTAssertEqual(outcome.selected?.lines.count, 2)
        XCTAssertEqual(outcome.offsetSeconds ?? 0, 7, accuracy: 0.0001)
    }

    /// 【MODIFIED】真实 Bundle 相同的数据格式能按 SSS 文件名线索找到纯文本歌本。
    func testBundledSuperSimpleSongbookParticipatesInMatching() async throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let catalog = Data(#"{"tracks":[{"id":-1001,"trackID":"sss-twinkle","title":"Twinkle Twinkle Little Star","aliases":["Twinkle Twinkle"],"artist":"Super Simple Songs","source":"Super Simple Songs","plainLyrics":"twinkle twinkle little star\nhow I wonder what you are"}]}"#.utf8)
        let repository = BabyLyricsRepository(
            cachesDirectory: storage.appendingPathComponent("Caches", isDirectory: true),
            applicationSupportDirectory: storage.appendingPathComponent("Support", isDirectory: true),
            bundledCatalogData: catalog
        )
        let media = LyricsMediaDescriptor(
            id: "sss-media",
            title: "01 Twinkle Twinkle Little Star [SSS].mp4",
            searchTitle: "Twinkle Twinkle Little Star",
            artistName: nil,
            sourceHint: "Super Simple Songs",
            versionHint: nil,
            durationSeconds: 40,
            songStartSeconds: 0,
            songEndSeconds: 40,
            mediaSourceID: "sss-source"
        )

        let reference = await repository.plainTextReference(for: media)

        XCTAssertEqual(reference?.id, -1001)
        XCTAssertEqual(reference?.artist, "Super Simple Songs")
        XCTAssertTrue(reference?.plainLyrics.contains("twinkle twinkle") == true)
    }

    /// 网络 LRC 时间戳不可信时，文本可被腾讯单词时间戳重新校时。
    func testNetworkTextIsRetimedFromASRAndKeepsStableIdentity() {
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

        XCTAssertEqual(outcome.selected?.id, candidate.id)
        XCTAssertEqual(outcome.selected?.lines.map(\.time), [1, 4])
        XCTAssertEqual(outcome.offsetSeconds ?? 0, 6, accuracy: 0.0001)
        XCTAssertEqual(outcome.selected?.persistentIdentifier, candidate.persistentIdentifier)
    }

    /// 【MODIFIED】候选接近时绝不能自动换成 ASR 原始字幕或任一候选；应保持当前默认第一份。
    func testAmbiguousMatcherDoesNotAutoSelectAnything() {
        let first = makeCandidate(id: 11, title: "First", words: "hello world again")
        let second = makeCandidate(id: 12, title: "Second", words: "hello world again")
        let analysis = makeAnalysis(segments: [
            makeSegment("hello world again", at: 0),
            makeSegment("hello world again", at: 0.2),
            makeSegment("hello world again", at: 0.4)
        ])

        let outcome = BabyPlayerLyricsSoundMatcher.match(
            analysis: analysis,
            candidates: [first, second],
            reference: nil,
            sampleStartSeconds: 3
        )

        XCTAssertNil(outcome.selected)
        XCTAssertNil(outcome.offsetSeconds)
        XCTAssertTrue(outcome.message.contains("已保留当前歌词"))
    }

    /// 【MODIFIED】重复歌词必须沿 ASR 时间单调向后匹配，不能把第二次副歌吸回第一次出现的位置。
    func testRepeatedChorusUsesMonotonicGlobalAlignment() {
        let candidate = LyricsCandidate(
            id: 21,
            trackName: "Repeated Chorus",
            artistName: "Kids",
            albumName: nil,
            duration: 100,
            lines: [
                TimedLyricLine(time: 50, text: "clap your hands"),
                TimedLyricLine(time: 51, text: "stomp your feet"),
                TimedLyricLine(time: 52, text: "clap your hands"),
                TimedLyricLine(time: 53, text: "stomp your feet")
            ],
            matchScore: 0,
            providerName: "LRCLIB"
        )
        let words = [
            makeWord("clap", at: 0), makeWord("your", at: 0.2), makeWord("hands", at: 0.4),
            makeWord("stomp", at: 2), makeWord("your", at: 2.2), makeWord("feet", at: 2.4),
            makeWord("clap", at: 4), makeWord("your", at: 4.2), makeWord("hands", at: 4.4),
            makeWord("stomp", at: 6), makeWord("your", at: 6.2), makeWord("feet", at: 6.4)
        ]
        let segment = BabyPlayerASRSegment(
            text: "clap your hands stomp your feet clap your hands stomp your feet",
            startSeconds: 0,
            endSeconds: 7,
            words: words
        )

        let outcome = BabyPlayerLyricsSoundMatcher.match(
            analysis: makeAnalysis(segments: [segment]),
            candidates: [candidate],
            reference: nil,
            sampleStartSeconds: 0
        )

        XCTAssertEqual(outcome.selected?.lines.map(\.time), [0, 2, 4, 6])
    }

    /// 完整本地歌曲缓存不应被 120 秒 ASR 识别窗口截断。
    func testCompleteAudioIsKeptWhileRecognitionWindowRemainsBounded() {
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

        XCTAssertEqual(BabyPlayerAudioCache.completeSongDuration(for: media), 320, accuracy: 0.0001)
        XCTAssertEqual(BabyPlayerAudioCache.recognitionDuration(for: media), 120, accuracy: 0.0001)
    }

    /// 客户端额度预检必须在上传前拒绝超出剩余额度的识别请求。
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

    /// 创建隔离 Repository；输入临时根目录，输出不会影响真实 App 数据的测试实例。
    private func makeRepository(_ root: URL) -> BabyLyricsRepository {
        BabyLyricsRepository(
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true),
            applicationSupportDirectory: root.appendingPathComponent("Support", isDirectory: true),
            bundledCatalogData: Data(#"{"tracks":[]}"#.utf8)
        )
    }

    /// 创建单测临时目录；副作用仅限系统临时目录。
    private func makeStorage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BabyPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 创建标准媒体描述，便于绑定/偏移测试复用。
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

    /// 创建单行测试歌词候选；无外部副作用。
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

    /// 创建不带 word 细节的句级 ASR 段。
    private func makeSegment(_ text: String, at start: Double) -> BabyPlayerASRSegment {
        BabyPlayerASRSegment(
            text: text,
            startSeconds: start,
            endSeconds: start + 1,
            words: []
        )
    }

    /// 创建单词级 ASR 时间戳。
    private func makeWord(_ text: String, at start: Double) -> BabyPlayerASRWord {
        BabyPlayerASRWord(text: text, startSeconds: start, endSeconds: start + 0.3)
    }

    /// 创建完整 ASR 分析测试对象；不会调用真实腾讯服务。
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
}
