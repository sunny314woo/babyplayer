//
// BabyPlayerLyricsRefiner.swift
// 第二轮只纠正文案；时间边界始终来自腾讯 ASR。
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

private struct LyricsRefinerRequest: Encodable {
    struct Segment: Encodable {
        let index: Int
        let text: String
        let startSeconds: Double
        let endSeconds: Double

        enum CodingKeys: String, CodingKey {
            case index, text
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
        }
    }

    struct Candidate: Encodable {
        let identifier: String
        let title: String
        let artist: String
        let source: String
        let lines: [String]
    }

    let mediaFingerprint: String
    let transcript: String
    let segments: [Segment]
    let candidates: [Candidate]

    enum CodingKeys: String, CodingKey {
        case transcript, segments, candidates
        case mediaFingerprint = "media_fingerprint"
    }
}

private struct LyricsRefinerResponse: Decodable {
    struct Line: Decodable {
        let segmentIndex: Int
        let startSeconds: Double
        let endSeconds: Double
        let text: String

        enum CodingKeys: String, CodingKey {
            case text
            case segmentIndex = "segment_index"
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
        }
    }

    let status: String
    let model: String
    let confidence: Double
    let selectedCandidateIdentifier: String?
    let lines: [Line]

    enum CodingKeys: String, CodingKey {
        case status, model, confidence, lines
        case selectedCandidateIdentifier = "selected_candidate_identifier"
    }
}

struct BabyPlayerLyricsRefinerClient {
    private let configuration: LyricsRefinerConfiguration
    private let session: URLSession

    init(session: URLSession = .shared) throws {
        configuration = try .load()
        self.session = session
    }

    func refine(
        analysis: BabyPlayerASRAnalysis,
        candidates: [LyricsCandidate],
        reference: LyricsPlainTextReference?,
        mediaFingerprint: String
    ) async throws -> LyricsCandidate {
        let available = requestCandidates(candidates: candidates, reference: reference)
        let requestBody = LyricsRefinerRequest(
            mediaFingerprint: mediaFingerprint,
            transcript: analysis.transcript,
            segments: analysis.segments.enumerated().compactMap { index, segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return .init(
                    index: index,
                    text: text,
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds
                )
            },
            candidates: available
        )
        guard requestBody.segments.count >= 2 else { throw BabyPlayerASRError.invalidResponse }

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
        guard refined.confidence >= 0.55, refined.lines.count >= 2 else {
            throw BabyPlayerASRError.server("AI 文案校正置信度不足")
        }

        let selected = refined.selectedCandidateIdentifier.flatMap { identifier in
            candidates.first { $0.persistentIdentifier == identifier }
        }
        let selectedReference: LyricsPlainTextReference? = refined.selectedCandidateIdentifier.flatMap { identifier in
            guard let reference, identifier == "songbook:\(reference.id)" else { return nil }
            return reference
        }
        let lines = refined.lines
            .sorted { $0.segmentIndex < $1.segmentIndex }
            .map { TimedLyricLine(time: $0.startSeconds, text: $0.text) }
        let identityText = lines.map { "\($0.time)|\($0.text)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identityText.utf8))
        let numericID = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return LyricsCandidate(
            id: -2_000_000_000 - Int(numericID),
            trackName: selected?.trackName ?? selectedReference?.title ?? "AI 校正歌词",
            artistName: selected?.artistName ?? selectedReference?.artist ?? "腾讯 ASR + DeepSeek",
            albumName: selected?.albumName ?? (selectedReference == nil ? nil : "本地歌本"),
            duration: max(analysis.audioDurationSeconds, lines.last?.time ?? 0),
            lines: lines,
            matchScore: max(0, 100 - refined.confidence * 100),
            providerName: selectedReference == nil
                ? "DeepSeek V4 Flash·腾讯时间轴"
                : "本地歌本·自动校时 · DeepSeek V4 Flash"
        )
    }

    private func requestCandidates(
        candidates: [LyricsCandidate],
        reference: LyricsPlainTextReference?
    ) -> [LyricsRefinerRequest.Candidate] {
        var result = candidates.prefix(3).map {
            LyricsRefinerRequest.Candidate(
                identifier: $0.persistentIdentifier,
                title: $0.trackName,
                artist: $0.artistName,
                source: $0.providerName ?? "网络歌词",
                lines: $0.lines.map(\.text)
            )
        }
        if let reference {
            result.append(.init(
                identifier: "songbook:\(reference.id)",
                title: reference.title,
                artist: reference.artist,
                source: "本地歌本",
                lines: reference.plainLyrics.components(separatedBy: .newlines)
            ))
        }
        return result
    }
}
