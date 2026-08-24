//
// BabyPlayerLyricsRefiner.swift
// 第二轮只纠正文案；时间边界始终来自腾讯 ASR。
// 当前主要功能：把 AI Lyrics v1 及确定性 alignment 证据发给 /v1/refine，仅应用受限文本修复。
// 最近修改：2026-08-23 收紧 Version C repair contract，确保 AI v1/v2 共用 identity 且时间戳不受 DeepSeek 控制。
//

import CryptoKit
import Foundation

private struct LyricsRefinerConfiguration {
    let baseURL: URL
    let apiToken: String

    static func load() throws -> LyricsRefinerConfiguration {
        let rawURL = Bundle.main.object(forInfoDictionaryKey: "BabyPlayerASRBaseURL") as? String ?? ""
        let token = Bundle.main.object(forInfoDictionaryKey: "BabyPlayerASRAPIToken") as? String ?? ""
        guard let baseURL = URL(string: rawURL), baseURL.scheme == "https",
              !token.isEmpty, !token.uppercased().hasPrefix("XX_") else {
            throw BabyPlayerASRError.notConfigured
        }
        return LyricsRefinerConfiguration(baseURL: baseURL, apiToken: token)
    }
}

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
    let lines: [Line]

    enum CodingKeys: String, CodingKey {
        case status, model, lines
        case cacheHit = "cache_hit"
        case reconciliationVersion = "reconciliation_version"
        case songMatchConfidence = "song_match_confidence"
        case primarySource = "primary_source"
        case webSearchUsed = "web_search_used"
    }
}

struct BabyPlayerLyricsReconciliationResult: Sendable {
    let candidate: LyricsCandidate
    let confidence: Double
    let cacheHit: Bool
    let webSearchUsed: Bool
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
        guard reconciled.lines.count >= 2,
              (0.0...1.0).contains(reconciled.songMatchConfidence) else {
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
            webSearchUsed: reconciled.webSearchUsed
        )
    }
}
