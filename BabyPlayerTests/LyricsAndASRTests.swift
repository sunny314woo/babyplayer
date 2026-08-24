//
// LyricsAndASRTests.swift
// BabyPlayer 歌词、ASR、AI 校时、持久化与额度策略的回归测试。
// 当前主要功能：保护普通歌词默认绑定、AI Lyrics 渐进结果、人工优先、稳定 identity 和全局单调对齐。
// 最近修改：2026-08-23 为 Version C — AI Lyrics Repair 建立冻结行为测试。
// 最近修改：2026-08-23 验证 AI 进度卡会展示完整的 ASR、时间轴和字幕内容里程碑。
// 最近修改：2026-08-23 覆盖单曲循环退避与片头边界不得导致音频导出作废。
// 最近修改：2026-08-23 冻结 ASR 临时分段、全局时间戳合并、首段早停与同 fingerprint 任务复用行为。
// 最近修改：2026-08-24 覆盖 Apple TV 遥控器中间键的播放/暂停决策。
// 最近修改：2026-08-24 覆盖 Apple TV 只提交 Mac 本机路径、不上传音频的任务合同。
//

import Foundation
import XCTest
@testable import BabyPlayer

final class LyricsAndASRTests: XCTestCase {
    /// 播放器倍速菜单包含用于快速检查字幕的 3×，默认仍为正常 1×。
    func testPlaybackRateMenuUsesRequestedRatesIncludingThreeTimes() {
        XCTAssertEqual(BabyPlayerPlaybackRatePolicy.availableRates, [0.8, 1, 1.5, 2, 3])
        XCTAssertEqual(BabyPlayerPlaybackRatePolicy.defaultRate, 1)
        XCTAssertEqual(BabyPlayerPlaybackRatePolicy.normalized(0.82), 0.8)
        XCTAssertEqual(BabyPlayerPlaybackRatePolicy.normalized(1.8), 2)
        XCTAssertEqual(BabyPlayerPlaybackRatePolicy.title(for: 1.5), "1.5×")
        XCTAssertEqual(BabyPlayerPlaybackRatePolicy.title(for: 3), "3×")
    }

    /// 验证中间键对播放、缓冲和暂停状态的决策；不启动真实播放器。
    // 【MODIFIED】缓冲中仍视为“正在尝试播放”，再按中间键必须暂停。
    func testCenterPressTogglesPlaybackAndPause() {
        XCTAssertEqual(
            BabyPlayerPlaybackTogglePolicy.action(timeControlStatus: .playing, rate: 1),
            .pause
        )
        XCTAssertEqual(
            BabyPlayerPlaybackTogglePolicy.action(
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                rate: 0
            ),
            .pause
        )
        XCTAssertEqual(
            BabyPlayerPlaybackTogglePolicy.action(timeControlStatus: .paused, rate: 0),
            .play
        )
    }

    /// 【MODIFIED】ASR 已返回后的文件错误必须明确显示为保存失败，避免误判腾讯识别失败。
    func testASRPostProcessingErrorIdentifiesPersistenceFailure() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 513)

        XCTAssertEqual(
            BabyPlayerAnalysisErrorPresentation.message(error, fallback: "ASR 处理失败"),
            "ASR 已完成，但结果保存失败（513）"
        )
    }

    /// 腾讯长 segment 必须按词级时间拆成电视可读短行，不能把一分钟文字铺满屏幕。
    func testRawASRCandidateSplitsLongTencentSegmentForTVReadability() throws {
        let words = (0..<25).map {
            makeWord("word\($0)", at: Double($0) * 0.35)
        }
        let analysis = makeAnalysis(segments: [BabyPlayerASRSegment(
            text: words.map(\.text).joined(separator: " "),
            startSeconds: 0,
            endSeconds: 9,
            words: words
        )])

        let candidate = try analysis.lyricsCandidate(
            title: "Long ASR",
            mediaFingerprint: "test-fingerprint"
        )

        XCTAssertGreaterThan(candidate.lines.count, 3)
        XCTAssertTrue(candidate.lines.allSatisfy { $0.text.split(separator: " ").count <= 6 })
        XCTAssertTrue(candidate.lines.allSatisfy { $0.text.count <= 30 })
        XCTAssertTrue(candidate.lines.allSatisfy {
            ($0.endTime ?? $0.time) - $0.time <= 3.2 + 0.0001
        })
        XCTAssertEqual(candidate.lines.first?.time ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(candidate.lines.last?.endTime ?? -1, 8.7, accuracy: 0.0001)
    }

    /// 腾讯缺少 word timeline 时也不得把整分钟 segment 当成一条字幕。
    func testRawASRFallbackDistributesUntimedSegmentIntoMovingShortLines() throws {
        let text = (0..<18).map { "word\($0)" }.joined(separator: " ")
        let analysis = makeAnalysis(segments: [BabyPlayerASRSegment(
            text: text,
            startSeconds: 0,
            endSeconds: 18,
            words: []
        )])

        let candidate = try analysis.lyricsCandidate(
            title: "Untimed ASR",
            mediaFingerprint: "untimed-test-fingerprint"
        )

        XCTAssertGreaterThan(candidate.lines.count, 1)
        XCTAssertTrue(candidate.lines.allSatisfy { $0.text.split(separator: " ").count <= 6 })
        XCTAssertTrue(candidate.lines.allSatisfy { $0.text.count <= 30 })
        XCTAssertTrue(candidate.lines.allSatisfy {
            ($0.endTime ?? $0.time) - $0.time <= 3.2 + 0.0001
        })
        XCTAssertEqual(candidate.lines.first?.time ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(candidate.lines.last?.endTime ?? -1, 18, accuracy: 0.0001)
    }

    /// 同一原视频改用完整分片时间线后，旧 DeepSeek 映射必须被判定为过期。
    func testASREvidenceHashIncludesWordTimelineForSameSourceVideo() {
        let first = makeAnalysis(
            segments: [BabyPlayerASRSegment(
                text: "round and round",
                startSeconds: 1,
                endSeconds: 2,
                words: [makeWord("round", at: 1), makeWord("round", at: 1.6)]
            )],
            audioContentHash: "same-audio",
            mediaContentHash: "same-video"
        )
        let extended = makeAnalysis(
            segments: [BabyPlayerASRSegment(
                text: "round and round again",
                startSeconds: 1,
                endSeconds: 3,
                words: [
                    makeWord("round", at: 1),
                    makeWord("round", at: 1.6),
                    makeWord("again", at: 2.4)
                ]
            )],
            audioContentHash: "same-audio",
            mediaContentHash: "same-video"
        )

        XCTAssertNotEqual(first.evidenceHash, extended.evidenceHash)
    }

    /// 【MODIFIED】在物理 Apple TV 的真实 App 容器写入探针，冻结 tvOS 可写目录边界。
    func testDurableLyricsDirectoryIsInsideWritableAppContainer() throws {
        let fileManager = FileManager.default
        let root = BabyPlayerLyricsStoragePolicy.writableStorageBase(
            fileManager: fileManager
        ).appendingPathComponent("BabyPlayerLyrics", isDirectory: true)
        let probe = root.appendingPathComponent(
            "BabyPlayer-Write-Probe-" + UUID().uuidString
        )

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(
            atPath: probe.path,
            contents: Data("probe".utf8)
        ))

        XCTAssertTrue(fileManager.fileExists(atPath: probe.path))
        XCTAssertTrue(root.path.contains("/Library/Caches/BabyPlayerLyrics"))
    }

    /// 验证 MVP 对 2–3 分钟媒体只生成一个整首窗口；输入为 170 秒视频及片头片尾，输出 160 秒连续范围，不执行分片。
    // 【MODIFIED】当前生产验收以临时整首 M4A 为准，60 秒分片留待以后。
    func testMVPUsesOneTemporaryWholeSongWindow() {
        let media = LyricsMediaDescriptor(
            id: "mvp-whole-song",
            title: "Whole Song",
            searchTitle: "Whole Song",
            artistName: nil,
            sourceHint: nil,
            versionHint: nil,
            durationSeconds: 170,
            songStartSeconds: 5,
            songEndSeconds: 165,
            mediaSourceID: "source-whole-song"
        )

        let window = BabyPlayerTemporaryASRAudioPolicy.songWindow(for: media)

        XCTAssertEqual(window?.startSeconds ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(window?.durationSeconds ?? -1, 160, accuracy: 0.0001)
    }

    /// 验证客户端已能把临时 M4A POST 到 `/v1/analyze` 并解码 transcript/timestamps；输入为本地假文件和 mock URLProtocol，不访问真实网络。
    // 【MODIFIED】这是 Tencent 真实验收前的最后一个无外部副作用 contract test。
    func testMVPAnalyzePostsTemporaryAudioAndDecodesTranscriptTimestamps() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BabyPlayer-ASR-Mock-\(UUID().uuidString).m4a")
        try Data("mock-m4a-audio".utf8).write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let capture = BabyPlayerMockRequestCapture()
        BabyPlayerMockURLProtocol.setHandler { request in
            let body = request.httpMethod == "POST"
                ? try requestBodyData(request)
                : Data()
            capture.record(request, body: body)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(#"{"status":"completed","cache_hit":false,"provider":"mock","engine_type":"16k_en","audio_duration_seconds":160,"transcript":"twinkle little star","segments":[{"text":"twinkle little star","start_seconds":1.2,"end_seconds":3.4,"words":[{"text":"twinkle","start_seconds":1.2,"end_seconds":1.8}]}],"monthly_used_seconds":160,"monthly_reserved_seconds":0,"monthly_limit_seconds":18000}"#.utf8)
            return (response, payload)
        }
        defer { BabyPlayerMockURLProtocol.setHandler(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BabyPlayerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let client = BabyPlayerASRClient(
            baseURL: URL(string: "https://babyplayer.mock/v1")!,
            apiToken: "mock-token",
            session: session
        )

        let analysis = try await client.analyze(
            sampleURL: temporaryURL,
            durationSeconds: 160,
            mediaFingerprint: "mock-media-fingerprint",
            mediaTitle: "Mock Song",
            forceRefresh: true
        )

        XCTAssertEqual(capture.method, "POST")
        XCTAssertEqual(capture.path, "/v1/analyze")
        XCTAssertEqual(capture.authorization, "Bearer mock-token")
        XCTAssertTrue(capture.bodyText.contains("name=\"force_refresh\"\r\n\r\ntrue"))
        XCTAssertTrue(capture.bodyText.contains("name=\"media_title\"\r\n\r\nMock Song"))
        XCTAssertEqual(analysis.transcript, "twinkle little star")
        XCTAssertEqual(analysis.segments.first?.words.first?.startSeconds, 1.2)
    }

    /// 验证本地开发链路只提交路径 JSON 并轮询小结果；不会构造 multipart 或上传音频。
    // 【MODIFIED】Mac 负责读取原视频、提取音频和等待腾讯 ASR。
    func testMacLocalAnalysisSubmitsPathAndPollsResultWithoutAudioUpload() async throws {
        let capture = BabyPlayerMockRequestCapture()
        BabyPlayerMockURLProtocol.setHandler { request in
            let body = request.httpMethod == "POST"
                ? try requestBodyData(request)
                : Data()
            capture.record(request, body: body)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.httpMethod == "POST" {
                return (response, Data(#"{"job_id":"local-job-1","status":"queued","message":"任务已提交到 Mac"}"#.utf8))
            }
            let payload = Data(#"{"job_id":"local-job-1","status":"completed","message":"识别完成","analysis":{"status":"completed","cache_hit":false,"provider":"mock","engine_type":"16k_en","audio_duration_seconds":155,"transcript":"rain rain go away","segments":[{"text":"rain rain go away","start_seconds":0.2,"end_seconds":2.1,"words":[]}],"monthly_used_seconds":155,"monthly_reserved_seconds":0,"monthly_limit_seconds":18000,"audio_sha256":"audio-content-hash","media_content_sha256":"video-content-hash"}}"#.utf8)
            return (response, payload)
        }
        defer { BabyPlayerMockURLProtocol.setHandler(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BabyPlayerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let client = BabyPlayerASRClient(
            baseURL: URL(string: "http://192.168.3.33:8011/v1")!,
            apiToken: "mock-token",
            session: session
        )
        let media = LyricsMediaDescriptor(
            id: "rain",
            title: "Rain Rain Go Away",
            searchTitle: "Rain Rain Go Away",
            artistName: nil,
            sourceHint: nil,
            versionHint: nil,
            durationSeconds: 155,
            songStartSeconds: 0,
            songEndSeconds: 155,
            mediaSourceID: "rain-source"
        )

        let submitted = try await client.submitLocalAnalysis(
            mediaPath: "/Users/test/Music/Rain Rain Go Away.mp4",
            media: media,
            mediaFingerprint: "rain-local-fingerprint",
            mediaTitle: "Rain Rain Go Away",
            forceRefresh: true
        )
        let completed = try await client.localAnalysisJob(id: submitted.jobID)

        XCTAssertEqual(capture.methods, ["POST", "GET"])
        XCTAssertEqual(capture.paths, [
            "/v1/local-analysis/jobs",
            "/v1/local-analysis/jobs/local-job-1"
        ])
        let body = try XCTUnwrap(capture.bodyTexts.first)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["media_path"] as? String, "/Users/test/Music/Rain Rain Go Away.mp4")
        XCTAssertNil(json["audio"])
        XCTAssertFalse(body.contains("multipart/form-data"))
        XCTAssertEqual(completed.analysis?.transcript, "rain rain go away")
        XCTAssertEqual(completed.analysis?.audioContentHash, "audio-content-hash")
        XCTAssertEqual(completed.analysis?.mediaContentHash, "video-content-hash")
        XCTAssertFalse(completed.analysis?.evidenceHash.isEmpty ?? true)
        XCTAssertNotEqual(completed.analysis?.evidenceHash, "video-content-hash")
    }

    /// 验证 ASR 计划只包含临时短分段；输入为 320 秒歌曲，输出为多个不超过集中时长的 segment，不修改状态。
    // 【MODIFIED】Tencent ASR 不得再等待完整歌曲 M4A 建立完成。
    func testASRPlanningUsesTemporarySegmentsInsteadOfCompleteM4A() {
        let segments = BabyPlayerASRSegmentPolicy.segments(forSongDuration: 320)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.durationSeconds <= BabyPlayerASRSegmentPolicy.durationSeconds })
        XCTAssertTrue(segments.allSatisfy(\.isTemporary))
        XCTAssertEqual(segments.first?.startSeconds, 0)
    }

    // 【MODIFIED】Debug 只开放回环与 RFC1918/.local HTTP，公网明文地址必须拒绝。
    func testDebugLocalServiceURLPolicyRejectsPublicPlainHTTP() {
        XCTAssertTrue(BabyPlayerServiceConfiguration.isAllowed(
            URL(string: "http://192.168.3.33:8011/v1")!
        ))
        XCTAssertTrue(BabyPlayerServiceConfiguration.isAllowed(
            URL(string: "http://babyplayer.local:8011/v1")!
        ))
        XCTAssertFalse(BabyPlayerServiceConfiguration.isAllowed(
            URL(string: "http://203.0.113.10:8011/v1")!
        ))
        XCTAssertTrue(BabyPlayerServiceConfiguration.isAllowed(
            URL(string: "https://player.example.test/v1")!
        ))
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

        XCTAssertTrue(text.contains("语音识别已经完成"))
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

    // 【MODIFIED】普通候选可默认显示，但未经家长固定不得永久绑定。
    func testFirstCandidateIsTemporaryUntilExplicitlyPinned() async throws {
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
        XCTAssertNil(stored)
    }

    // 【MODIFIED】分析结果必须持久保留，但保存本身不得替换当前默认歌词。
    func testStoredAnalysisResultSurvivesReloadWithoutChangingPinnedLyrics() async throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let repository = makeRepository(storage)
        let media = makeMedia()
        let ordinary = makeCandidate(id: 1, title: "Ordinary", words: "one two three four")
        let analyzed = makeCandidate(id: -10, title: "ASR", words: "five six seven eight")
        let pinned = await repository.playback(for: ordinary, media: media, selectionOrigin: .manual)
        _ = try await repository.confirm(pinned, for: media)

        _ = try await repository.storeASRResult(
            analyzed,
            asrEvidenceHash: "audio-hash-1",
            for: media
        )

        let reloaded = makeRepository(storage)
        let bundle = await reloaded.analysisBundle(for: media)
        let stillPinned = await reloaded.storedLyrics(for: media)
        XCTAssertEqual(bundle?.asrResult?.candidate.id, analyzed.id)
        XCTAssertEqual(bundle?.asrResult?.asrEvidenceHash, "audio-hash-1")
        XCTAssertEqual(bundle?.pinnedOrdinaryPlayback?.candidateID, ordinary.id)
        XCTAssertEqual(stillPinned?.candidateID, ordinary.id)
        XCTAssertEqual(stillPinned?.selectionOrigin, .manual)

        let adopted = await reloaded.playback(for: analyzed, media: media, selectionOrigin: .asr)
        _ = try await reloaded.confirm(adopted, for: media)
        let afterAdoption = await reloaded.analysisBundle(for: media)
        let preferred = await reloaded.storedLyrics(for: media)
        XCTAssertEqual(afterAdoption?.pinnedOrdinaryPlayback?.candidateID, ordinary.id)
        XCTAssertEqual(preferred?.candidateID, analyzed.id)
        XCTAssertEqual(preferred?.selectionOrigin, .asr)
    }

    /// ASR 和 DeepSeek 并列保留，用户可在两份字幕之间分别采用。
    func testASRAndDeepSeekResultsCanBeAdoptedIndependently() async throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let repository = makeRepository(storage)
        let media = makeMedia()
        let asr = makeCandidate(id: -10, title: "ASR", words: "raw transcript line")
        let deepSeek = makeCandidate(id: -11, title: "DeepSeek", words: "calibrated lyric line")
        _ = try await repository.storeASRResult(asr, asrEvidenceHash: "same-evidence", for: media)
        let bundle = try await repository.storeDeepSeekResult(
            deepSeek,
            asrEvidenceHash: "same-evidence",
            for: media
        )

        XCTAssertEqual(bundle.result(for: .asr)?.candidate.id, asr.id)
        XCTAssertEqual(bundle.result(for: .deepSeek)?.candidate.id, deepSeek.id)

        let asrPlayback = await repository.playback(for: asr, media: media, selectionOrigin: .asr)
        _ = try await repository.confirm(asrPlayback, for: media)
        let adoptedASR = await repository.storedLyrics(for: media)
        XCTAssertEqual(adoptedASR?.candidateID, asr.id)

        let deepSeekPlayback = await repository.playback(
            for: deepSeek,
            media: media,
            selectionOrigin: .asr
        )
        _ = try await repository.confirm(deepSeekPlayback, for: media)
        let adoptedDeepSeek = await repository.storedLyrics(for: media)
        XCTAssertEqual(adoptedDeepSeek?.candidateID, deepSeek.id)
        let reloaded = makeRepository(storage)
        let reloadedBundle = await reloaded.analysisBundle(for: media)
        XCTAssertNotNil(reloadedBundle?.asrResult)
        XCTAssertNotNil(reloadedBundle?.deepSeekResult)
    }

    // 【MODIFIED】重新 ASR 产生不同证据时，基于旧证据的 DeepSeek 结果不得继续可采用。
    func testNewASREvidenceInvalidatesStoredDeepSeekResult() async throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let repository = makeRepository(storage)
        let media = makeMedia()
        let asr = makeCandidate(id: -10, title: "ASR", words: "one two three four")
        let deepSeek = makeCandidate(id: -11, title: "AI", words: "one two three four")
        _ = try await repository.storeASRResult(asr, asrEvidenceHash: "hash-1", for: media)
        _ = try await repository.storeDeepSeekResult(
            deepSeek,
            asrEvidenceHash: "hash-1",
            for: media
        )

        let updated = try await repository.storeASRResult(
            asr,
            asrEvidenceHash: "hash-2",
            for: media
        )

        XCTAssertNotNil(updated.asrResult)
        XCTAssertNil(updated.deepSeekResult)
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
            monthlyLimitSeconds: 18_000,
            audioContentHash: nil,
            mediaContentHash: nil
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
        let endTimes = outcome.selected?.lines.compactMap(\.endTime) ?? []
        XCTAssertEqual(endTimes.count, 3)
        for (actual, expected) in zip(endTimes, [2.2, 4.3, 6.3]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
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
                TimedLyricLine(
                    time: 1.25,
                    text: "twinkel twinkel little star",
                    endTime: 3.9
                ),
                TimedLyricLine(
                    time: 4.75,
                    text: "how I wonder what you are",
                    endTime: 7.2
                )
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
        XCTAssertEqual(v2.lines.map(\.endTime), v1.lines.map(\.endTime))
        XCTAssertEqual(v2.lines.map(\.text), [
            "Twinkle, twinkle, little star",
            "how I wonder what you are"
        ])
        XCTAssertEqual(v2.persistentIdentifier, v1.persistentIdentifier)
        XCTAssertEqual(v2.id, v1.id)
    }

    func testASRTimelineHidesSubtitleDuringInstrumentalGap() {
        let lines = [
            TimedLyricLine(time: 2, text: "first line", endTime: 4),
            TimedLyricLine(time: 8, text: "second line", endTime: 10)
        ]

        XCTAssertEqual(BabyPlayerLyricTimeline.visibleLineIndex(at: 3, lines: lines), 0)
        XCTAssertNil(BabyPlayerLyricTimeline.visibleLineIndex(at: 6, lines: lines))
        XCTAssertEqual(BabyPlayerLyricTimeline.visibleLineIndex(at: 9, lines: lines), 1)
        XCTAssertNil(BabyPlayerLyricTimeline.visibleLineIndex(at: 11, lines: lines))
    }

    func testDeepSeekWordMappingUsesASRTimesAndOmitsUnsupportedLine() {
        let v1 = LyricsCandidate(
            id: -2_600,
            trackName: "Mapped",
            artistName: "Kids",
            albumName: nil,
            duration: 20,
            lines: [
                TimedLyricLine(time: 0, text: "first line", endTime: 1),
                TimedLyricLine(time: 2, text: "instrumental subtitle", endTime: 3),
                TimedLyricLine(time: 4, text: "last line", endTime: 5)
            ],
            matchScore: 0,
            providerName: "AI 校时歌词",
            identityAnchor: "ai-source:mapped-test"
        )
        let repairs = [
            BabyPlayerLyricsTextRepair(
                lineIdentifier: "line-0",
                originalText: "first line",
                suggestedText: "First line",
                shouldModify: true,
                confidence: 0.9,
                shouldDisplay: true,
                startSeconds: 8,
                endSeconds: 9.5
            ),
            BabyPlayerLyricsTextRepair(
                lineIdentifier: "line-1",
                originalText: "instrumental subtitle",
                suggestedText: "instrumental subtitle",
                shouldModify: false,
                confidence: 0.7,
                shouldDisplay: false
            ),
            BabyPlayerLyricsTextRepair(
                lineIdentifier: "line-2",
                originalText: "last line",
                suggestedText: "last line",
                shouldModify: false,
                confidence: 0.9,
                shouldDisplay: true,
                startSeconds: 14,
                endSeconds: 15.5
            )
        ]

        let mapped = BabyPlayerLyricsRepairApplier.applying(
            repairs,
            to: v1,
            overallConfidence: 0.9
        )

        XCTAssertEqual(mapped.lines.map(\.text), ["First line", "last line"])
        XCTAssertEqual(mapped.lines.map(\.time), [8, 14])
        XCTAssertEqual(mapped.lines.compactMap(\.endTime), [9.5, 15.5])
    }

    /// 验证异常宽的末行时间窗口不会突破服务端每行 100 个 ASR words 的合同。
    func testLyricsRefinerCapsAlignedWordsPerLine() {
        let words = (0..<187).map {
            makeWord("word\($0)", at: Double($0) * 0.1)
        }

        let bounded = BabyPlayerLyricsRefinerEvidencePolicy.boundedWords(words)

        XCTAssertEqual(bounded.count, 100)
        XCTAssertEqual(bounded.first?.text, "word0")
        XCTAssertEqual(bounded.last?.text, "word99")
    }

    /// 验证 D3 客户端只上传标题/候选，并接受由 VPS 从 ASR word range 换算的时间轴。
    func testD3ReconcilerPostsCandidatesAndDecodesServerTimedLyrics() async throws {
        let capture = BabyPlayerMockRequestCapture()
        BabyPlayerMockURLProtocol.setHandler { request in
            capture.record(request)
            let body = try requestBodyData(request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["song_title"] as? String, "Twinkle Twinkle")
            XCTAssertNil(json["transcript"])
            XCTAssertNil(json["asr_words"])
            XCTAssertEqual((json["candidates"] as? [[String: Any]])?.count, 1)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(#"{"status":"completed","cache_hit":false,"model":"deepseek-v4-flash","reconciliation_version":"babyplayer-lyrics-d3-v1","song_match_confidence":0.94,"primary_source":"candidate_1","web_search_used":false,"lines":[{"text":"Twinkle, twinkle, little star","asr_word_start_index":0,"asr_word_end_index":3,"start_seconds":0.4,"end_seconds":2.0,"source":"candidate_1","source_line_ids":["candidate_1:line_0"],"confidence":0.96,"text_corrected":true},{"text":"How I wonder what you are","asr_word_start_index":4,"asr_word_end_index":9,"start_seconds":2.2,"end_seconds":4.1,"source":"candidate_1","source_line_ids":["candidate_1:line_1"],"confidence":0.95,"text_corrected":false}],"discarded_lines":[]}"#.utf8)
            return (response, payload)
        }
        defer { BabyPlayerMockURLProtocol.setHandler(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BabyPlayerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let input = LyricsCandidate(
            id: 42,
            trackName: "Twinkle Twinkle",
            artistName: "Kids",
            albumName: nil,
            duration: 10,
            lines: [
                TimedLyricLine(time: 20, text: "Twinkle twinkle little star"),
                TimedLyricLine(time: 2, text: "How I wonder what you are")
            ],
            matchScore: 0,
            providerName: "LRCLIB"
        )

        let result = try await BabyPlayerLyricsReconcilerClient(session: session).reconcile(
            songTitle: "Twinkle Twinkle",
            mediaFingerprint: "test-media-fingerprint",
            candidates: [input]
        )

        XCTAssertEqual(capture.path, "/v1/lyrics/reconcile")
        XCTAssertEqual(result.candidate.lines.map(\.time), [0.4, 2.2])
        XCTAssertEqual(result.candidate.lines.compactMap(\.endTime), [2.0, 4.1])
        XCTAssertEqual(result.candidate.lines.map(\.text), [
            "Twinkle, twinkle, little star",
            "How I wonder what you are"
        ])
        XCTAssertEqual(result.confidence, 0.94)
        XCTAssertFalse(result.webSearchUsed)
    }

    /// 没有下载歌词时仍会发送歌曲名和空候选列表，由 Mac 用已缓存 ASR 整理时间线。
    func testD3ReconcilerAllowsASROnlyRequestWithoutDownloadedLyrics() async throws {
        BabyPlayerMockURLProtocol.setHandler { request in
            let body = try requestBodyData(request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["song_title"] as? String, "Baby Shark")
            XCTAssertEqual((json["candidates"] as? [[String: Any]])?.count, 0)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(#"{"status":"completed","cache_hit":false,"model":"deepseek-v4-flash","reconciliation_version":"babyplayer-lyrics-d3-v1","song_match_confidence":0.86,"primary_source":"asr_only","web_search_used":false,"lines":[{"text":"Baby shark doo doo doo doo doo doo","asr_word_start_index":0,"asr_word_end_index":7,"start_seconds":1.0,"end_seconds":3.4,"source":"asr_only","source_line_ids":[],"confidence":0.9,"text_corrected":false},{"text":"Baby shark","asr_word_start_index":8,"asr_word_end_index":9,"start_seconds":3.5,"end_seconds":4.1,"source":"asr_only","source_line_ids":[],"confidence":0.88,"text_corrected":false}],"discarded_lines":[]}"#.utf8)
            return (response, payload)
        }
        defer { BabyPlayerMockURLProtocol.setHandler(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BabyPlayerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let result = try await BabyPlayerLyricsReconcilerClient(session: session).reconcile(
            songTitle: "Baby Shark",
            mediaFingerprint: "baby-shark-media-fingerprint",
            candidates: []
        )

        XCTAssertEqual(result.candidate.lines.count, 2)
        XCTAssertEqual(result.candidate.lines.map(\.time), [1.0, 3.5])
        XCTAssertEqual(result.candidate.providerName, "AI 证据歌词")
        XCTAssertEqual(result.confidence, 0.86)
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
            monthlyLimitSeconds: 18_000,
            audioContentHash: nil,
            mediaContentHash: nil
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
        XCTAssertEqual(segments.last?.endSeconds ?? -1, 320, accuracy: 0.0001)
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

    private func makeAnalysis(
        segments: [BabyPlayerASRSegment],
        audioContentHash: String? = nil,
        mediaContentHash: String? = nil
    ) -> BabyPlayerASRAnalysis {
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
            monthlyLimitSeconds: 18_000,
            audioContentHash: audioContentHash,
            mediaContentHash: mediaContentHash
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

/// 线程安全记录 mock 请求；输入为 URLRequest，输出快照字段，只修改测试内存。
private final class BabyPlayerMockRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMethod: String?
    private var storedPath: String?
    private var storedAuthorization: String?
    private var storedBodyText = ""
    private var storedMethods: [String] = []
    private var storedPaths: [String] = []
    private var storedBodyTexts: [String] = []

    func record(_ request: URLRequest, body: Data = Data()) {
        lock.withLock {
            storedMethod = request.httpMethod
            storedPath = request.url?.path
            storedAuthorization = request.value(forHTTPHeaderField: "Authorization")
            storedBodyText = String(decoding: body, as: UTF8.self)
            storedMethods.append(request.httpMethod ?? "")
            storedPaths.append(request.url?.path ?? "")
            storedBodyTexts.append(String(decoding: body, as: UTF8.self))
        }
    }

    var method: String? { lock.withLock { storedMethod } }
    var path: String? { lock.withLock { storedPath } }
    var authorization: String? { lock.withLock { storedAuthorization } }
    var bodyText: String { lock.withLock { storedBodyText } }
    var methods: [String] { lock.withLock { storedMethods } }
    var paths: [String] { lock.withLock { storedPaths } }
    var bodyTexts: [String] { lock.withLock { storedBodyTexts } }
}

/// 截获 URLSession 请求并返回本地 JSON；不会访问真实 VPS 或 Tencent。
private final class BabyPlayerMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var storedHandler: Handler?

    static func setHandler(_ handler: Handler?) {
        handlerLock.withLock { storedHandler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.handlerLock.withLock { Self.storedHandler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}

/// URLSession 可能把 JSON body 转换为 stream；测试统一读取两种形式。
private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else {
        throw URLError(.badServerResponse)
    }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}
