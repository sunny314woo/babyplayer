//
// BabyPlayerLyricsRefiner.swift
// 第二轮只纠正文案；时间边界始终来自腾讯 ASR。
// 当前主要功能：把 AI Lyrics v1 及确定性 alignment 证据发给 /v1/refine，仅应用受限文本修复。
// 最近修改：2026-08-23 收紧 Version C repair contract，确保 AI v1/v2 共用 identity 且时间戳不受 DeepSeek 控制。
//

import CryptoKit
import Foundation

// 【MODIFIED】DeepSeek 和 ASR 必须共用同一份 Debug/Release 服务地址规则。
private typealias LyricsRefinerConfiguration = BabyPlayerServiceConfiguration

// 【MODIFIED】请求以 AI v1 原始行和确定性对齐证据为中心，不再要求模型重建 ASR segments。
private struct LyricsRefinerRequest: Encodable {
    struct Word: Encodable {
        let text: String
        let startSeconds: Double
        let endSeconds: Double

        enum CodingKeys: String, CodingKey {
            case text
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
        }
    }

    struct OriginalLine: Encodable {
        let lineIdentifier: String
        let originalText: String
        let startSeconds: Double
        let endSeconds: Double
        let alignedWords: [Word]

        enum CodingKeys: String, CodingKey {
            case lineIdentifier = "line_identifier"
            case originalText = "original_text"
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
            case alignedWords = "aligned_words"
        }
    }

    struct IndexedWord: Encodable {
        let wordIndex: Int
        let text: String
        let startSeconds: Double
        let endSeconds: Double

        enum CodingKeys: String, CodingKey {
            case text
            case wordIndex = "word_index"
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
        }
    }

    struct Evidence: Encodable {
        let normalizedTextSimilarity: Double
        let orderedTokenSimilarity: Double
        let titleSimilarity: Double
        let asrCoverage: Double
        let temporalOrder: Double
        let sameSongConfidence: Double

        enum CodingKeys: String, CodingKey {
            case normalizedTextSimilarity = "normalized_text_similarity"
            case orderedTokenSimilarity = "ordered_token_similarity"
            case titleSimilarity = "title_similarity"
            case asrCoverage = "asr_coverage"
            case temporalOrder = "temporal_order"
            case sameSongConfidence = "same_song_confidence"
        }
    }

    let mediaFingerprint: String
    let transcript: String
    let originalLines: [OriginalLine]
    let asrWords: [IndexedWord]
    let evidence: Evidence

    enum CodingKeys: String, CodingKey {
        case transcript, evidence
        case mediaFingerprint = "media_fingerprint"
        case originalLines = "original_lines"
        case asrWords = "asr_words"
    }
}

private struct LyricsRefinerResponse: Decodable {
    struct Repair: Decodable {
        let lineIdentifier: String
        let originalText: String
        let suggestedText: String
        let shouldModify: Bool
        let shouldDisplay: Bool
        let startWordIndex: Int?
        let endWordIndex: Int?
        let startSeconds: Double?
        let endSeconds: Double?
        let evidence: String
        let confidence: Double

        enum CodingKeys: String, CodingKey {
            case evidence, confidence
            case lineIdentifier = "line_identifier"
            case originalText = "original_text"
            case suggestedText = "suggested_text"
            case shouldModify = "should_modify"
            case shouldDisplay = "should_display"
            case startWordIndex = "start_word_index"
            case endWordIndex = "end_word_index"
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
        }
    }

    let status: String
    let model: String
    let overallConfidence: Double
    let repairs: [Repair]

    enum CodingKeys: String, CodingKey {
        case status, model, repairs
        case overallConfidence = "overall_confidence"
    }
}

struct BabyPlayerLyricsTextRepair: Sendable {
    let lineIdentifier: String
    let originalText: String
    let suggestedText: String
    let shouldModify: Bool
    let confidence: Double
    let shouldDisplay: Bool
    let startSeconds: Double?
    let endSeconds: Double?

    init(
        lineIdentifier: String,
        originalText: String,
        suggestedText: String,
        shouldModify: Bool,
        confidence: Double,
        shouldDisplay: Bool = true,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil
    ) {
        self.lineIdentifier = lineIdentifier
        self.originalText = originalText
        self.suggestedText = suggestedText
        self.shouldModify = shouldModify
        self.confidence = confidence
        self.shouldDisplay = shouldDisplay
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

enum BabyPlayerLyricsRefinerEvidencePolicy {
    static let maximumAlignedWordsPerLine = 100

    static func boundedWords(_ words: [BabyPlayerASRWord]) -> [BabyPlayerASRWord] {
        Array(words.prefix(maximumAlignedWordsPerLine))
    }
}

// 【MODIFIED】单一纯函数应用文本建议，时间和 identity 始终从 AI v1 复制。
enum BabyPlayerLyricsRepairApplier {
    private static let minimumRepairConfidence = 0.55

    /// 应用有限文本 repair；输入为 AI v1、逐行建议和总体置信度，输出为同 identity/同时间轴的 AI v2，不修改 repository/UI。
    static func applying(
        _ repairs: [BabyPlayerLyricsTextRepair],
        to aiLyricsV1: LyricsCandidate,
        overallConfidence: Double
    ) -> LyricsCandidate {
        var repairsByID: [String: BabyPlayerLyricsTextRepair] = [:]
        for repair in repairs where repairsByID[repair.lineIdentifier] == nil {
            repairsByID[repair.lineIdentifier] = repair
        }
        let lines = aiLyricsV1.lines.enumerated().compactMap { index, line in
            let identifier = "line-\(index)"
            guard let repair = repairsByID[identifier],
                  repair.originalText == line.text else {
                return line
            }
            guard repair.shouldDisplay else { return nil }
            let start = repair.startSeconds ?? line.time
            let end = repair.endSeconds ?? line.endTime
            let canModify = repair.shouldModify
                && repair.confidence >= minimumRepairConfidence
                && !repair.suggestedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return TimedLyricLine(
                time: start,
                text: canModify ? repair.suggestedText : line.text,
                endTime: end
            )
        }
        return LyricsCandidate(
            id: aiLyricsV1.id,
            trackName: aiLyricsV1.trackName,
            artistName: aiLyricsV1.artistName,
            albumName: aiLyricsV1.albumName,
            duration: aiLyricsV1.duration,
            lines: lines,
            matchScore: max(0, 100 - overallConfidence * 100),
            providerName: aiLyricsV1.providerName?.contains("本地歌本") == true
                ? "本地歌本·AI优化"
                : "AI 优化歌词",
            identityAnchor: aiLyricsV1.identityAnchor
        )
    }
}

struct BabyPlayerLyricsRefinerClient {
    private enum RepairPolicy {
        static let minimumOverallConfidence = 0.55
        static let alignmentBoundaryToleranceSeconds = 0.25
    }

    private let configuration: LyricsRefinerConfiguration
    private let session: URLSession

    init(session: URLSession = .shared) throws {
        configuration = try .load()
        self.session = session
    }

    // 【MODIFIED】只接收已有 AI v1，并将文本建议应用回同一 candidate。
    /// 请求有限文本修复；输入为 ASR 证据、AI v1、same-song 证据和指纹，输出为同 identity/同时间轴 AI v2，不直接修改 repository/UI。
    func refine(
        analysis: BabyPlayerASRAnalysis,
        aiLyricsV1: LyricsCandidate,
        evidence: BabyPlayerSameSongEvidence?,
        mediaFingerprint: String
    ) async throws -> LyricsCandidate {
        let fallbackEvidence = BabyPlayerSameSongEvidence(
            normalizedTextSimilarity: 0,
            orderedTokenSimilarity: 0,
            titleSimilarity: 0,
            asrCoverage: 0,
            temporalOrder: 0,
            sameSongConfidence: 0
        )
        let resolvedEvidence = evidence ?? fallbackEvidence
        let requestBody = LyricsRefinerRequest(
            mediaFingerprint: mediaFingerprint,
            transcript: analysis.transcript.isEmpty
                ? analysis.segments.map(\.text).joined(separator: " ")
                : analysis.transcript,
            originalLines: requestLines(aiLyricsV1: aiLyricsV1, analysis: analysis),
            asrWords: analysis.segments.flatMap(\.words).enumerated().map {
                .init(
                    wordIndex: $0.offset,
                    text: $0.element.text,
                    startSeconds: $0.element.startSeconds,
                    endSeconds: $0.element.endSeconds
                )
            },
            evidence: .init(
                normalizedTextSimilarity: resolvedEvidence.normalizedTextSimilarity,
                orderedTokenSimilarity: resolvedEvidence.orderedTokenSimilarity,
                titleSimilarity: resolvedEvidence.titleSimilarity,
                asrCoverage: resolvedEvidence.asrCoverage,
                temporalOrder: resolvedEvidence.temporalOrder,
                sameSongConfidence: resolvedEvidence.sameSongConfidence
            )
        )
        guard requestBody.originalLines.count >= 2 else { throw BabyPlayerASRError.invalidResponse }
        guard requestBody.asrWords.count >= 3 else { throw BabyPlayerASRError.invalidResponse }

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("refine"))
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(requestBody)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BabyPlayerASRError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                throw BabyPlayerASRError.server(envelope.detail.message ?? envelope.detail.code)
            }
            throw BabyPlayerASRError.invalidResponse
        }
        let refined = try JSONDecoder().decode(LyricsRefinerResponse.self, from: data)
        guard refined.overallConfidence >= RepairPolicy.minimumOverallConfidence,
              refined.repairs.count == aiLyricsV1.lines.count else {
            throw BabyPlayerASRError.server("AI 文案校正置信度不足")
        }
        let repairs = refined.repairs.map {
            BabyPlayerLyricsTextRepair(
                lineIdentifier: $0.lineIdentifier,
                originalText: $0.originalText,
                suggestedText: $0.suggestedText,
                shouldModify: $0.shouldModify,
                confidence: $0.confidence,
                shouldDisplay: $0.shouldDisplay,
                startSeconds: $0.startSeconds,
                endSeconds: $0.endSeconds
            )
        }
        let result = BabyPlayerLyricsRepairApplier.applying(
            repairs,
            to: aiLyricsV1,
            overallConfidence: refined.overallConfidence
        )
        guard result.lines.count >= 2 else {
            throw BabyPlayerASRError.server("AI 对齐后的有效字幕不足")
        }
        return result
    }

    /// 把 AI v1 行与对应 ASR words 组成证据；输入为 AI v1 和 analysis，输出为结构化原始行，不修改状态。
    private func requestLines(
        aiLyricsV1: LyricsCandidate,
        analysis: BabyPlayerASRAnalysis
    ) -> [LyricsRefinerRequest.OriginalLine] {
        let words = analysis.segments.flatMap(\.words)
        return aiLyricsV1.lines.enumerated().map { index, line in
            let fallbackEnd = aiLyricsV1.lines.indices.contains(index + 1)
                ? aiLyricsV1.lines[index + 1].time
                : max(analysis.audioDurationSeconds, line.time)
            let end = max(line.time, line.endTime ?? fallbackEnd)
            let relevantWords = words.filter {
                $0.startSeconds >= line.time - RepairPolicy.alignmentBoundaryToleranceSeconds
                    && $0.startSeconds < end + RepairPolicy.alignmentBoundaryToleranceSeconds
            }
            let boundedWords = BabyPlayerLyricsRefinerEvidencePolicy.boundedWords(relevantWords)
            return .init(
                lineIdentifier: "line-\(index)",
                originalText: line.text,
                startSeconds: line.time,
                endSeconds: end,
                alignedWords: boundedWords.map {
                    .init(
                        text: $0.text,
                        startSeconds: $0.startSeconds,
                        endSeconds: $0.endSeconds
                    )
                }
            )
        }
    }
}

// MARK: - Version D3 reusable evidence reconciliation client

private struct LyricsReconciliationRequest: Encodable {
    struct CandidateLine: Encodable {
        let lineIdentifier: String
        let text: String
        let originalStartSeconds: Double?
        let originalEndSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case text
            case lineIdentifier = "line_identifier"
            case originalStartSeconds = "original_start_seconds"
            case originalEndSeconds = "original_end_seconds"
        }
    }

    struct Candidate: Encodable {
        let candidateID: String
        let source: String
        let title: String
        let artist: String
        let lines: [CandidateLine]

        enum CodingKeys: String, CodingKey {
            case source, title, artist, lines
            case candidateID = "candidate_id"
        }
    }

    let mediaFingerprint: String
    let songTitle: String
    let candidates: [Candidate]
    let forceRefresh: Bool

    enum CodingKeys: String, CodingKey {
        case candidates
        case mediaFingerprint = "media_fingerprint"
        case songTitle = "song_title"
        case forceRefresh = "force_refresh"
    }
}

private struct LyricsReconciliationResponse: Decodable {
    struct Line: Decodable {
        let text: String
        let asrWordStartIndex: Int
        let asrWordEndIndex: Int
        let startSeconds: Double
        let endSeconds: Double
        let source: String
        let confidence: Double
        let textCorrected: Bool

        enum CodingKeys: String, CodingKey {
            case text, source, confidence
            case asrWordStartIndex = "asr_word_start_index"
            case asrWordEndIndex = "asr_word_end_index"
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
            case textCorrected = "text_corrected"
        }
    }

    let status: String
    let cacheHit: Bool
    let model: String
    let reconciliationVersion: String
    let songMatchConfidence: Double
    let primarySource: String
    let webSearchUsed: Bool
    let asrWordCoverage: Double?
    let recoveredAsrWordCount: Int?
    let lines: [Line]

    enum CodingKeys: String, CodingKey {
        case status, model, lines
        case cacheHit = "cache_hit"
        case reconciliationVersion = "reconciliation_version"
        case songMatchConfidence = "song_match_confidence"
        case primarySource = "primary_source"
        case webSearchUsed = "web_search_used"
        case asrWordCoverage = "asr_word_coverage"
        case recoveredAsrWordCount = "recovered_asr_word_count"
    }
}

struct BabyPlayerLyricsReconciliationResult: Sendable {
    let candidate: LyricsCandidate
    let confidence: Double
    let cacheHit: Bool
    let webSearchUsed: Bool
    let asrWordCoverage: Double
    let recoveredAsrWordCount: Int
}

/// D3 API 只上传标题和最多三份候选；ASR 和时间轴由 VPS 缓存与验证。
struct BabyPlayerLyricsReconcilerClient {
    private let configuration: LyricsRefinerConfiguration
    private let session: URLSession

    init(session: URLSession = .shared) throws {
        configuration = try .load()
        self.session = session
    }

    func reconcile(
        songTitle: String,
        mediaFingerprint: String,
        candidates: [LyricsCandidate],
        forceRefresh: Bool = false
    ) async throws -> BabyPlayerLyricsReconciliationResult {
        let ordinaryCandidates = candidates.filter { $0.identityAnchor == nil }
        let requestCandidates = ordinaryCandidates.prefix(3).enumerated().map { index, candidate in
            LyricsReconciliationRequest.Candidate(
                candidateID: "candidate_\(index + 1)",
                source: candidate.providerName ?? "unknown",
                title: candidate.trackName,
                artist: candidate.artistName,
                lines: candidate.lines.enumerated().map { lineIndex, line in
                    .init(
                        lineIdentifier: "line_\(lineIndex)",
                        text: line.text,
                        originalStartSeconds: line.time,
                        originalEndSeconds: line.endTime
                    )
                }
            )
        }
        let body = LyricsReconciliationRequest(
            mediaFingerprint: mediaFingerprint,
            songTitle: songTitle,
            candidates: Array(requestCandidates),
            forceRefresh: forceRefresh
        )
        var request = URLRequest(
            url: configuration.baseURL.appendingPathComponent("lyrics/reconcile")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BabyPlayerASRError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                throw BabyPlayerASRError.server(envelope.detail.message ?? envelope.detail.code)
            }
            throw BabyPlayerASRError.invalidResponse
        }
        let reconciled = try JSONDecoder().decode(LyricsReconciliationResponse.self, from: data)
        return try makeResult(
            reconciled,
            songTitle: songTitle,
            mediaFingerprint: mediaFingerprint,
            ordinaryCandidates: ordinaryCandidates
        )
    }

    /// 只读服务器已有 DeepSeek 结果；命中时不调用 ASR、搜索或大模型。
    func cachedReconciliation(
        songTitle: String,
        mediaFingerprint: String
    ) async throws -> BabyPlayerLyricsReconciliationResult? {
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("lyrics/cache"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "media_fingerprint", value: mediaFingerprint)
        ]
        guard let url = components?.url else { throw BabyPlayerASRError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BabyPlayerASRError.invalidResponse
        }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                throw BabyPlayerASRError.server(envelope.detail.message ?? envelope.detail.code)
            }
            throw BabyPlayerASRError.invalidResponse
        }
        let reconciled = try JSONDecoder().decode(LyricsReconciliationResponse.self, from: data)
        return try makeResult(
            reconciled,
            songTitle: songTitle,
            mediaFingerprint: mediaFingerprint,
            ordinaryCandidates: []
        )
    }

    private func makeResult(
        _ reconciled: LyricsReconciliationResponse,
        songTitle: String,
        mediaFingerprint: String,
        ordinaryCandidates: [LyricsCandidate]
    ) throws -> BabyPlayerLyricsReconciliationResult {
        guard reconciled.lines.count >= 2,
              (0.0...1.0).contains(reconciled.songMatchConfidence),
              (0.0...1.0).contains(reconciled.asrWordCoverage ?? 1),
              (reconciled.recoveredAsrWordCount ?? 0) >= 0 else {
            throw BabyPlayerASRError.server("AI 歌词重建证据不足")
        }
        var previousEnd = -1
        let lines = try reconciled.lines.map { line -> TimedLyricLine in
            guard line.asrWordStartIndex > previousEnd,
                  line.asrWordEndIndex >= line.asrWordStartIndex,
                  line.endSeconds >= line.startSeconds,
                  !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BabyPlayerASRError.invalidResponse
            }
            previousEnd = line.asrWordEndIndex
            return TimedLyricLine(
                time: line.startSeconds,
                text: line.text,
                endTime: line.endSeconds
            )
        }
        let anchor = "ai-reconciled:\(mediaFingerprint)"
        let digest = SHA256.hash(data: Data(anchor.utf8))
        let numericID = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let candidate = LyricsCandidate(
            id: -1_900_000_000 - Int(numericID % 200_000_000),
            trackName: songTitle,
            artistName: ordinaryCandidates.first?.artistName ?? "",
            albumName: nil,
            duration: max(
                ordinaryCandidates.map(\.duration).max() ?? 0,
                lines.last?.endTime ?? lines.last?.time ?? 0
            ),
            lines: lines,
            matchScore: max(0, 100 - reconciled.songMatchConfidence * 100),
            providerName: reconciled.webSearchUsed
                ? "AI 证据歌词·限定检索"
                : "AI 证据歌词",
            identityAnchor: anchor
        )
        return BabyPlayerLyricsReconciliationResult(
            candidate: candidate,
            confidence: reconciled.songMatchConfidence,
            cacheHit: reconciled.cacheHit,
            webSearchUsed: reconciled.webSearchUsed,
            asrWordCoverage: reconciled.asrWordCoverage ?? 1,
            recoveredAsrWordCount: reconciled.recoveredAsrWordCount ?? 0
        )
    }
}

// MARK: - Phase 3A independent Simplified Chinese translation

enum BabyPlayerLyricsLanguagePolicy {
    private static let englishEvidenceWords: Set<String> = [
        "a", "all", "am", "an", "and", "are", "away", "baby", "be", "birthday",
        "can", "come", "do", "down", "for", "go", "good", "had", "happy", "hello",
        "here", "how", "i", "if", "in", "is", "it", "little", "love", "me", "my",
        "no", "not", "of", "oh", "old", "on", "one", "out", "please", "see", "sing",
        "star", "the", "there", "this", "three", "to", "two", "up", "we", "what",
        "when", "where", "with", "wonder", "yes", "you", "your"
    ]

    /// 仅根据最终歌词文本作确定性判断；标题、模型和媒体元数据都不参与。
    static func isPredominantlyEnglish(_ lines: [TimedLyricLine]) -> Bool {
        let text = lines.map(\.text).joined(separator: " ")
        var totalLetters = 0
        var asciiLatinLetters = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            totalLetters += 1
            if (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value)) {
                asciiLatinLetters += 1
            }
        }
        guard totalLetters >= 12,
              Double(asciiLatinLetters) / Double(totalLetters) >= 0.85 else { return false }

        let words = text.lowercased().components(
            separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted
        ).filter { !$0.isEmpty }
        guard words.count >= 3 else { return false }
        let asciiWords = words.filter { word in
            word.unicodeScalars.allSatisfy {
                (97...122).contains(Int($0.value)) || $0.value == 39
            }
        }
        guard Double(asciiWords.count) / Double(words.count) >= 0.8 else { return false }
        return asciiWords.contains(where: englishEvidenceWords.contains)
    }

    /// 中文原文只用来选择展示模式；不会触发翻译或改变任何时间字段。
    static func isPredominantlyChinese(_ lines: [TimedLyricLine]) -> Bool {
        let scalars = lines.flatMap { $0.text.unicodeScalars }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        let hanCount = letters.filter(isHanCharacter).count
        guard hanCount >= 4, !letters.isEmpty else { return false }
        return Double(hanCount) / Double(letters.count) >= 0.6
    }

    private static func isHanCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

enum BabyPlayerLyricsTranslationContract {
    static let translationVersion = "babyplayer-zh-hans-v1"
    static let targetLanguage = "zh-Hans"
    static let maximumChineseCharacters = 300

    static func lineIdentifier(at index: Int) -> String {
        "line-\(index)"
    }

    static func isCompatible(_ result: StoredLyricsTranslationResult) -> Bool {
        result.translationVersion == translationVersion
            && result.targetLanguage == targetLanguage
            && !result.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct BilingualLyricLine: Equatable, Sendable {
    let identifier: String
    let startSeconds: Double
    let endSeconds: Double?
    let englishText: String
    let chineseText: String
}

enum BabyPlayerBilingualLyricsComposer {
    /// 中文只能按 identifier 附着；所有时间、顺序和英文内容逐字段复制自 DeepSeek 英文结果。
    static func compose(
        english: StoredLyricsAnalysisResult,
        translation: StoredLyricsTranslationResult
    ) -> [BilingualLyricLine]? {
        guard english.source == .deepSeek,
              translation.englishLyricsContentHash == english.lyricsContentHash,
              BabyPlayerLyricsTranslationContract.isCompatible(translation),
              translation.lines.count == english.candidate.lines.count else { return nil }

        var seen = Set<String>()
        var result: [BilingualLyricLine] = []
        for (index, englishLine) in english.candidate.lines.enumerated() {
            let translatedLine = translation.lines[index]
            let expectedIdentifier = BabyPlayerLyricsTranslationContract.lineIdentifier(at: index)
            let chinese = translatedLine.chineseText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard translatedLine.lineIdentifier == expectedIdentifier,
                  seen.insert(translatedLine.lineIdentifier).inserted,
                  !chinese.isEmpty,
                  chinese.count <= BabyPlayerLyricsTranslationContract.maximumChineseCharacters,
                  translatedLine.confidence.map({ (0...1).contains($0) }) ?? true else { return nil }
            result.append(BilingualLyricLine(
                identifier: expectedIdentifier,
                startSeconds: englishLine.time,
                endSeconds: englishLine.endTime,
                englishText: englishLine.text,
                chineseText: chinese
            ))
        }
        return result
    }
}

/// 播放页只根据已有的字幕内容决定默认模式；不会触发网络或改写英文时间轴。
enum BabyPlayerLyricsPresentationPolicy {
    static func preferredMode(
        subtitlesEnabled: Bool,
        sourceLines: [TimedLyricLine],
        bilingualLines: [BilingualLyricLine]?
    ) -> BabyPlayerLyricsMode {
        guard subtitlesEnabled else { return .off }
        if bilingualLines?.isEmpty == false { return .bilingual }
        if BabyPlayerLyricsLanguagePolicy.isPredominantlyChinese(sourceLines) { return .chinese }
        return sourceLines.isEmpty ? .off : .english
    }

    static func availableModes(
        sourceLines: [TimedLyricLine],
        bilingualLines: [BilingualLyricLine]?
    ) -> [BabyPlayerLyricsMode] {
        if bilingualLines?.isEmpty == false {
            return [.bilingual, .english, .chinese, .off]
        }
        if BabyPlayerLyricsLanguagePolicy.isPredominantlyChinese(sourceLines) {
            return [.chinese, .off]
        }
        if !sourceLines.isEmpty {
            return [.english, .off]
        }
        return [.off]
    }

    static func displayText(
        mode: BabyPlayerLyricsMode,
        sourceText: String,
        bilingualLine: BilingualLyricLine?
    ) -> String? {
        switch mode {
        case .off:
            return nil
        case .english:
            return bilingualLine?.englishText ?? sourceText
        case .chinese:
            return bilingualLine?.chineseText ?? sourceText
        case .bilingual:
            guard let bilingualLine else { return sourceText }
            return bilingualLine.englishText + "\n" + bilingualLine.chineseText
        }
    }
}

enum BabyPlayerLyricsSourceMenuPolicy {
    /// 当前候选在上方单独展示；其他候选保留 LRCLIB 的原排名和原序。
    static func rankedAlternatives(
        _ candidates: [LyricsCandidate],
        currentCandidateID: Int?,
        currentLyricIdentifier: String?
    ) -> [(rank: Int, candidate: LyricsCandidate)] {
        candidates.enumerated().compactMap { index, candidate in
            let isCurrent = candidate.id == currentCandidateID
                || candidate.persistentIdentifier == currentLyricIdentifier
            return isCurrent ? nil : (index + 1, candidate)
        }
    }
}

private struct LyricsTranslationRequest: Encodable {
    struct Line: Encodable {
        let lineIdentifier: String
        let englishText: String

        enum CodingKeys: String, CodingKey {
            case lineIdentifier = "line_identifier"
            case englishText = "english_text"
        }
    }

    let mediaFingerprint: String
    let englishLyricsContentHash: String
    let translationVersion: String
    let targetLanguage: String
    let lines: [Line]

    enum CodingKeys: String, CodingKey {
        case lines
        case mediaFingerprint = "media_fingerprint"
        case englishLyricsContentHash = "english_lyrics_content_hash"
        case translationVersion = "translation_version"
        case targetLanguage = "target_language"
    }
}

private struct LyricsTranslationResponse: Decodable {
    struct Line: Decodable {
        let lineIdentifier: String
        let chineseText: String
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case confidence
            case lineIdentifier = "line_identifier"
            case chineseText = "chinese_text"
        }
    }

    let status: String
    let model: String
    let translationVersion: String
    let targetLanguage: String
    let englishLyricsContentHash: String
    let lines: [Line]

    enum CodingKeys: String, CodingKey {
        case status, model, lines
        case translationVersion = "translation_version"
        case targetLanguage = "target_language"
        case englishLyricsContentHash = "english_lyrics_content_hash"
    }
}

enum BabyPlayerLyricsTranslationResponseValidator {
    /// Swift Decodable 默认忽略未知键；因此先检查原始 JSON，明确拒绝模型夹带的时间字段。
    static func validateRawJSON(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = root["lines"] as? [[String: Any]] else {
            throw BabyPlayerASRError.invalidResponse
        }
        let allowedRootKeys: Set<String> = [
            "status", "cache_hit", "model", "translation_version",
            "target_language", "english_lyrics_content_hash", "lines"
        ]
        let allowedLineKeys: Set<String> = ["line_identifier", "chinese_text", "confidence"]
        guard Set(root.keys).isSubset(of: allowedRootKeys),
              lines.allSatisfy({ Set($0.keys).isSubset(of: allowedLineKeys) }) else {
            throw BabyPlayerASRError.invalidResponse
        }
    }
}

struct BabyPlayerLyricsTranslationClient {
    private let configuration: LyricsRefinerConfiguration
    private let session: URLSession

    init(session: URLSession = .shared) throws {
        configuration = try .load()
        self.session = session
    }

    init(baseURL: URL, apiToken: String, session: URLSession) {
        configuration = LyricsRefinerConfiguration(baseURL: baseURL, apiToken: apiToken)
        self.session = session
    }

    func translate(
        english: StoredLyricsAnalysisResult,
        mediaFingerprint: String
    ) async throws -> StoredLyricsTranslationResult {
        guard english.source == .deepSeek,
              BabyPlayerLyricsLanguagePolicy.isPredominantlyEnglish(english.candidate.lines) else {
            throw BabyPlayerASRError.invalidResponse
        }
        let requestBody = LyricsTranslationRequest(
            mediaFingerprint: mediaFingerprint,
            englishLyricsContentHash: english.lyricsContentHash,
            translationVersion: BabyPlayerLyricsTranslationContract.translationVersion,
            targetLanguage: BabyPlayerLyricsTranslationContract.targetLanguage,
            lines: english.candidate.lines.indices.map { index in
                .init(
                    lineIdentifier: BabyPlayerLyricsTranslationContract.lineIdentifier(at: index),
                    englishText: english.candidate.lines[index].text
                )
            }
        )
        var request = URLRequest(
            url: configuration.baseURL.appendingPathComponent("lyrics/translate/zh-Hans")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BabyPlayerASRError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                throw BabyPlayerASRError.server(envelope.detail.message ?? envelope.detail.code)
            }
            throw BabyPlayerASRError.invalidResponse
        }
        try BabyPlayerLyricsTranslationResponseValidator.validateRawJSON(data)
        let translated = try JSONDecoder().decode(LyricsTranslationResponse.self, from: data)
        let expectedIdentifiers = english.candidate.lines.indices.map {
            BabyPlayerLyricsTranslationContract.lineIdentifier(at: $0)
        }
        let identifiers = translated.lines.map(\.lineIdentifier)
        guard translated.status == "completed",
              translated.englishLyricsContentHash == english.lyricsContentHash,
              translated.translationVersion == BabyPlayerLyricsTranslationContract.translationVersion,
              translated.targetLanguage == BabyPlayerLyricsTranslationContract.targetLanguage,
              Set(identifiers).count == identifiers.count,
              identifiers == expectedIdentifiers else {
            throw BabyPlayerASRError.invalidResponse
        }
        let result = StoredLyricsTranslationResult(
            mediaFingerprint: mediaFingerprint,
            englishLyricsContentHash: translated.englishLyricsContentHash,
            translationVersion: translated.translationVersion,
            targetLanguage: translated.targetLanguage,
            model: translated.model,
            lines: translated.lines.map {
                StoredLyricsTranslationLine(
                    lineIdentifier: $0.lineIdentifier,
                    chineseText: $0.chineseText,
                    confidence: $0.confidence
                )
            },
            createdAt: Date()
        )
        guard BabyPlayerBilingualLyricsComposer.compose(
            english: english,
            translation: result
        ) != nil else { throw BabyPlayerASRError.invalidResponse }
        return result
    }
}
