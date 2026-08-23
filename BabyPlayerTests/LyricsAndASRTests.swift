import XCTest
@testable import BabyPlayer

final class LyricsAndASRTests: XCTestCase {
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

    func testNetworkTextIsRetimedFromASRAndIgnoresUntrustedLRCTimes() {
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
        XCTAssertTrue(outcome.selected?.providerName?.contains("声音重校时") == true)
    }

    func testProductionMatcherNeverFallsBackToUntrustedOnlineTimeline() {
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

        XCTAssertNotEqual(outcome.selected?.id, candidate.id)
        XCTAssertEqual(outcome.selected?.providerName, "腾讯 ASR·声音时间轴")
        XCTAssertEqual(outcome.offsetSeconds ?? 0, 3, accuracy: 0.0001)
    }

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
}
