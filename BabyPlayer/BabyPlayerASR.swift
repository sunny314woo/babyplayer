//
// BabyPlayerASR.swift
// Apple TV 提交人工分析任务；Mac 读取原视频、提取音频并调用独立 ASR 代理。
// 当前主要功能：缓存/额度预检、腾讯声音证据、确定性同歌判断、AI 歌词校时与渐进修复。
// 最近修改：2026-08-23 为 Version C 引入全局单调 alignment 和非 raw-ASR 的 AI Lyrics v1。
// 最近修改：2026-08-23 让远程 MP4 先加载音轨再导出，并将片头片尾边界安全裁剪到真实媒体时长。
// 最近修改：2026-08-23 为 tvOS 不能直接导出的 Jellyfin 网络 MP4 增加低优先级临时下载回退。
// 最近修改：2026-08-23 取消完整 M4A 前置与长期音频库，改用可复用的临时 ASR 分段、全局时间戳合并和首段早停。
// 最近修改：2026-08-25 保持 ASR 与 DeepSeek 能独立调用，由播放器将显式 ASR 操作串成自动后续链。
// 最近修改：2026-08-24 本地调试改为提交 Mac 异步任务，不再由 Apple TV 导出和上传整首 M4A。
//

import AVFoundation
import CryptoKit
import Foundation
import OSLog

private let babyPlayerASRLogger = Logger(
    subsystem: "com.wufengyu.BabyPlayer",
    category: "AILyrics"
)

struct BabyPlayerASRWord: Codable, Sendable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
    var voiceActivityScore: Double? = nil
    var voiceActivityCoverage: Double? = nil
    var qualityFlags: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case text
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case voiceActivityScore = "voice_activity_score"
        case voiceActivityCoverage = "voice_activity_coverage"
        case qualityFlags = "quality_flags"
    }

    var isPossibleInstrumentalHallucination: Bool {
        qualityFlags?.contains("possible_instrumental_hallucination") == true
    }
}

struct BabyPlayerASRSegment: Codable, Sendable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
    let words: [BabyPlayerASRWord]
    var voiceActivityDetector: String? = nil
    var voiceActivityScope: String? = nil
    var qualityFlags: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case text, words
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case voiceActivityDetector = "voice_activity_detector"
        case voiceActivityScope = "voice_activity_scope"
        case qualityFlags = "quality_flags"
    }
}

struct BabyPlayerVoiceActivitySummary: Codable, Sendable {
    let status: String
    let detector: String
    let scope: String
    let analyzedWordCount: Int
    let lowActivityWordCount: Int
    let suspiciousWordCount: Int

    enum CodingKeys: String, CodingKey {
        case status, detector, scope
        case analyzedWordCount = "analyzed_word_count"
        case lowActivityWordCount = "low_activity_word_count"
        case suspiciousWordCount = "suspicious_word_count"
    }
}

struct BabyPlayerVoiceWindowPlan: Codable, Sendable {
    let plannerVersion: String
    let plannerStatus: String
    let fallbackReason: String?
    let mediaDurationSeconds: Double?
    let analysisDurationSeconds: Double?
    let rawVocalSeconds: Double
    let plannedASRSeconds: Double
    let savedASRSeconds: Double
    let asrWindowCount: Int
    let smartIntroEndSeconds: Double?
    let smartOutroStartSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case plannerVersion = "planner_version"
        case plannerStatus = "planner_status"
        case fallbackReason = "fallback_reason"
        case mediaDurationSeconds = "media_duration_seconds"
        case analysisDurationSeconds = "analysis_duration_seconds"
        case rawVocalSeconds = "raw_vocal_seconds"
        case plannedASRSeconds = "planned_asr_seconds"
        case savedASRSeconds = "saved_asr_seconds"
        case asrWindowCount = "asr_window_count"
        case smartIntroEndSeconds = "smart_intro_end_seconds"
        case smartOutroStartSeconds = "smart_outro_start_seconds"
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
    let audioContentHash: String?
    let mediaContentHash: String?
    var voiceActivity: BabyPlayerVoiceActivitySummary? = nil
    var voiceWindowPlan: BabyPlayerVoiceWindowPlan? = nil

    enum CodingKeys: String, CodingKey {
        case status, provider, transcript, segments
        case cacheHit = "cache_hit"
        case engineType = "engine_type"
        case audioDurationSeconds = "audio_duration_seconds"
        case monthlyUsedSeconds = "monthly_used_seconds"
        case monthlyReservedSeconds = "monthly_reserved_seconds"
        case monthlyLimitSeconds = "monthly_limit_seconds"
        case audioContentHash = "audio_sha256"
        case mediaContentHash = "media_content_sha256"
        case voiceActivity = "voice_activity"
        case voiceWindowPlan = "voice_window_plan"
    }

    /// 返回可用于版本关联的 ASR 证据哈希；源文件相同但词时间线改变时也必须变化。
    var evidenceHash: String {
        let words = segments.flatMap(\.words).map {
            let activity = $0.voiceActivityScore.map { String(format: "%.4f", $0) } ?? ""
            let flags = ($0.qualityFlags ?? []).sorted().joined(separator: ",")
            return "\($0.text)|\(String(format: "%.3f", $0.startSeconds))|\(String(format: "%.3f", $0.endSeconds))|\(activity)|\(flags)"
        }.joined(separator: "\n")
        let raw = [
            "babyplayer-asr-evidence-v2",
            mediaContentHash ?? "",
            audioContentHash ?? "",
            transcript,
            words
        ].joined(separator: "|")
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 将腾讯原始 segment 转为可人工采用的测试字幕；长段按词级时间拆成电视可读短行。
    func lyricsCandidate(title: String, mediaFingerprint: String) throws -> LyricsCandidate {
        let lines = segments.flatMap(readableLines(for:))
        guard !lines.isEmpty else { throw BabyPlayerASRError.server("ASR 未返回可显示的分段歌词") }
        let digest = SHA256.hash(data: Data("asr:\(mediaFingerprint):\(evidenceHash)".utf8))
        let numericID = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return LyricsCandidate(
            id: -1_600_000_000 - Int(numericID % 200_000_000),
            trackName: title,
            artistName: "",
            albumName: nil,
            duration: max(audioDurationSeconds, lines.last?.endTime ?? 0),
            lines: lines,
            matchScore: 0,
            providerName: "腾讯 ASR",
            identityAnchor: "asr:\(mediaFingerprint):\(evidenceHash)"
        )
    }

    /// 腾讯偶尔把整分钟识别为一个 segment；按停顿、时长、字符和词数拆成单行短句。
    private func readableLines(for segment: BabyPlayerASRSegment) -> [TimedLyricLine] {
        let providerWords = segment.words.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.endSeconds >= $0.startSeconds
                && !$0.isPossibleInstrumentalHallucination
        }
        let words: [BabyPlayerASRWord]
        if providerWords.isEmpty {
            words = syntheticWords(for: segment)
        } else {
            words = providerWords.flatMap(expandedWords(for:))
        }
        guard !words.isEmpty else { return [] }

        let maximumWordsPerLine = 6
        let maximumCharactersPerLine = 30
        let maximumLineDuration = 3.2
        let pauseBoundary = 0.65
        var result: [TimedLyricLine] = []
        var current: [BabyPlayerASRWord] = []

        func appendCurrentLine() {
            guard let first = current.first, let last = current.last else { return }
            result.append(TimedLyricLine(
                time: first.startSeconds,
                text: current.map(\.text).joined(separator: " "),
                endTime: last.endSeconds
            ))
            current.removeAll(keepingCapacity: true)
        }

        for word in words {
            if let first = current.first, let previous = current.last,
               current.count >= maximumWordsPerLine
                || (current.map(\.text).joined(separator: " ") + " " + word.text).count
                    > maximumCharactersPerLine
                || word.startSeconds - previous.endSeconds >= pauseBoundary
                || word.endSeconds - first.startSeconds > maximumLineDuration
                || isStrongTextBoundary(previous.text) {
                appendCurrentLine()
            }
            current.append(word)
        }
        appendCurrentLine()
        return result
    }

    /// 腾讯极端情况会把多个词塞进一个 word；在其时间内等分，避免单个“词”占满屏幕。
    private func expandedWords(for word: BabyPlayerASRWord) -> [BabyPlayerASRWord] {
        let tokens = word.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count > 1, word.endSeconds > word.startSeconds else { return [word] }
        let duration = word.endSeconds - word.startSeconds
        return tokens.enumerated().map { index, token in
            let start = word.startSeconds + duration * Double(index) / Double(tokens.count)
            let end = word.startSeconds + duration * Double(index + 1) / Double(tokens.count)
            return BabyPlayerASRWord(text: token, startSeconds: start, endSeconds: end)
        }
    }

    /// 没有 word timeline 时不再返回整个长 segment，而是把 segment 文本均匀分配到它的时间范围。
    private func syntheticWords(for segment: BabyPlayerASRSegment) -> [BabyPlayerASRWord] {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, segment.endSeconds > segment.startSeconds else { return [] }
        var tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.count == 1, text.count > 12 {
            tokens = []
            var token = ""
            for character in text {
                token.append(character)
                if token.count >= 8 {
                    tokens.append(token)
                    token = ""
                }
            }
            if !token.isEmpty { tokens.append(token) }
        }
        guard !tokens.isEmpty else { return [] }
        let duration = segment.endSeconds - segment.startSeconds
        return tokens.enumerated().map { index, token in
            let start = segment.startSeconds + duration * Double(index) / Double(tokens.count)
            let end = segment.startSeconds + duration * Double(index + 1) / Double(tokens.count)
            return BabyPlayerASRWord(text: token, startSeconds: start, endSeconds: end)
        }
    }

    private func isStrongTextBoundary(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?;:。！？；：".contains(last)
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

// 【MODIFIED】本地任务请求只包含媒体身份和 Mac 路径，不包含音频二进制。
private struct BabyPlayerLocalAnalysisJobRequest: Encodable {
    let mediaFingerprint: String
    let mediaTitle: String
    let mediaPath: String
    let durationSeconds: Double
    let songStartSeconds: Double
    let songEndSeconds: Double?
    let forceRefresh: Bool

    enum CodingKeys: String, CodingKey {
        case mediaFingerprint = "media_fingerprint"
        case mediaTitle = "media_title"
        case mediaPath = "media_path"
        case durationSeconds = "duration_seconds"
        case songStartSeconds = "song_start_seconds"
        case songEndSeconds = "song_end_seconds"
        case forceRefresh = "force_refresh"
    }
}

struct BabyPlayerLocalAnalysisJob: Decodable, Sendable {
    let jobID: String
    let status: String
    let message: String?
    let errorCode: String?
    let analysis: BabyPlayerASRAnalysis?

    enum CodingKeys: String, CodingKey {
        case status, message, analysis
        case jobID = "job_id"
        case errorCode = "error_code"
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

// 【MODIFIED】单曲循环下可恢复错误使用集中的封顶退避，不影响播放线程。
enum BabyPlayerAIAnalysisRetryPolicy {
    static let delaysSeconds: [TimeInterval] = [2, 5, 12, 30, 60]

    /// 计算退避时间；输入为已连续失败次数，输出秒数，不修改状态。
    static func delay(afterFailureCount count: Int) -> TimeInterval {
        guard let last = delaysSeconds.last else { return 60 }
        guard count > 0 else { return delaysSeconds.first ?? last }
        return delaysSeconds[min(count - 1, delaysSeconds.count - 1)]
    }

    /// 判断错误是否适合后台重试；输入为 Error，输出布尔值，不修改 UI/repository。
    static func shouldRetry(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let asrError = error as? BabyPlayerASRError else { return false }
        switch asrError {
        case .audioExportFailed, .invalidResponse, .server:
            return true
        case .notConfigured, .cacheMiss, .monthlyLimit:
            return false
        }
    }
}

struct BabyPlayerAudioExportWindow: Equatable, Sendable {
    let startSeconds: Double
    let durationSeconds: Double
}

// 【MODIFIED】片头/片尾只是首选歌曲边界，不能因元数据越界让 AI 歌词整体不可用。
enum BabyPlayerAudioExportPolicy {
    static let minimumUsableDuration: Double = 1

    /// 把建议片段裁剪到真实资产时长；输入起点、时长和资产时长，输出可选安全窗口，不修改状态。
    static func clampedWindow(
        startSeconds: Double,
        durationSeconds: Double,
        assetDurationSeconds: Double
    ) -> BabyPlayerAudioExportWindow? {
        guard assetDurationSeconds.isFinite,
              assetDurationSeconds >= minimumUsableDuration else { return nil }
        let requestedStart = max(0, startSeconds)
        let safeStart = requestedStart <= assetDurationSeconds - minimumUsableDuration
            ? requestedStart
            : 0
        let available = assetDurationSeconds - safeStart
        let safeDuration = min(max(0, durationSeconds), available)
        guard safeDuration >= minimumUsableDuration else { return nil }
        return BabyPlayerAudioExportWindow(
            startSeconds: safeStart,
            durationSeconds: safeDuration
        )
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

// 【MODIFIED】ASR、旧 refine 与 D3 共用同一 URL 校验；Release 只允许 HTTPS，Debug 的 HTTP 只允许 Mac 局域网。
struct BabyPlayerServiceConfiguration {
    let baseURL: URL
    let apiToken: String

    static func load() throws -> BabyPlayerServiceConfiguration {
        let rawURL = Bundle.main.object(forInfoDictionaryKey: "BabyPlayerASRBaseURL") as? String ?? ""
        let token = Bundle.main.object(forInfoDictionaryKey: "BabyPlayerASRAPIToken") as? String ?? ""
        guard !rawURL.isEmpty, !token.isEmpty,
              !rawURL.uppercased().contains("XX_"),
              !token.uppercased().hasPrefix("XX_"),
              let url = URL(string: rawURL), isAllowed(url) else {
            throw BabyPlayerASRError.notConfigured
        }
        return BabyPlayerServiceConfiguration(baseURL: url, apiToken: token)
    }

    /// 校验服务地址；输入 URL，输出是否可用，不读写配置或网络。
    static func isAllowed(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
        #else
        return false
        #endif
    }

    /// 本地明文地址只存在于 Debug，代表由 Mac 直接读取媒体的开发链路。
    var usesMacLocalAnalysisJobs: Bool {
        #if DEBUG
        return baseURL.scheme?.lowercased() == "http"
        #else
        return false
        #endif
    }
}

struct BabyPlayerASRClient {
    private let configuration: BabyPlayerServiceConfiguration
    private let session: URLSession

    init(session: URLSession = .shared) throws {
        configuration = try .load()
        self.session = session
    }

    /// 为本地 mock 测试注入服务地址；输入为 base URL、非生产 token 和 URLSession，输出 client，不访问网络。
    // 【MODIFIED】真实 App 仍只使用 Bundle 配置；测试可证明 multipart `/analyze` 已具备发送条件。
    init(baseURL: URL, apiToken: String, session: URLSession) {
        configuration = BabyPlayerServiceConfiguration(baseURL: baseURL, apiToken: apiToken)
        self.session = session
    }

    var usesMacLocalAnalysisJobs: Bool {
        configuration.usesMacLocalAnalysisJobs
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

    /// 向 Mac 提交轻量本地分析任务；输入不含音频，返回立即可轮询的任务状态。
    // 【MODIFIED】本地开发主链路，Apple TV 不再生成或上传 M4A。
    func submitLocalAnalysis(
        mediaPath: String,
        media: LyricsMediaDescriptor,
        mediaFingerprint: String,
        mediaTitle: String,
        forceRefresh: Bool
    ) async throws -> BabyPlayerLocalAnalysisJob {
        guard let duration = media.durationSeconds, duration > 0 else {
            throw BabyPlayerASRError.server("缺少媒体时长，Mac 无法开始分析")
        }
        let payload = BabyPlayerLocalAnalysisJobRequest(
            mediaFingerprint: mediaFingerprint,
            mediaTitle: mediaTitle,
            mediaPath: mediaPath,
            durationSeconds: duration,
            songStartSeconds: max(0, media.songStartSeconds ?? 0),
            songEndSeconds: media.songEndSeconds,
            forceRefresh: forceRefresh
        )
        var request = authenticatedRequest(
            url: configuration.baseURL.appendingPathComponent("local-analysis/jobs")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        return try decode(BabyPlayerLocalAnalysisJob.self, data: data, response: response)
    }

    /// 读取一次 Mac 任务状态；短请求不会等待整首识别完成。
    func localAnalysisJob(id: String) async throws -> BabyPlayerLocalAnalysisJob {
        var request = authenticatedRequest(
            url: configuration.baseURL
                .appendingPathComponent("local-analysis/jobs")
                .appendingPathComponent(id)
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        return try decode(BabyPlayerLocalAnalysisJob.self, data: data, response: response)
    }

    func analyze(
        sampleURL: URL,
        durationSeconds: Double,
        mediaFingerprint: String,
        mediaTitle: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> BabyPlayerASRAnalysis {
        let audio = try Data(contentsOf: sampleURL, options: [.mappedIfSafe])
        let boundary = "BabyPlayerBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        appendField("operation_id", UUID().uuidString, boundary: boundary, to: &body)
        appendField("media_fingerprint", mediaFingerprint, boundary: boundary, to: &body)
        appendField("media_title", mediaTitle ?? "", boundary: boundary, to: &body)
        appendField("duration_seconds", String(format: "%.3f", durationSeconds), boundary: boundary, to: &body)
        appendField("voice_format", "m4a", boundary: boundary, to: &body)
        appendField("force_refresh", forceRefresh ? "true" : "false", boundary: boundary, to: &body)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"sample.m4a\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n")

        var request = authenticatedRequest(url: configuration.baseURL.appendingPathComponent("analyze"))
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: body)
        return try decode(BabyPlayerASRAnalysis.self, data: data, response: response)
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
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

// 【MODIFIED】ASR 只准备短命分段；它不代表播放器缓存，也不会成为长期离线音频资产。
struct BabyPlayerASRAudioSegment: Equatable, Sendable {
    let index: Int
    let startSeconds: Double
    let durationSeconds: Double

    var endSeconds: Double { startSeconds + durationSeconds }
    var isTemporary: Bool { true }

    /// 生成服务端 segment cache key；输入为媒体 fingerprint，输出稳定 SHA256，不修改状态。
    func fingerprint(mediaFingerprint: String) -> String {
        let startMilliseconds = Int((startSeconds * 1_000).rounded())
        let durationMilliseconds = Int((durationSeconds * 1_000).rounded())
        let raw = "babyplayer-asr-segment-v1|\(mediaFingerprint)|\(index)|\(startMilliseconds)|\(durationMilliseconds)"
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// 【MODIFIED】分段长度与 overlap 只在这里定义，后续可按真实儿歌数据统一调整。
enum BabyPlayerASRSegmentPolicy {
    static let durationSeconds: Double = 60
    static let overlapSeconds: Double = 3
    static let minimumUsableDurationSeconds: Double = 1
    static var advanceSeconds: Double { durationSeconds - overlapSeconds }

    /// 计算歌曲在源媒体中的安全窗口；输入为媒体描述，输出起点与歌曲时长，不修改状态。
    static func songWindow(for media: LyricsMediaDescriptor) -> BabyPlayerAudioExportWindow? {
        BabyPlayerTemporaryASRAudioPolicy.songWindow(for: media)
    }

    /// 为媒体建立歌曲相对分段；输入为媒体描述，输出按 index 排序的临时 segment，不修改状态。
    static func segments(for media: LyricsMediaDescriptor) -> [BabyPlayerASRAudioSegment] {
        guard let window = songWindow(for: media) else { return [] }
        return segments(forSongDuration: window.durationSeconds)
    }

    /// 为歌曲时长建立连续覆盖计划；输入为秒数，输出含固定 overlap 的 segment，不修改状态。
    static func segments(forSongDuration songDuration: Double) -> [BabyPlayerASRAudioSegment] {
        guard songDuration >= minimumUsableDurationSeconds,
              durationSeconds > overlapSeconds,
              advanceSeconds > 0 else { return [] }
        var result: [BabyPlayerASRAudioSegment] = []
        var start: Double = 0
        var index = 0
        while start < songDuration {
            let duration = min(durationSeconds, songDuration - start)
            guard duration >= minimumUsableDurationSeconds else { break }
            result.append(BabyPlayerASRAudioSegment(
                index: index,
                startSeconds: start,
                durationSeconds: duration
            ))
            if start + duration >= songDuration { break }
            start += advanceSeconds
            index += 1
        }
        return result
    }
}

// 【MODIFIED】MVP 只生成一个短命的整首 M4A；此策略不分片、不 overlap，也不建立音频库。
enum BabyPlayerTemporaryASRAudioPolicy {
    /// 计算整首 ASR 音频窗口；输入为 Jellyfin 媒体描述，输出安全的片头后/片尾前范围，不修改状态。
    static func songWindow(for media: LyricsMediaDescriptor) -> BabyPlayerAudioExportWindow? {
        let totalDuration = media.durationSeconds ?? 0
        guard totalDuration >= BabyPlayerAudioExportPolicy.minimumUsableDuration else { return nil }
        let requestedStart = max(0, media.songStartSeconds ?? 0)
        let safeStart = requestedStart
            <= totalDuration - BabyPlayerAudioExportPolicy.minimumUsableDuration
            ? requestedStart
            : 0
        let requestedEnd = min(totalDuration, media.songEndSeconds ?? totalDuration)
        let safeEnd = requestedEnd > safeStart ? requestedEnd : totalDuration
        let duration = safeEnd - safeStart
        guard duration >= BabyPlayerAudioExportPolicy.minimumUsableDuration else { return nil }
        return BabyPlayerAudioExportWindow(startSeconds: safeStart, durationSeconds: duration)
    }
}

struct BabyPlayerASRSegmentResult: Sendable {
    let segment: BabyPlayerASRAudioSegment
    let analysis: BabyPlayerASRAnalysis
}

// 【MODIFIED】Tencent 分段局部 timestamp 在本地转换为歌曲全局 timestamp，并在 overlap 内确定性去重。
enum BabyPlayerASRSegmentMerger {
    private struct IndexedWord {
        let segment: BabyPlayerASRAudioSegment
        let word: BabyPlayerASRWord
        let localOrder: Int
    }

    /// 合并分段分析；输入为按任意顺序到达的 segment result，输出单调、去重的完整 ASR 证据，不修改状态。
    static func merge(_ results: [BabyPlayerASRSegmentResult]) -> BabyPlayerASRAnalysis {
        precondition(!results.isEmpty, "At least one ASR segment result is required")
        let sortedResults = results.sorted { $0.segment.index < $1.segment.index }
        var accepted: [IndexedWord] = []

        for result in sortedResults {
            let globalWords = result.analysis.segments.flatMap(\.words).enumerated().map { order, word in
                IndexedWord(
                    segment: result.segment,
                    word: BabyPlayerASRWord(
                        text: word.text,
                        startSeconds: result.segment.startSeconds + word.startSeconds,
                        endSeconds: result.segment.startSeconds + word.endSeconds
                    ),
                    localOrder: order
                )
            }
            for indexed in globalWords {
                let isInsideLeadingOverlap = indexed.segment.index > 0
                    && indexed.word.startSeconds
                        <= indexed.segment.startSeconds + BabyPlayerASRSegmentPolicy.overlapSeconds
                let isDuplicate = isInsideLeadingOverlap && accepted.contains { existing in
                    normalize(existing.word.text) == normalize(indexed.word.text)
                        && abs(existing.word.startSeconds - indexed.word.startSeconds)
                            <= BabyPlayerASRSegmentPolicy.overlapSeconds
                }
                if !isDuplicate {
                    accepted.append(indexed)
                }
            }
        }

        accepted.sort {
            if $0.word.startSeconds != $1.word.startSeconds {
                return $0.word.startSeconds < $1.word.startSeconds
            }
            if $0.segment.index != $1.segment.index {
                return $0.segment.index < $1.segment.index
            }
            return $0.localOrder < $1.localOrder
        }
        let words = accepted.map(\.word)
        let shiftedSegmentBounds = sortedResults.flatMap { result in
            result.analysis.segments.map { segment in
                (
                    result.segment.startSeconds + segment.startSeconds,
                    result.segment.startSeconds + segment.endSeconds
                )
            }
        }
        let start = words.first?.startSeconds ?? shiftedSegmentBounds.map(\.0).min() ?? 0
        let end = words.last?.endSeconds ?? shiftedSegmentBounds.map(\.1).max() ?? start
        let transcript = words.isEmpty
            ? sortedResults.map(\.analysis.transcript).filter { !$0.isEmpty }.joined(separator: " ")
            : words.map(\.text).joined(separator: " ")
        let last = sortedResults.last!.analysis
        return BabyPlayerASRAnalysis(
            status: last.status,
            cacheHit: sortedResults.allSatisfy(\.analysis.cacheHit),
            provider: last.provider,
            engineType: last.engineType,
            audioDurationSeconds: sortedResults.map(\.segment.endSeconds).max() ?? end,
            transcript: transcript,
            segments: [BabyPlayerASRSegment(
                text: transcript,
                startSeconds: start,
                endSeconds: end,
                words: words
            )],
            monthlyUsedSeconds: sortedResults.map(\.analysis.monthlyUsedSeconds).max() ?? 0,
            monthlyReservedSeconds: last.monthlyReservedSeconds,
            monthlyLimitSeconds: last.monthlyLimitSeconds,
            audioContentHash: nil,
            mediaContentHash: nil
        )
    }

    /// 规范化 overlap 比较文本；输入为单词，输出小写字母数字序列，不修改状态。
    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}

// 【MODIFIED】第一段只有在内容证据明确不相干时早停；证据不足不会被误判成 mismatch。
enum BabyPlayerASRFirstSegmentPolicy {
    private static let clearlyMismatchedConfidence = 0.30
    private static let clearlyMismatchedContentEvidence = 0.18

    /// 判断是否继续其余 segment；输入为第一段最佳同歌证据，输出继续与否，不修改状态。
    static func shouldContinue(after evidence: BabyPlayerSameSongEvidence?) -> Bool {
        guard let evidence else { return true }
        let strongestContent = max(
            evidence.normalizedTextSimilarity,
            evidence.orderedTokenSimilarity,
            evidence.asrCoverage
        )
        return !(evidence.sameSongConfidence < clearlyMismatchedConfidence
            && strongestContent < clearlyMismatchedContentEvidence)
    }
}

struct BabyPlayerPreparedASRSegment: Sendable {
    let segment: BabyPlayerASRAudioSegment
    let fileURL: URL
    let generatedDurationSeconds: Double
    let fileSize: Int64
}

// 【MODIFIED】媒体源无关的临时分段提取器；只理解可访问 AVAsset，不保存完整歌曲副本。
actor BabyPlayerASRAudioSegmentPreparer {
    static let shared = BabyPlayerASRAudioSegmentPreparer()
    private let fileManager = FileManager.default

    /// 生成单个临时整首 M4A；输入为当前 Jellyfin 队列媒体，输出临时音频元数据，不分片、不持久化。
    // 【MODIFIED】MVP 复用已验证的导出器，但只提交一个覆盖整首歌曲窗口的工作单元。
    func prepareCompleteSong(item: BabyPlayerQueueItem) async throws -> BabyPlayerPreparedASRSegment {
        guard let window = BabyPlayerTemporaryASRAudioPolicy.songWindow(for: item.lyricsMedia) else {
            throw BabyPlayerASRError.audioExportFailed
        }
        return try await prepare(
            item: item,
            segment: BabyPlayerASRAudioSegment(
                index: 0,
                startSeconds: 0,
                durationSeconds: window.durationSeconds
            )
        )
    }

    /// 生成一个临时 M4A segment；输入为队列媒体和分段，输出临时文件元数据，会修改临时目录但不修改 repository/UI。
    func prepare(
        item: BabyPlayerQueueItem,
        segment: BabyPlayerASRAudioSegment
    ) async throws -> BabyPlayerPreparedASRSegment {
        try Task.checkCancellation()
        guard let songWindow = BabyPlayerASRSegmentPolicy.songWindow(for: item.lyricsMedia) else {
            throw BabyPlayerASRError.audioExportFailed
        }
        let sourceStart = songWindow.startSeconds + segment.startSeconds
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("BabyPlayer-ASR-Segments", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory
            .appendingPathComponent("segment-\(segment.index)-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        babyPlayerASRLogger.info(
            "Segment preparation start index=\(segment.index, privacy: .public) start=\(segment.startSeconds, privacy: .public) intendedDuration=\(segment.durationSeconds, privacy: .public)"
        )
        do {
            let asset = AVURLAsset(url: item.url)
            babyPlayerASRLogger.info(
                "Remote AVAsset extraction start index=\(segment.index, privacy: .public)"
            )
            do {
                try await export(
                    asset: asset,
                    sourceStartSeconds: sourceStart,
                    durationSeconds: segment.durationSeconds,
                    to: destination
                )
            } catch {
                try Task.checkCancellation()
                let directError = error as NSError
                babyPlayerASRLogger.error(
                    "Direct AVAsset extraction failed index=\(segment.index, privacy: .public) domain=\(directError.domain, privacy: .public) code=\(directError.code, privacy: .public)"
                )
                if item.url.isFileURL {
                    babyPlayerASRLogger.info(
                        "Temporary audio fallback start index=\(segment.index, privacy: .public) mode=local-audio-composition"
                    )
                    try await exportThroughAudioComposition(
                        asset: asset,
                        sourceStartSeconds: sourceStart,
                        durationSeconds: segment.durationSeconds,
                        to: destination
                    )
                } else {
                    // Jellyfin 的远程 fragmented MP4 在 tvOS 上可能无法被 exporter 随机读取；只在失败后下载短命源文件。
                    babyPlayerASRLogger.info(
                        "Temporary audio fallback start index=\(segment.index, privacy: .public) mode=ephemeral-source-download"
                    )
                    let downloadedMedia = try await downloadRemoteMediaForExtraction(
                        from: item.url
                    )
                    defer { try? fileManager.removeItem(at: downloadedMedia) }
                    try Task.checkCancellation()
                    let localAsset = AVURLAsset(url: downloadedMedia)
                    do {
                        try await export(
                            asset: localAsset,
                            sourceStartSeconds: sourceStart,
                            durationSeconds: segment.durationSeconds,
                            to: destination
                        )
                    } catch {
                        babyPlayerASRLogger.info(
                            "Temporary audio fallback start index=\(segment.index, privacy: .public) mode=downloaded-audio-composition"
                        )
                        try await exportThroughAudioComposition(
                            asset: localAsset,
                            sourceStartSeconds: sourceStart,
                            durationSeconds: segment.durationSeconds,
                            to: destination
                        )
                    }
                }
            }
            try Task.checkCancellation()
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let generatedDuration = try await AVURLAsset(url: destination).load(.duration).seconds
            babyPlayerASRLogger.info(
                "Segment extraction completed index=\(segment.index, privacy: .public) generatedDuration=\(generatedDuration, privacy: .public) fileSize=\(bytes, privacy: .public)"
            )
            return BabyPlayerPreparedASRSegment(
                segment: segment,
                fileURL: destination,
                generatedDurationSeconds: generatedDuration,
                fileSize: bytes
            )
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
            babyPlayerASRLogger.notice(
                "Segment task cancelled index=\(segment.index, privacy: .public)"
            )
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: destination)
            let nsError = error as NSError
            babyPlayerASRLogger.error(
                "Segment extraction failed index=\(segment.index, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            throw BabyPlayerASRError.audioExportFailed
        }
    }

    /// 删除已上传的临时 segment；输入为 prepared segment，无输出，会修改临时目录。
    func remove(_ prepared: BabyPlayerPreparedASRSegment) {
        try? fileManager.removeItem(at: prepared.fileURL)
    }

    /// 下载仅供本次整首音频提取的源媒体；输入为已认证 Jellyfin URL，输出临时 URL，会在导出结束前删除。
    private func downloadRemoteMediaForExtraction(from sourceURL: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (temporaryURL, response) = try await session.download(from: sourceURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  fileManager.fileExists(atPath: temporaryURL.path) else {
                throw BabyPlayerASRError.audioExportFailed
            }
            try Task.checkCancellation()
            let fileExtension = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
            let stableURL = fileManager.temporaryDirectory
                .appendingPathComponent("BabyPlayer-ASR-Source-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            try fileManager.moveItem(at: temporaryURL, to: stableURL)
            babyPlayerASRLogger.info("Ephemeral Jellyfin source download completed")
            return stableURL
        } catch is CancellationError {
            babyPlayerASRLogger.notice("Ephemeral Jellyfin source download cancelled")
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            babyPlayerASRLogger.error(
                "Ephemeral Jellyfin source download failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            throw BabyPlayerASRError.audioExportFailed
        }
    }

    /// 直接从可访问媒体导出指定时间段；输入为 AVAsset、源时间范围和目标 URL，无输出，会创建临时 M4A。
    private func export(
        asset: AVAsset,
        sourceStartSeconds: Double,
        durationSeconds: Double,
        to destination: URL
    ) async throws {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let loadedDuration = try await asset.load(.duration).seconds
        guard !audioTracks.isEmpty,
              let window = BabyPlayerAudioExportPolicy.clampedWindow(
                startSeconds: sourceStartSeconds,
                durationSeconds: durationSeconds,
                assetDurationSeconds: loadedDuration
              ),
              let exporter = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
              ) else {
            throw BabyPlayerASRError.audioExportFailed
        }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: window.startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: window.durationSeconds, preferredTimescale: 600)
        )
        try await exporter.export(to: destination, as: .m4a)
    }

    /// 用音频 composition 重试同一短时间段；输入为源 AVAsset、时间范围和目标 URL，无输出，会替换失败的临时文件。
    private func exportThroughAudioComposition(
        asset: AVAsset,
        sourceStartSeconds: Double,
        durationSeconds: Double,
        to destination: URL
    ) async throws {
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw BabyPlayerASRError.audioExportFailed
        }
        let loadedDuration = try await asset.load(.duration).seconds
        guard let window = BabyPlayerAudioExportPolicy.clampedWindow(
            startSeconds: sourceStartSeconds,
            durationSeconds: durationSeconds,
            assetDurationSeconds: loadedDuration
        ) else { throw BabyPlayerASRError.audioExportFailed }
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw BabyPlayerASRError.audioExportFailed }
        let sourceRange = CMTimeRange(
            start: CMTime(seconds: window.startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: window.durationSeconds, preferredTimescale: 600)
        )
        try compositionTrack.insertTimeRange(sourceRange, of: audioTrack, at: .zero)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw BabyPlayerASRError.audioExportFailed }
        try await exporter.export(to: destination, as: .m4a)
    }
}

// 【MODIFIED】2026-08-23 冻结：完整歌曲 M4A 音频库已取消。保留历史实现仅供迁移审计，禁止参与编译或被 UI 调用。
#if false
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
        var asset = AVURLAsset(url: item.url)
        var temporaryMediaURL: URL?
        defer {
            if let temporaryMediaURL {
                try? fileManager.removeItem(at: temporaryMediaURL)
            }
        }
        do {
            try await export(
                asset: asset,
                startSeconds: start,
                durationSeconds: fullDuration,
                to: playbackDestination
            )
        } catch BabyPlayerASRError.audioExportFailed where !item.url.isFileURL {
            // 【MODIFIED】AVPlayer 仍使用原网络 URL 播放；只有后台提取改用短命临时文件。
            let downloadedURL = try await downloadRemoteMediaForExtraction(from: item.url)
            temporaryMediaURL = downloadedURL
            asset = AVURLAsset(url: downloadedURL)
            try await export(
                asset: asset,
                startSeconds: start,
                durationSeconds: fullDuration,
                to: playbackDestination
            )
        }
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
        // 【MODIFIED】越界的片头边界回退为 0，不让分析因跳过设置而直接作废。
        let requestedStart = max(0, media.songStartSeconds ?? 0)
        let start = requestedStart <= totalDuration - BabyPlayerAudioExportPolicy.minimumUsableDuration
            ? requestedStart
            : 0
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
        do {
            // 【MODIFIED】远程 Jellyfin MP4 在创建 exporter 前必须先加载音轨与真实时长。
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let loadedDuration = try await asset.load(.duration).seconds
            guard !audioTracks.isEmpty,
                  let window = BabyPlayerAudioExportPolicy.clampedWindow(
                    startSeconds: startSeconds,
                    durationSeconds: durationSeconds,
                    assetDurationSeconds: loadedDuration
                  ),
                  let exporter = AVAssetExportSession(
                    asset: asset,
                    presetName: AVAssetExportPresetAppleM4A
                  ) else {
                throw BabyPlayerASRError.audioExportFailed
            }
            exporter.timeRange = CMTimeRange(
                start: CMTime(seconds: window.startSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: window.durationSeconds, preferredTimescale: 600)
            )
            try await exporter.export(to: destination, as: .m4a)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            let nsError = error as NSError
            babyPlayerASRLogger.error(
                "Audio export failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            throw BabyPlayerASRError.audioExportFailed
        }
    }

    // 【MODIFIED】仅当 AVAssetExportSession 无法直接读取远程 MP4 时使用低优先级下载回退。
    /// 下载用于音频提取的临时媒体；输入为已认证 Jellyfin URL，输出系统临时 URL，会使用网络但不修改 UI/repository。
    private func downloadRemoteMediaForExtraction(from sourceURL: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.networkServiceType = .background
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (temporaryURL, response) = try await session.download(from: sourceURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  fileManager.fileExists(atPath: temporaryURL.path) else {
                throw BabyPlayerASRError.audioExportFailed
            }
            // 【MODIFIED】URLSession 的 download URL 只在回调生命期可靠，先移到本 App 的临时目录再返回。
            let fileExtension = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
            let stableTemporaryURL = fileManager.temporaryDirectory
                .appendingPathComponent("BabyPlayer-ASR-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            try fileManager.moveItem(at: temporaryURL, to: stableTemporaryURL)
            return stableTemporaryURL
        } catch {
            let nsError = error as NSError
            babyPlayerASRLogger.error(
                "Temporary media download failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            throw BabyPlayerASRError.audioExportFailed
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
#endif

// 【MODIFIED】对外携带集中计算的同歌证据，供受限 DeepSeek repair 请求使用。
struct BabyPlayerSameSongEvidence: Codable, Sendable {
    let normalizedTextSimilarity: Double
    let orderedTokenSimilarity: Double
    let titleSimilarity: Double
    let asrCoverage: Double
    let temporalOrder: Double
    let sameSongConfidence: Double
}

struct BabyPlayerASRMatchOutcome: Sendable {
    let candidates: [LyricsCandidate]
    let selected: LyricsCandidate?
    let offsetSeconds: Double?
    let message: String
    let shouldAutomaticallyApply: Bool
    let sameSongEvidence: BabyPlayerSameSongEvidence?

    // 【MODIFIED】区分“可生成 AI candidate”与“证据强到可自动展示”。
    /// 创建匹配结果；输入为候选、可选 AI 结果、偏移、消息和自动应用许可，输出为不可变结果，不修改状态。
    init(
        candidates: [LyricsCandidate],
        selected: LyricsCandidate?,
        offsetSeconds: Double?,
        message: String,
        shouldAutomaticallyApply: Bool = false,
        sameSongEvidence: BabyPlayerSameSongEvidence? = nil
    ) {
        self.candidates = candidates
        self.selected = selected
        self.offsetSeconds = offsetSeconds
        self.message = message
        self.shouldAutomaticallyApply = shouldAutomaticallyApply
        self.sameSongEvidence = sameSongEvidence
    }
}

/// AI v1 渐进回调；输入为已确定性校时的 outcome，输出为 Void，回到 MainActor 更新 UI/repository。
typealias BabyPlayerAILyricsProgressHandler = @MainActor @Sendable (
    BabyPlayerASRMatchOutcome
) async -> Void

// 【MODIFIED】同 fingerprint 共享一份轻量 in-flight Task；切歌/页面退出可按 key 安全取消。
actor BabyPlayerASRTaskRegistry {
    private struct Entry {
        let id: UUID
        let task: Task<BabyPlayerASRMatchOutcome, Error>
    }

    private var inFlight: [String: Entry] = [:]

    /// 复用或创建分析任务；输入为 fingerprint 和工作闭包，输出共享结果，会修改 registry 内存状态。
    func value(
        for fingerprint: String,
        operation: @escaping @Sendable () async throws -> BabyPlayerASRMatchOutcome
    ) async throws -> BabyPlayerASRMatchOutcome {
        if let existing = inFlight[fingerprint] {
            return try await existing.task.value
        }
        let entryID = UUID()
        let task = Task { try await operation() }
        inFlight[fingerprint] = Entry(id: entryID, task: task)
        defer {
            if inFlight[fingerprint]?.id == entryID {
                inFlight[fingerprint] = nil
            }
        }
        return try await task.value
    }

    /// 取消指定媒体工作；输入为 fingerprint，无输出，会取消并移除 registry task。
    func cancel(_ fingerprint: String) {
        if let entry = inFlight.removeValue(forKey: fingerprint) {
            babyPlayerASRLogger.notice("Analysis task cancelled for media fingerprint")
            entry.task.cancel()
        }
    }

    /// 取消全部媒体工作；无输入输出，会清空 registry。
    func cancelAll() {
        if !inFlight.isEmpty {
            babyPlayerASRLogger.notice(
                "All analysis tasks cancelled count=\(self.inFlight.count, privacy: .public)"
            )
        }
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
    }
}

// 【MODIFIED】UI 阶段与真实链路一一对应；只有进入上传时才使用 recognizing。
enum BabyPlayerASRProcessingStage: Equatable, Sendable {
    case preparingAudio(index: Int, total: Int)
    case recognizing(index: Int, total: Int)
    case aligning
    case refining
}

/// ASR 阶段回调；输入为真实处理阶段，无输出，回到 MainActor 更新 UI。
typealias BabyPlayerASRStageHandler = @MainActor @Sendable (
    BabyPlayerASRProcessingStage
) async -> Void

actor BabyPlayerASRCoordinator {
    static let shared = BabyPlayerASRCoordinator()
    // 保留 STEP 1 已存在的 registry 类型与测试供以后优化；MVP 生产分析不复用跨循环任务。
    private let taskRegistry = BabyPlayerASRTaskRegistry()

    // 【MODIFIED】Coordinator 保持 ASR/DeepSeek 两个可测试的独立阶段；是否串行由上层用户工作流明确决定。
    /// 只执行腾讯 ASR；输入当前媒体、强制刷新与阶段回调，输出原始 ASR 结果，不匹配候选或调用 DeepSeek。
    func recognize(
        item: BabyPlayerQueueItem,
        forceRefresh: Bool = false,
        onStage: BabyPlayerASRStageHandler? = nil
    ) async throws -> BabyPlayerASRAnalysis {
        let fingerprint = item.lyricsMedia.asrFingerprint
        let client = try BabyPlayerASRClient()
        guard let songWindow = BabyPlayerTemporaryASRAudioPolicy.songWindow(
            for: item.lyricsMedia
        ) else { throw BabyPlayerASRError.audioExportFailed }

        if client.usesMacLocalAnalysisJobs {
            guard let localMediaPath = item.localMediaPath,
                  !localMediaPath.isEmpty else {
                throw BabyPlayerASRError.server("Jellyfin 没有提供 Mac 本机视频路径")
            }
            await onStage?(.preparingAudio(index: 1, total: 1))
            var job = try await client.submitLocalAnalysis(
                mediaPath: localMediaPath,
                media: item.lyricsMedia,
                mediaFingerprint: fingerprint,
                mediaTitle: item.lyricsMedia.searchTitle,
                forceRefresh: forceRefresh
            )
            // 【MODIFIED】每次仅做短轮询；等待期间 Task 挂起，不暂停 AVPlayer 或循环逻辑。
            for _ in 0..<900 {
                try Task.checkCancellation()
                switch job.status {
                case "queued", "extracting":
                    await onStage?(.preparingAudio(index: 1, total: 1))
                case "recognizing":
                    await onStage?(.recognizing(index: 1, total: 1))
                case "completed":
                    guard let analysis = job.analysis else {
                        throw BabyPlayerASRError.invalidResponse
                    }
                    return analysis
                case "failed":
                    throw BabyPlayerASRError.server(
                        job.message ?? job.errorCode ?? "Mac 本地分析失败"
                    )
                default:
                    throw BabyPlayerASRError.invalidResponse
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                job = try await client.localAnalysisJob(id: job.jobID)
            }
            throw BabyPlayerASRError.server("Mac 本地分析等待超时，请稍后读取已保存结果")
        }

        if !forceRefresh,
           let cached = try? await client.cachedAnalysis(mediaFingerprint: fingerprint) {
            return cached
        }

        let usage = try await client.usage()
        try BabyPlayerASRQuotaPolicy.validate(
            usage,
            requestedSeconds: songWindow.durationSeconds
        )
        await onStage?(.preparingAudio(index: 1, total: 1))
        let prepared = try await BabyPlayerASRAudioSegmentPreparer.shared
            .prepareCompleteSong(item: item)
        do {
            try Task.checkCancellation()
            await onStage?(.recognizing(index: 1, total: 1))
            let result = try await client.analyze(
                sampleURL: prepared.fileURL,
                durationSeconds: min(
                    songWindow.durationSeconds,
                    prepared.generatedDurationSeconds
                ),
                mediaFingerprint: fingerprint,
                mediaTitle: item.lyricsMedia.searchTitle,
                forceRefresh: forceRefresh
            )
            await BabyPlayerASRAudioSegmentPreparer.shared.remove(prepared)
            return result
        } catch {
            await BabyPlayerASRAudioSegmentPreparer.shared.remove(prepared)
            throw error
        }
    }

    /// 只执行 DeepSeek 证据校准；输入媒体、最多三份候选与强制刷新，输出校准候选，不提取音频或调用 ASR。
    func reconcile(
        item: BabyPlayerQueueItem,
        candidates: [LyricsCandidate],
        forceRefresh: Bool = false,
        onStage: BabyPlayerASRStageHandler? = nil
    ) async throws -> BabyPlayerLyricsReconciliationResult {
        await onStage?(.refining)
        return try await BabyPlayerLyricsReconcilerClient().reconcile(
            songTitle: item.lyricsMedia.searchTitle,
            mediaFingerprint: item.lyricsMedia.asrFingerprint,
            candidates: Array(candidates.prefix(3)),
            forceRefresh: forceRefresh
        )
    }

    /// 只恢复服务器已完成的 DeepSeek 结果，不会触发新的付费分析。
    func cachedReconciliation(
        item: BabyPlayerQueueItem
    ) async throws -> BabyPlayerLyricsReconciliationResult? {
        try await BabyPlayerLyricsReconcilerClient().cachedReconciliation(
            songTitle: item.lyricsMedia.searchTitle,
            mediaFingerprint: item.lyricsMedia.asrFingerprint
        )
    }

    /// 取消指定媒体分析；输入为 fingerprint，无输出，会终止临时提取/上传并清理 registry。
    func cancel(mediaFingerprint: String) async {
        await taskRegistry.cancel(mediaFingerprint)
    }

    /// 页面生命周期结束时取消全部分析；无输入输出，会终止 coordinator 持有的所有工作。
    func cancelAll() async {
        await taskRegistry.cancelAll()
    }

}

enum BabyPlayerLyricsSoundMatcher {
    // 【MODIFIED】全局单调 alignment 的所有调参都集中在此，避免算法内散落 magic number。
    private enum AlignmentPolicy {
        static let minimumLineSimilarity = 0.38
        static let maximumLengthUnderrun = 2
        static let maximumLengthOverrun = 3
        static let lineSkipPenalty = 0.58
        static let leadingWordSkipPenalty = 0.006
        static let internalWordSkipPenalty = 0.08
        static let trailingWordSkipPenalty = 0.006
        static let matchBaseReward = 0.9
        static let matchTokenReward = 0.22
        static let minimumLineCoverage = 0.55
        static let minimumWordCoverage = 0.45
        static let comparisonEpsilon = 0.000_001
    }

    private struct AlignmentPredecessor {
        let row: Int
        let column: Int
        let matchedLineIndex: Int?
        let matchedWordIndex: Int?
        let matchedWordCount: Int
    }

    // 【MODIFIED】Version C 的同歌置信度只在这里定义权重和阈值。
    private enum SameSongPolicy {
        static let normalizedTextWeight = 0.28
        static let orderedPhraseWeight = 0.30
        static let titleWeight = 0.14
        static let asrCoverageWeight = 0.18
        static let temporalOrderWeight = 0.10
        static let missingTitleEvidence = 0.50
        static let minimumContentEvidence = 0.30
        static let minimumTemporalOrder = 0.75
        static let minimumConfidenceForAICandidate = 0.43
        static let minimumConfidenceForAutomaticApply = 0.58
        static let minimumAutomaticLead = 0.06
    }

    private struct ScoredCandidate {
        let candidate: LyricsCandidate
        let evidence: BabyPlayerSameSongEvidence
    }

    static func match(
        analysis: BabyPlayerASRAnalysis,
        candidates: [LyricsCandidate],
        reference: LyricsPlainTextReference?,
        sampleStartSeconds: Double,
        mediaTitle: String? = nil,
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

        // 【MODIFIED】重新分析时从普通来源重建同 anchor AI Lyrics，不把旧 AI v2 嵌套成新 AI identity。
        let ordinaryCandidates = candidates.filter { $0.identityAnchor == nil }
        var available = ordinaryCandidates.isEmpty ? candidates : ordinaryCandidates
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
            return ScoredCandidate(
                candidate: candidate,
                evidence: sameSongEvidence(
                    transcriptTokens: transcriptTokens,
                    lyricTokens: lyricTokens,
                    mediaTitle: mediaTitle,
                    candidate: candidate,
                    analysis: analysis
                )
            )
        }.sorted {
            if $0.evidence.sameSongConfidence == $1.evidence.sameSongConfidence {
                return $0.candidate.persistentIdentifier < $1.candidate.persistentIdentifier
            }
            return $0.evidence.sameSongConfidence > $1.evidence.sameSongConfidence
        }

        guard let best = scored.first else {
            return BabyPlayerASRMatchOutcome(
                candidates: candidates, selected: nil, offsetSeconds: nil,
                message: "没有可供声音核验的歌词"
            )
        }
        let runnerUpConfidence = scored.dropFirst().first?.evidence.sameSongConfidence ?? 0
        let margin = best.evidence.sameSongConfidence - runnerUpConfidence
        let permitsAICandidate = best.evidence.sameSongConfidence
            >= SameSongPolicy.minimumConfidenceForAICandidate
            && max(
                best.evidence.normalizedTextSimilarity,
                best.evidence.orderedTokenSimilarity
            ) >= SameSongPolicy.minimumContentEvidence
            && best.evidence.temporalOrder >= SameSongPolicy.minimumTemporalOrder
        let permitsAutomaticApply = permitsAICandidate
            && best.evidence.sameSongConfidence >= SameSongPolicy.minimumConfidenceForAutomaticApply
            && (scored.count == 1 || margin >= SameSongPolicy.minimumAutomaticLead)
        var selected: LyricsCandidate?
        var offset: Double?
        var message: String
        if permitsAICandidate && best.candidate.providerName?.contains("本地歌本") == true {
            selected = best.candidate
            offset = sampleStartSeconds
            message = "已用声音时间戳校准本地歌本"
        } else if permitsAICandidate,
                  preferSoundTimeline,
                  let retimed = retimedCandidate(best.candidate, analysis: analysis) {
            selected = retimed
            offset = sampleStartSeconds
            message = "AI 校时完成"
        } else if permitsAICandidate,
                  !preferSoundTimeline,
                  let estimated = estimatedOffset(
                segments: analysis.segments,
                lines: best.candidate.lines,
                sampleStartSeconds: sampleStartSeconds
                  ) {
            selected = best.candidate
            offset = estimated
            message = "声音核验已匹配并校正整体偏移"
        } else {
            // 【MODIFIED】Version C 中声音时间线是生成 AI 结果的必要条件；对齐失败时不自动绑定 raw ASR 或旧时间轴。
            selected = (!preferSoundTimeline && permitsAICandidate) ? best.candidate : nil
            offset = nil
            message = permitsAICandidate
                ? "已确认大致是同一首歌，但时间证据不足，保留普通歌词"
                : "未确认匹配，保留普通歌词"
        }
        let referenceScore = reference.map { similarity(transcriptTokens, tokens($0.plainLyrics)) }
        let referenceMessage = referenceScore.map { " · 歌本核验 \(Int($0 * 100)) 分" } ?? ""
        var orderedCandidates = scored.map(\.candidate)
        if let selected,
           !orderedCandidates.contains(where: { $0.persistentIdentifier == selected.persistentIdentifier }) {
            // 【MODIFIED】AI v1 是独立可选对象，保留原普通候选；DeepSeek v2 只更新这一 AI identity。
            orderedCandidates.insert(selected, at: 0)
        }
        return BabyPlayerASRMatchOutcome(
            candidates: orderedCandidates,
            selected: selected,
            offsetSeconds: offset,
            message: "\(message)\(referenceMessage)",
            shouldAutomaticallyApply: permitsAutomaticApply && selected != nil,
            sameSongEvidence: best.evidence
        )
    }

    // 【MODIFIED】综合文本、顺序、标题、coverage 和时间单调性，不用单一 similarity magic number。
    /// 计算 sameSongConfidence；输入为 ASR/歌词 tokens、标题、候选和时间证据，输出为集中证据结构，不修改状态。
    private static func sameSongEvidence(
        transcriptTokens: [String],
        lyricTokens: [String],
        mediaTitle: String?,
        candidate: LyricsCandidate,
        analysis: BabyPlayerASRAnalysis
    ) -> BabyPlayerSameSongEvidence {
        let normalizedText = similarity(transcriptTokens, lyricTokens)
        let ordered = orderedTokenCoverage(query: transcriptTokens, reference: lyricTokens)
        let title: Double
        if let mediaTitle, !tokens(mediaTitle).isEmpty {
            title = symmetricOrderedSimilarity(tokens(mediaTitle), tokens(candidate.trackName))
        } else {
            title = max(
                SameSongPolicy.missingTitleEvidence,
                Double(candidate.matchPercentage) / 100
            )
        }
        let coverage = multisetCoverage(query: transcriptTokens, reference: lyricTokens)
        let temporal = temporalOrderScore(analysis)
        let confidence = normalizedText * SameSongPolicy.normalizedTextWeight
            + ordered * SameSongPolicy.orderedPhraseWeight
            + title * SameSongPolicy.titleWeight
            + coverage * SameSongPolicy.asrCoverageWeight
            + temporal * SameSongPolicy.temporalOrderWeight
        return BabyPlayerSameSongEvidence(
            normalizedTextSimilarity: normalizedText,
            orderedTokenSimilarity: ordered,
            titleSimilarity: title,
            asrCoverage: coverage,
            temporalOrder: temporal,
            sameSongConfidence: confidence
        )
    }

    /// 计算 ASR token 按原顺序在歌词中的覆盖；输入两个 token 序列，输出 0...1，不修改状态。
    private static func orderedTokenCoverage(query: [String], reference: [String]) -> Double {
        guard !query.isEmpty, !reference.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: reference.count + 1)
        for queryToken in query {
            var current = Array(repeating: 0, count: reference.count + 1)
            for referenceIndex in reference.indices {
                if queryToken == reference[referenceIndex] {
                    current[referenceIndex + 1] = previous[referenceIndex] + 1
                } else {
                    current[referenceIndex + 1] = max(
                        previous[referenceIndex + 1],
                        current[referenceIndex]
                    )
                }
            }
            previous = current
        }
        return Double(previous.last ?? 0) / Double(query.count)
    }

    /// 对短标题做对称顺序比较；输入两个 token 序列，输出 0...1，不修改状态。
    private static func symmetricOrderedSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return min(
            orderedTokenCoverage(query: lhs, reference: rhs),
            orderedTokenCoverage(query: rhs, reference: lhs)
        )
    }

    /// 计算含重复词的 ASR coverage；输入查询和参考 tokens，输出 0...1，不修改状态。
    private static func multisetCoverage(query: [String], reference: [String]) -> Double {
        guard !query.isEmpty else { return 0 }
        var counts = Dictionary(grouping: reference, by: { $0 }).mapValues(\.count)
        var matches = 0
        for token in query where (counts[token] ?? 0) > 0 {
            matches += 1
            counts[token, default: 0] -= 1
        }
        return Double(matches) / Double(query.count)
    }

    /// 检查 ASR sentence/word timestamps 的单调性；输入为 analysis，输出 0...1 的有序边比例，不修改状态。
    private static func temporalOrderScore(_ analysis: BabyPlayerASRAnalysis) -> Double {
        let wordTimes = analysis.segments.flatMap(\.words).map(\.startSeconds)
        let times = wordTimes.count >= 2 ? wordTimes : analysis.segments.map(\.startSeconds)
        guard times.count >= 2 else { return 1 }
        let orderedEdges = zip(times, times.dropFirst()).filter { $0 <= $1 }.count
        return Double(orderedEdges) / Double(times.count - 1)
    }

    private static func retimedCandidate(
        _ candidate: LyricsCandidate,
        analysis: BabyPlayerASRAnalysis
    ) -> LyricsCandidate? {
        let rawLines = candidate.lines.map(\.text)
        guard let timed = retimedLines(rawLines, words: analysis.segments.flatMap(\.words)) else {
            return nil
        }
        let anchor = "ai-source:\(candidate.persistentIdentifier)"
        return LyricsCandidate(
            id: aiCandidateID(identityAnchor: anchor),
            trackName: candidate.trackName,
            artistName: candidate.artistName,
            albumName: candidate.albumName,
            duration: max(analysis.audioDurationSeconds, timed.last?.time ?? 0),
            lines: timed,
            matchScore: candidate.matchScore,
            providerName: "AI 校时歌词",
            identityAnchor: anchor
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
        let anchor = "ai-songbook:\(reference.id)"
        return LyricsCandidate(
            id: aiCandidateID(identityAnchor: anchor),
            trackName: reference.title,
            artistName: reference.artist,
            albumName: "本地歌本",
            duration: max(analysis.audioDurationSeconds, timed.last?.time ?? 0),
            lines: timed,
            matchScore: 0,
            providerName: "本地歌本·AI校准",
            identityAnchor: anchor
        )
    }

    // 【MODIFIED】以动态规划同时优化所有歌词行，前奏噪声可跳过，中间错误跳过会受更高惩罚。
    /// 建立全局单调时间轴；输入为原歌词行和按时间排列的 ASR words，输出为可选校时行，不修改 repository/UI。
    private static func retimedLines(
        _ rawLines: [String],
        words: [BabyPlayerASRWord]
    ) -> [TimedLyricLine]? {
        guard rawLines.count >= 2, words.count >= 3 else { return nil }
        let rowCount = rawLines.count + 1
        let columnCount = words.count + 1
        let stateCount = rowCount * columnCount
        var scores = Array(repeating: -Double.infinity, count: stateCount)
        var predecessors = Array<AlignmentPredecessor?>(repeating: nil, count: stateCount)
        scores[0] = 0

        func index(_ row: Int, _ column: Int) -> Int { row * columnCount + column }
        func update(
            row: Int,
            column: Int,
            score: Double,
            predecessor: AlignmentPredecessor
        ) {
            let target = index(row, column)
            if score > scores[target] + AlignmentPolicy.comparisonEpsilon {
                scores[target] = score
                predecessors[target] = predecessor
            }
        }

        for row in 0..<rowCount {
            for column in 0..<columnCount {
                let current = scores[index(row, column)]
                guard current.isFinite else { continue }
                if row < rawLines.count {
                    update(
                        row: row + 1,
                        column: column,
                        score: current - AlignmentPolicy.lineSkipPenalty,
                        predecessor: .init(
                            row: row,
                            column: column,
                            matchedLineIndex: nil,
                            matchedWordIndex: nil,
                            matchedWordCount: 0
                        )
                    )
                }
                if column < words.count {
                    let penalty = row == 0
                        ? AlignmentPolicy.leadingWordSkipPenalty
                        : AlignmentPolicy.internalWordSkipPenalty
                    update(
                        row: row,
                        column: column + 1,
                        score: current - penalty,
                        predecessor: .init(
                            row: row,
                            column: column,
                            matchedLineIndex: nil,
                            matchedWordIndex: nil,
                            matchedWordCount: 0
                        )
                    )
                }
                guard row < rawLines.count, column < words.count else { continue }
                let lineTokens = tokens(rawLines[row])
                guard !lineTokens.isEmpty else { continue }
                let minimumLength = max(1, lineTokens.count - AlignmentPolicy.maximumLengthUnderrun)
                let maximumLength = min(
                    words.count - column,
                    lineTokens.count + AlignmentPolicy.maximumLengthOverrun
                )
                guard minimumLength <= maximumLength else { continue }
                for length in minimumLength...maximumLength {
                    let recognized = words[column..<(column + length)].map(\.text).joined(separator: " ")
                    let rawSimilarity = similarity(lineTokens, tokens(recognized))
                    // 【MODIFIED】防止包含下一句的长窗口因“覆盖查询词”得到虚高分。
                    let lengthPrecision = Double(min(lineTokens.count, length))
                        / Double(max(lineTokens.count, length))
                    let matchSimilarity = rawSimilarity * lengthPrecision
                    guard matchSimilarity >= AlignmentPolicy.minimumLineSimilarity else { continue }
                    let reward = matchSimilarity * (
                        AlignmentPolicy.matchBaseReward
                        + Double(min(lineTokens.count, 8)) * AlignmentPolicy.matchTokenReward
                    )
                    update(
                        row: row + 1,
                        column: column + length,
                        score: current + reward,
                        predecessor: .init(
                            row: row,
                            column: column,
                            matchedLineIndex: row,
                            matchedWordIndex: column,
                            matchedWordCount: length
                        )
                    )
                }
            }
        }

        var bestColumn = 0
        var bestScore = -Double.infinity
        for column in 0..<columnCount {
            let score = scores[index(rawLines.count, column)]
                - Double(words.count - column) * AlignmentPolicy.trailingWordSkipPenalty
            if score > bestScore {
                bestScore = score
                bestColumn = column
            }
        }
        var row = rawLines.count
        var column = bestColumn
        var timed: [TimedLyricLine] = []
        var matchedWordCount = 0
        while row > 0 || column > 0 {
            guard let previous = predecessors[index(row, column)] else { break }
            if let lineIndex = previous.matchedLineIndex,
               let wordIndex = previous.matchedWordIndex {
                timed.append(TimedLyricLine(
                    time: words[wordIndex].startSeconds,
                    text: rawLines[lineIndex],
                    endTime: words[wordIndex + previous.matchedWordCount - 1].endSeconds
                ))
                matchedWordCount += previous.matchedWordCount
            }
            row = previous.row
            column = previous.column
        }
        timed.reverse()
        let recognizedCoverage = Double(matchedWordCount) / Double(words.count)
        let lineCoverage = Double(timed.count) / Double(rawLines.count)
        guard timed.count >= 2,
              recognizedCoverage >= AlignmentPolicy.minimumWordCoverage
                || lineCoverage >= AlignmentPolicy.minimumLineCoverage else { return nil }
        return timed
    }

    /// 从 AI source anchor 生成稳定的负数 candidate ID；输入为 anchor，输出为可与 LRCLIB/歌本 ID 区分的 Int，不修改状态。
    private static func aiCandidateID(identityAnchor: String) -> Int {
        let digest = SHA256.hash(data: Data(identityAnchor.utf8))
        let numericID = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return -1_000_000_000 - Int(numericID % 900_000_000)
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

// 【MODIFIED】家长设置只读取服务端月度额度；不再枚举、创建或删除完整歌曲 M4A 音频库。
@MainActor
final class BabyPlayerASRUsageViewModel: ObservableObject {
    @Published private(set) var usageText = "读取中…"

    func refresh() {
        Task {
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

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return "\(hours) 小时 \(minutes) 分"
    }

}
