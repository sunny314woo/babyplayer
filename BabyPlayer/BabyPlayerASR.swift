//
// BabyPlayerASR.swift
// Apple TV 本地提取 M4A、管理音频缓存、调用独立 ASR 代理并在本地匹配歌词。
//

import AVFoundation
import CryptoKit
import Foundation

struct BabyPlayerASRWord: Codable, Sendable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double

    enum CodingKeys: String, CodingKey {
        case text
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

struct BabyPlayerASRSegment: Codable, Sendable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
    let words: [BabyPlayerASRWord]

    enum CodingKeys: String, CodingKey {
        case text, words
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

struct BabyPlayerASRAnalysis: Codable, Sendable {
    let status: String
    let cacheHit: Bool
    let provider: String
    let engineType: String
    let audioDurationSeconds: Double
    let transcript: String
    let segments: [BabyPlayerASRSegment]
    let monthlyUsedSeconds: Int
    let monthlyReservedSeconds: Int
    let monthlyLimitSeconds: Int

    enum CodingKeys: String, CodingKey {
        case status, provider, transcript, segments
        case cacheHit = "cache_hit"
        case engineType = "engine_type"
        case audioDurationSeconds = "audio_duration_seconds"
        case monthlyUsedSeconds = "monthly_used_seconds"
        case monthlyReservedSeconds = "monthly_reserved_seconds"
        case monthlyLimitSeconds = "monthly_limit_seconds"
    }
}

struct BabyPlayerASRUsage: Codable, Sendable {
    let month: String
    let usedSeconds: Int
    let reservedSeconds: Int
    let remainingSeconds: Int
    let limitSeconds: Int
    let nextResetAt: String

    enum CodingKeys: String, CodingKey {
        case month
        case usedSeconds = "used_seconds"
        case reservedSeconds = "reserved_seconds"
        case remainingSeconds = "remaining_seconds"
        case limitSeconds = "limit_seconds"
        case nextResetAt = "next_reset_at"
    }
}

enum BabyPlayerASRError: LocalizedError {
    case notConfigured
    case cacheMiss
    case monthlyLimit(String)
    case invalidResponse
    case server(String)
    case audioExportFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "声音分析服务尚未配置"
        case .cacheMiss:
            return "尚无声音分析缓存"
        case let .monthlyLimit(message), let .server(message):
            return message
        case .invalidResponse:
            return "声音分析服务返回了无法识别的数据"
        case .audioExportFailed:
            return "暂时无法从这个视频提取歌曲音频"
        }
    }
}

enum BabyPlayerASRQuotaPolicy {
    static func validate(_ usage: BabyPlayerASRUsage, requestedSeconds: Double) throws {
        let required = max(1, Int(requestedSeconds.rounded(.up)))
        guard usage.remainingSeconds >= required else {
            throw BabyPlayerASRError.monthlyLimit(
                BabyPlayerASRDateFormatter.limitMessage(nextResetAt: usage.nextResetAt)
            )
        }
    }
}

enum BabyPlayerASRDateFormatter {
    static func limitMessage(nextResetAt: String) -> String {
        "本月声音分析额度不足，可于 \(display(nextResetAt)) 再次使用"
    }

    static func display(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

private struct BabyPlayerASRConfiguration {
    let baseURL: URL
    let apiToken: String

    static func load() throws -> BabyPlayerASRConfiguration {
        let rawURL = Bundle.main.object(forInfoDictionaryKey: "BabyPlayerASRBaseURL") as? String ?? ""
        let token = Bundle.main.object(forInfoDictionaryKey: "BabyPlayerASRAPIToken") as? String ?? ""
        guard !rawURL.isEmpty, !token.isEmpty,
              !rawURL.uppercased().contains("XX_"),
              !token.uppercased().hasPrefix("XX_"),
              let url = URL(string: rawURL), url.scheme == "https" else {
            throw BabyPlayerASRError.notConfigured
        }
        return BabyPlayerASRConfiguration(baseURL: url, apiToken: token)
    }
}

struct BabyPlayerASRClient {
    private let configuration: BabyPlayerASRConfiguration
    private let session: URLSession

    init(session: URLSession = .shared) throws {
        configuration = try .load()
        self.session = session
    }

    func cachedAnalysis(mediaFingerprint: String) async throws -> BabyPlayerASRAnalysis {
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("cache"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "media_fingerprint", value: mediaFingerprint)]
        guard let url = components?.url else { throw BabyPlayerASRError.invalidResponse }
        var request = authenticatedRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw BabyPlayerASRError.cacheMiss }
        return try decode(BabyPlayerASRAnalysis.self, data: data, response: response)
    }

    func usage() async throws -> BabyPlayerASRUsage {
        var request = authenticatedRequest(url: configuration.baseURL.appendingPathComponent("usage"))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        return try decode(BabyPlayerASRUsage.self, data: data, response: response)
    }

    func analyze(
        sampleURL: URL,
        durationSeconds: Double,
        mediaFingerprint: String
    ) async throws -> BabyPlayerASRAnalysis {
        let audio = try Data(contentsOf: sampleURL, options: [.mappedIfSafe])
        let boundary = "BabyPlayerBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        appendField("operation_id", UUID().uuidString, boundary: boundary, to: &body)
        appendField("media_fingerprint", mediaFingerprint, boundary: boundary, to: &body)
        appendField("duration_seconds", String(format: "%.3f", durationSeconds), boundary: boundary, to: &body)
        appendField("voice_format", "m4a", boundary: boundary, to: &body)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"sample.m4a\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n")

        var request = authenticatedRequest(url: configuration.baseURL.appendingPathComponent("analyze"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: body)
        return try decode(BabyPlayerASRAnalysis.self, data: data, response: response)
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw BabyPlayerASRError.invalidResponse }
        if (200...299).contains(http.statusCode) {
            return try JSONDecoder().decode(T.self, from: data)
        }
        if let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
            if envelope.detail.code == "MONTHLY_ASR_LIMIT_REACHED" {
                let message = envelope.detail.message
                    ?? envelope.detail.nextAvailableAt.map(BabyPlayerASRDateFormatter.limitMessage)
                    ?? "本月声音分析额度已用完"
                throw BabyPlayerASRError.monthlyLimit(message)
            }
            throw BabyPlayerASRError.server(envelope.detail.message ?? envelope.detail.code)
        }
        throw BabyPlayerASRError.invalidResponse
    }

    private func appendField(_ name: String, _ value: String, boundary: String, to data: inout Data) {
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append("\(value)\r\n")
    }
}

struct ServerErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let code: String
        let message: String?
        let nextAvailableAt: String?

        enum CodingKeys: String, CodingKey {
            case code, message
            case nextAvailableAt = "next_available_at"
        }
    }
    let detail: Detail
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

struct BabyPlayerAudioCacheEntry: Codable, Identifiable, Sendable {
    var id: String
    let title: String
    /// 完整歌曲段 M4A，可直接作为后续的纯音频播放源。
    let fileName: String
    let durationSeconds: Double
    let byteCount: Int64
    /// 超过单次 ASR 限制时单独保留的识别前段。
    let recognitionFileName: String?
    let recognitionDurationSeconds: Double?
    let recognitionByteCount: Int64?
    let isCompleteSong: Bool?
    let createdAt: Date
    let mediaFingerprint: String?
    let audioSHA256: String?
    var lastUsedAt: Date
    var analysisStatus: String
    var matchedLyricsTitle: String?

    var storedByteCount: Int64 { byteCount + (recognitionByteCount ?? 0) }
}

struct BabyPlayerAudioSample: Sendable {
    let playbackURL: URL
    let recognitionURL: URL
    let recognitionDurationSeconds: Double
    let entry: BabyPlayerAudioCacheEntry
}

actor BabyPlayerAudioCache {
    static let shared = BabyPlayerAudioCache()
    static let maximumRecognitionSeconds: Double = 120

    private let fileManager = FileManager.default

    func entries() -> [BabyPlayerAudioCacheEntry] {
        migrateLegacyCacheIfNeeded()
        return loadManifest().filter { fileManager.fileExists(atPath: root().appendingPathComponent($0.fileName).path) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func totalBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.storedByteCount }
    }

    func cachedOrExtract(item: BabyPlayerQueueItem) async throws -> BabyPlayerAudioSample {
        migrateLegacyCacheIfNeeded()
        var manifest = loadManifest()
        let mediaFingerprint = item.lyricsMedia.asrFingerprint
        if let index = manifest.firstIndex(where: {
            $0.id == item.id || $0.mediaFingerprint == mediaFingerprint
        }) {
            let entry = manifest[index]
            let playbackURL = root().appendingPathComponent(entry.fileName)
            let recognitionURL = root().appendingPathComponent(
                entry.recognitionFileName ?? entry.fileName
            )
            if entry.isCompleteSong == true,
               fileManager.fileExists(atPath: playbackURL.path),
               fileManager.fileExists(atPath: recognitionURL.path) {
                manifest[index].id = item.id
                manifest[index].lastUsedAt = Date()
                saveManifest(manifest)
                return BabyPlayerAudioSample(
                    playbackURL: playbackURL,
                    recognitionURL: recognitionURL,
                    recognitionDurationSeconds: entry.recognitionDurationSeconds
                        ?? min(entry.durationSeconds, Self.maximumRecognitionSeconds),
                    entry: manifest[index]
                )
            }
            try? removeFiles(for: entry)
            manifest.remove(at: index)
        }

        let fullDuration = Self.completeSongDuration(for: item.lyricsMedia)
        guard fullDuration >= 1 else { throw BabyPlayerASRError.audioExportFailed }
        let start = max(0, item.lyricsMedia.songStartSeconds ?? 0)

        try fileManager.createDirectory(at: root(), withIntermediateDirectories: true)
        let baseName = safeHash(mediaFingerprint)
        let fileName = "\(baseName)-song.m4a"
        let playbackDestination = root().appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: playbackDestination.path) {
            try fileManager.removeItem(at: playbackDestination)
        }
        let asset = AVURLAsset(url: item.url)
        try await export(
            asset: asset,
            startSeconds: start,
            durationSeconds: fullDuration,
            to: playbackDestination
        )
        let attributes = try fileManager.attributesOfItem(atPath: playbackDestination.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        let recognitionDuration = min(fullDuration, Self.maximumRecognitionSeconds)
        let recognitionFileName: String?
        let recognitionDestination: URL
        let recognitionBytes: Int64?
        if recognitionDuration + 0.001 < fullDuration {
            let sampleName = "\(baseName)-asr.m4a"
            recognitionFileName = sampleName
            recognitionDestination = root().appendingPathComponent(sampleName)
            if fileManager.fileExists(atPath: recognitionDestination.path) {
                try fileManager.removeItem(at: recognitionDestination)
            }
            do {
                try await export(
                    asset: asset,
                    startSeconds: start,
                    durationSeconds: recognitionDuration,
                    to: recognitionDestination
                )
            } catch {
                try? fileManager.removeItem(at: playbackDestination)
                throw error
            }
            let sampleAttributes = try fileManager.attributesOfItem(
                atPath: recognitionDestination.path
            )
            recognitionBytes = (sampleAttributes[.size] as? NSNumber)?.int64Value ?? 0
        } else {
            recognitionFileName = nil
            recognitionDestination = playbackDestination
            recognitionBytes = nil
        }
        let audioSHA256 = try SHA256.hash(
            data: Data(contentsOf: recognitionDestination, options: [.mappedIfSafe])
        )
            .map { String(format: "%02x", $0) }
            .joined()
        let entry = BabyPlayerAudioCacheEntry(
            id: item.id,
            title: item.title,
            fileName: fileName,
            durationSeconds: fullDuration,
            byteCount: bytes,
            recognitionFileName: recognitionFileName,
            recognitionDurationSeconds: recognitionDuration,
            recognitionByteCount: recognitionBytes,
            isCompleteSong: true,
            createdAt: Date(),
            mediaFingerprint: mediaFingerprint,
            audioSHA256: audioSHA256,
            lastUsedAt: Date(),
            analysisStatus: "等待识别",
            matchedLyricsTitle: nil
        )
        manifest.removeAll { $0.id == item.id || $0.mediaFingerprint == mediaFingerprint }
        manifest.append(entry)
        saveManifest(manifest)
        return BabyPlayerAudioSample(
            playbackURL: playbackDestination,
            recognitionURL: recognitionDestination,
            recognitionDurationSeconds: recognitionDuration,
            entry: entry
        )
    }

    nonisolated static func completeSongDuration(for media: LyricsMediaDescriptor) -> Double {
        let totalDuration = media.durationSeconds ?? 0
        let start = max(0, media.songStartSeconds ?? 0)
        let songEnd = min(totalDuration, media.songEndSeconds ?? totalDuration)
        let available = songEnd > start ? songEnd - start : max(0, totalDuration - start)
        return available
    }

    nonisolated static func recognitionDuration(for media: LyricsMediaDescriptor) -> Double {
        min(maximumRecognitionSeconds, completeSongDuration(for: media))
    }

    func markAnalyzed(mediaID: String, matchedTitle: String?) {
        var manifest = loadManifest()
        guard let index = manifest.firstIndex(where: { $0.id == mediaID }) else { return }
        manifest[index].analysisStatus = matchedTitle == nil ? "已识别·待确认" : "已识别"
        manifest[index].matchedLyricsTitle = matchedTitle
        manifest[index].lastUsedAt = Date()
        saveManifest(manifest)
    }

    func delete(mediaID: String) throws {
        var manifest = loadManifest()
        guard let index = manifest.firstIndex(where: { $0.id == mediaID }) else { return }
        try removeFiles(for: manifest[index])
        manifest.remove(at: index)
        saveManifest(manifest)
    }

    func deleteAll() throws {
        let directory = root()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func export(
        asset: AVAsset,
        startSeconds: Double,
        durationSeconds: Double,
        to destination: URL
    ) async throws {
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw BabyPlayerASRError.audioExportFailed }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )
        do {
            try await exporter.export(to: destination, as: .m4a)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }
    }

    private func root() -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BabyPlayer", isDirectory: true)
            .appendingPathComponent("AudioLibrary-v1", isDirectory: true)
    }

    private func legacyRoot() -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BabyPlayerASR", isDirectory: true)
            .appendingPathComponent("Audio-v1", isDirectory: true)
    }

    /// 旧版缓存也先迁入持久目录；下次用到该曲目时再升级为完整歌曲。
    private func migrateLegacyCacheIfNeeded() {
        let legacy = legacyRoot()
        guard !fileManager.fileExists(atPath: root().path),
              fileManager.fileExists(atPath: legacy.path) else { return }
        try? fileManager.createDirectory(
            at: root().deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.moveItem(at: legacy, to: root())
    }

    private func manifestURL() -> URL { root().appendingPathComponent("manifest.json") }

    private func loadManifest() -> [BabyPlayerAudioCacheEntry] {
        guard let data = try? Data(contentsOf: manifestURL()),
              let result = try? JSONDecoder().decode([BabyPlayerAudioCacheEntry].self, from: data) else {
            return []
        }
        return result
    }

    private func saveManifest(_ entries: [BabyPlayerAudioCacheEntry]) {
        try? fileManager.createDirectory(at: root(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL(), options: .atomic)
    }

    private func safeHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func removeFiles(for entry: BabyPlayerAudioCacheEntry) throws {
        let names = Set([entry.fileName, entry.recognitionFileName].compactMap { $0 })
        for name in names {
            let url = root().appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }
}

struct BabyPlayerASRMatchOutcome: Sendable {
    let candidates: [LyricsCandidate]
    let selected: LyricsCandidate?
    let offsetSeconds: Double?
    let message: String
}

actor BabyPlayerASRCoordinator {
    static let shared = BabyPlayerASRCoordinator()
    private var inFlight: [String: Task<BabyPlayerASRMatchOutcome, Error>] = [:]

    func analyze(
        item: BabyPlayerQueueItem,
        candidates: [LyricsCandidate],
        reference: LyricsPlainTextReference?
    ) async throws -> BabyPlayerASRMatchOutcome {
        let fingerprint = item.lyricsMedia.asrFingerprint
        if let existing = inFlight[fingerprint] {
            return try await existing.value
        }
        let task = Task {
            try await Self.performAnalysis(
                item: item,
                candidates: candidates,
                reference: reference,
                fingerprint: fingerprint
            )
        }
        inFlight[fingerprint] = task
        defer { inFlight[fingerprint] = nil }
        return try await task.value
    }

    private static func performAnalysis(
        item: BabyPlayerQueueItem,
        candidates: [LyricsCandidate],
        reference: LyricsPlainTextReference?,
        fingerprint: String
    ) async throws -> BabyPlayerASRMatchOutcome {
        let client = try BabyPlayerASRClient()
        let analysis: BabyPlayerASRAnalysis
        var reusedServerCache = false
        do {
            analysis = try await client.cachedAnalysis(mediaFingerprint: fingerprint)
            reusedServerCache = true
        } catch BabyPlayerASRError.cacheMiss {
            // 缓存查询优先；只有明确未命中后才检查额度、提取并上传。
            let expectedDuration = BabyPlayerAudioCache.recognitionDuration(for: item.lyricsMedia)
            guard expectedDuration >= 1 else { throw BabyPlayerASRError.audioExportFailed }
            let usage = try await client.usage()
            try BabyPlayerASRQuotaPolicy.validate(usage, requestedSeconds: expectedDuration)
            let sample = try await BabyPlayerAudioCache.shared.cachedOrExtract(item: item)
            analysis = try await client.analyze(
                sampleURL: sample.recognitionURL,
                durationSeconds: sample.recognitionDurationSeconds,
                mediaFingerprint: fingerprint
            )
        }
        let result = BabyPlayerLyricsSoundMatcher.match(
            analysis: analysis,
            candidates: candidates,
            reference: reference,
            sampleStartSeconds: item.lyricsMedia.songStartSeconds ?? 0
        )
        let finalResult: BabyPlayerASRMatchOutcome
        do {
            let refined = try await BabyPlayerLyricsRefinerClient().refine(
                analysis: analysis,
                candidates: candidates,
                reference: reference,
                mediaFingerprint: fingerprint
            )
            finalResult = BabyPlayerASRMatchOutcome(
                candidates: [refined] + result.candidates.filter { $0.id != refined.id },
                selected: refined,
                offsetSeconds: item.lyricsMedia.songStartSeconds ?? 0,
                message: "DeepSeek Flash 已校正文案，并保留腾讯 ASR 时间轴"
            )
        } catch BabyPlayerASRError.notConfigured {
            finalResult = result
        } catch {
            finalResult = BabyPlayerASRMatchOutcome(
                candidates: result.candidates,
                selected: result.selected,
                offsetSeconds: result.offsetSeconds,
                message: "\(result.message) · AI 文案校正暂不可用"
            )
        }
        if reusedServerCache {
            // VPS 缓存命中时先立即使用转写，再以低优先级补齐本地完整 M4A。
            // 音频库和识别缓存是两份独立资产，命中不应让本地音频永久缺失。
            Task(priority: .utility) {
                _ = try? await BabyPlayerAudioCache.shared.cachedOrExtract(item: item)
                await BabyPlayerAudioCache.shared.markAnalyzed(
                    mediaID: item.id,
                    matchedTitle: finalResult.selected?.trackName
                )
            }
        } else {
            await BabyPlayerAudioCache.shared.markAnalyzed(
                mediaID: item.id,
                matchedTitle: finalResult.selected?.trackName
            )
        }
        return finalResult
    }
}

enum BabyPlayerLyricsSoundMatcher {
    static func match(
        analysis: BabyPlayerASRAnalysis,
        candidates: [LyricsCandidate],
        reference: LyricsPlainTextReference?,
        sampleStartSeconds: Double,
        preferSoundTimeline: Bool = true
    ) -> BabyPlayerASRMatchOutcome {
        let transcript = analysis.transcript.isEmpty
            ? analysis.segments.map(\.text).joined(separator: " ")
            : analysis.transcript
        let transcriptTokens = tokens(transcript)
        guard transcriptTokens.count >= 3 else {
            return BabyPlayerASRMatchOutcome(
                candidates: candidates,
                selected: nil,
                offsetSeconds: nil,
                message: "声音文字太少，请手动选择歌词"
            )
        }

        var available = candidates
        if let reference,
           !available.contains(where: { $0.id == reference.id }),
           let aligned = alignedReferenceCandidate(
               reference,
               analysis: analysis,
               sampleStartSeconds: sampleStartSeconds
           ) {
            available.append(aligned)
        }
        let scored = available.map { candidate in
            let lyricTokens = tokens(candidate.lines.map(\.text).joined(separator: " "))
            let sound = similarity(transcriptTokens, lyricTokens)
            let metadata = Double(candidate.matchPercentage) / 100
            return (candidate, sound, sound * 0.8 + metadata * 0.2)
        }.sorted {
            if $0.2 == $1.2 {
                return $0.0.persistentIdentifier < $1.0.persistentIdentifier
            }
            return $0.2 > $1.2
        }

        guard let best = scored.first else {
            return BabyPlayerASRMatchOutcome(
                candidates: candidates, selected: nil, offsetSeconds: nil,
                message: "没有可供声音核验的歌词"
            )
        }
        let margin = best.2 - (scored.dropFirst().first?.2 ?? 0)
        let confident = best.1 >= 0.48 && (scored.count == 1 || margin >= 0.08)
        var selected: LyricsCandidate?
        var offset: Double?
        var message: String
        if confident && best.0.providerName == "本地歌本·自动校时" {
            selected = best.0
            offset = sampleStartSeconds
            message = "已用声音时间戳校准本地歌本"
        } else if confident,
                  preferSoundTimeline,
                  let retimed = retimedCandidate(best.0, analysis: analysis) {
            selected = retimed
            offset = sampleStartSeconds
            message = "已忽略网络时间轴，并用声音逐行重新校时"
        } else if confident,
                  !preferSoundTimeline,
                  let estimated = estimatedOffset(
                segments: analysis.segments,
                lines: best.0.lines,
                sampleStartSeconds: sampleStartSeconds
                  ) {
            selected = best.0
            offset = estimated
            message = "声音核验已匹配并校正整体偏移"
        } else if preferSoundTimeline,
                  let direct = directASRCandidate(analysis) {
            selected = direct
            offset = sampleStartSeconds
            message = confident
                ? "歌词文字可匹配但无法可靠逐行对齐，已使用声音识别字幕"
                : "歌词候选不明确，已使用声音识别字幕"
        } else {
            selected = confident ? best.0 : nil
            offset = nil
            message = confident
                ? "声音已确认歌词，但时间轴不足以自动校准"
                : "声音核验结果接近，请家长确认"
        }
        let referenceScore = reference.map { similarity(transcriptTokens, tokens($0.plainLyrics)) }
        let referenceMessage = referenceScore.map { " · 歌本核验 \(Int($0 * 100)) 分" } ?? ""
        var orderedCandidates = scored.map(\.0)
        if let selected,
           !orderedCandidates.contains(where: { $0.persistentIdentifier == selected.persistentIdentifier }) {
            // 重校时版本替代同源的旧 LRC，避免 UI 同时显示两个相同标题。
            orderedCandidates.removeAll { $0.id == selected.id }
            orderedCandidates.insert(selected, at: 0)
        }
        return BabyPlayerASRMatchOutcome(
            candidates: orderedCandidates,
            selected: selected,
            offsetSeconds: offset,
            message: "\(message)\(referenceMessage)"
        )
    }

    private static func retimedCandidate(
        _ candidate: LyricsCandidate,
        analysis: BabyPlayerASRAnalysis
    ) -> LyricsCandidate? {
        let rawLines = candidate.lines.map(\.text)
        guard let timed = retimedLines(rawLines, words: analysis.segments.flatMap(\.words)) else {
            return nil
        }
        return LyricsCandidate(
            id: candidate.id,
            trackName: candidate.trackName,
            artistName: candidate.artistName,
            albumName: candidate.albumName,
            duration: max(analysis.audioDurationSeconds, timed.last?.time ?? 0),
            lines: timed,
            matchScore: candidate.matchScore,
            providerName: "\(candidate.providerName ?? "网络歌词")·声音重校时"
        )
    }

    private static func directASRCandidate(_ analysis: BabyPlayerASRAnalysis) -> LyricsCandidate? {
        let lines = analysis.segments.compactMap { segment -> TimedLyricLine? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimedLyricLine(time: segment.startSeconds, text: text)
        }
        guard !lines.isEmpty else { return nil }
        let raw = lines.map { "\($0.time)|\($0.text)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(raw.utf8))
        let numericID = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return LyricsCandidate(
            id: -1_000_000_000 - Int(numericID),
            trackName: "声音识别字幕",
            artistName: "腾讯 ASR",
            albumName: nil,
            duration: max(analysis.audioDurationSeconds, lines.last?.time ?? 0),
            lines: lines,
            matchScore: 0,
            providerName: "腾讯 ASR·声音时间轴"
        )
    }

    private static func alignedReferenceCandidate(
        _ reference: LyricsPlainTextReference,
        analysis: BabyPlayerASRAnalysis,
        sampleStartSeconds: Double
    ) -> LyricsCandidate? {
        let rawLines = reference.plainLyrics.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let words = analysis.segments.flatMap(\.words)
        guard let timed = retimedLines(rawLines, words: words) else { return nil }
        return LyricsCandidate(
            id: reference.id,
            trackName: reference.title,
            artistName: reference.artist,
            albumName: "本地歌本",
            duration: max(analysis.audioDurationSeconds, timed.last?.time ?? 0),
            lines: timed,
            matchScore: 0,
            providerName: "本地歌本·自动校时"
        )
    }

    private static func retimedLines(
        _ rawLines: [String],
        words: [BabyPlayerASRWord]
    ) -> [TimedLyricLine]? {
        guard rawLines.count >= 2, words.count >= 3 else { return nil }
        var cursor = 0
        var timed: [TimedLyricLine] = []
        for line in rawLines {
            let lineTokens = tokens(line)
            guard !lineTokens.isEmpty, cursor < words.count else { continue }
            var best: (index: Int, length: Int, score: Double)?
            let maximumStart = min(words.count - 1, cursor + 50)
            for start in cursor...maximumStart {
                let minimumLength = max(1, lineTokens.count - 2)
                let maximumLength = min(words.count - start, lineTokens.count + 3)
                guard minimumLength <= maximumLength else { continue }
                for length in minimumLength...maximumLength {
                    let recognized = words[start..<(start + length)].map(\.text).joined(separator: " ")
                    let score = similarity(lineTokens, tokens(recognized))
                    if score > (best?.score ?? 0) { best = (start, length, score) }
                }
            }
            guard let best, best.score >= 0.45 else { continue }
            timed.append(TimedLyricLine(time: words[best.index].startSeconds, text: line))
            cursor = min(words.count, best.index + best.length)
        }
        let recognizedCoverage = Double(cursor) / Double(words.count)
        let lineCoverage = Double(timed.count) / Double(rawLines.count)
        guard timed.count >= 2,
              recognizedCoverage >= 0.55 || lineCoverage >= 0.55 else { return nil }
        return timed
    }

    private static func estimatedOffset(
        segments: [BabyPlayerASRSegment],
        lines: [TimedLyricLine],
        sampleStartSeconds: Double
    ) -> Double? {
        var offsets: [Double] = []
        for segment in segments where !segment.text.isEmpty {
            let segmentTokens = tokens(segment.text)
            let best = lines.map { line in
                (line, similarity(segmentTokens, tokens(line.text)))
            }.max { $0.1 < $1.1 }
            if let best, best.1 >= 0.5 {
                offsets.append(sampleStartSeconds + segment.startSeconds - best.0.time)
            }
        }
        guard offsets.count >= 3 else { return nil }
        let median = offsets.sorted()[offsets.count / 2]
        let deviations = offsets.map { abs($0 - median) }.sorted()
        guard deviations[deviations.count / 2] <= 1.5 else { return nil }
        return median
    }

    private static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func similarity(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let leftWords = Set(lhs)
        let rightWords = Set(rhs)
        // ASR 只覆盖歌曲开头的一段，因此以 ASR 片段为分母，不因完整歌词更长而降分。
        let wordCoverage = Double(leftWords.intersection(rightWords).count)
            / Double(leftWords.count)
        let pairCoverage = ngramCoverage(query: lhs, reference: rhs, size: 2)
        let tripleCoverage = ngramCoverage(query: lhs, reference: rhs, size: 3)
        // 再乘外层 0.8 后，对应设计中的单词 30%、相邻词组 50%。
        return wordCoverage * 0.375 + pairCoverage * 0.375 + tripleCoverage * 0.25
    }

    private static func ngramCoverage(
        query: [String],
        reference: [String],
        size: Int
    ) -> Double {
        guard query.count >= size, reference.count >= size else { return 0 }
        let queryNgrams = Set((0...(query.count - size)).map {
            query[$0..<($0 + size)].joined(separator: "|")
        })
        let referenceNgrams = Set((0...(reference.count - size)).map {
            reference[$0..<($0 + size)].joined(separator: "|")
        })
        guard !queryNgrams.isEmpty else { return 0 }
        return Double(queryNgrams.intersection(referenceNgrams).count)
            / Double(queryNgrams.count)
    }
}

extension LyricsMediaDescriptor {
    var asrFingerprint: String {
        let duration = Int(((durationSeconds ?? 0) * 1_000).rounded())
        let start = Int(((songStartSeconds ?? 0) * 1_000).rounded())
        let end = Int(((songEndSeconds ?? durationSeconds ?? 0) * 1_000).rounded())
        let raw = "babyplayer-audio-v2|\(mediaSourceID ?? id)|\(duration)|\(start)|\(end)"
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

@MainActor
final class BabyPlayerAudioCacheViewModel: ObservableObject {
    @Published private(set) var entries: [BabyPlayerAudioCacheEntry] = []
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var usageText = "读取中…"

    func refresh() {
        Task {
            entries = await BabyPlayerAudioCache.shared.entries()
            totalBytes = await BabyPlayerAudioCache.shared.totalBytes()
            do {
                let usage = try await BabyPlayerASRClient().usage()
                let reserved = usage.reservedSeconds > 0
                    ? " · 处理中 \(formatDuration(usage.reservedSeconds))"
                    : ""
                usageText = "已用 \(formatDuration(usage.usedSeconds)) / \(formatDuration(usage.limitSeconds)) · 剩余 \(formatDuration(usage.remainingSeconds))\(reserved) · \(BabyPlayerASRDateFormatter.display(usage.nextResetAt)) 重置"
            } catch {
                usageText = (error as? LocalizedError)?.errorDescription ?? "暂时不可用"
            }
        }
    }

    func delete(_ entry: BabyPlayerAudioCacheEntry) {
        Task {
            try? await BabyPlayerAudioCache.shared.delete(mediaID: entry.id)
            refresh()
        }
    }

    func deleteAll() {
        Task {
            try? await BabyPlayerAudioCache.shared.deleteAll()
            refresh()
        }
    }

    var totalSizeText: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }

    func createdText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return "\(hours) 小时 \(minutes) 分"
    }

}
