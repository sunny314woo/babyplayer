//
// LyricsRepository.swift
// BabyPlayer 歌词候选、本地绑定和时间偏移。
// 当前主要功能：搜索与缓存候选、稳定默认绑定、每歌词独立校时及人工优先持久化。
// 最近修改：2026-08-23 引入不依赖时间戳的 persistentIdentifier v2 和 v1 timing fallback。
// 最近修改：2026-08-24 持久保留人工触发的 ASR/DeepSeek 结果，分析完成不再自动替换当前歌词。
//

import CryptoKit
import Foundation

struct LyricsMediaDescriptor: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let searchTitle: String
    let artistName: String?
    let sourceHint: String?
    let versionHint: String?
    let durationSeconds: Double?
    let songStartSeconds: Double?
    let songEndSeconds: Double?
    let mediaSourceID: String?

    /// 有 Jellyfin 章节或家长设置时，用真正的歌曲段时长代替整段 MP4 时长。
    var expectedSongDurationSeconds: Double? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let start = min(durationSeconds, max(0, songStartSeconds ?? 0))
        let end = min(durationSeconds, max(start, songEndSeconds ?? durationSeconds))
        let result = end - start
        return result > 0 ? result : nil
    }

    var hasSongBoundaryHint: Bool {
        songStartSeconds != nil || songEndSeconds != nil
    }
}

/// 只从文件名/Jellyfin 标题提取候选线索，不把文件名当成最终识别结果。
struct LyricsTitleMetadata: Equatable, Sendable {
    let searchTitle: String
    let sourceHint: String?
    let versionHint: String?

    static func parse(_ rawTitle: String) -> LyricsTitleMetadata {
        let folded = rawTitle.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let compact = folded.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()

        let sourceHint: String?
        if compact.contains("supersimplesongs") || compact.contains("supersimple")
            || containsStandaloneTag("sss", in: folded) {
            sourceHint = "Super Simple Songs"
        } else if compact.contains("babybus") || folded.contains("宝宝巴士") {
            sourceHint = "BabyBus"
        } else {
            sourceHint = nil
        }

        let versionRules: [(String, String)] = [
            (#"(?i)\bkaraoke\b"#, "Karaoke"),
            (#"(?i)\bsing[\s_-]*along\b"#, "Sing Along"),
            (#"(?i)\blive\b"#, "Live"),
            (#"(?i)\bremix\b"#, "Remix"),
            (#"(?i)\bofficial(?:\s+(?:music\s+)?video)?\b"#, "Official")
        ]
        let versionHint = versionRules.first(where: { matches($0.0, in: rawTitle) })?.1

        var title = replacing(#"^\s*\d+[\s._-]*"#, in: rawTitle, with: "")
        // 只删除包含已知来源/版本/清晰度的括号，保留真正属于歌名的括号。
        title = replacing(
            #"(?i)\s*[\[\(\uff08\u3010][^\]\)\uff09\u3011]*(?:super\s*simple(?:\s*songs)?|\bsss\b|baby\s*bus|\u5b9d\u5b9d\u5df4\u58eb|official|karaoke|sing[\s_-]*along|lyrics?|music\s*video|\bmv\b|\b(?:4k|8k|\d{3,4}p)\b)[^\]\)\uff09\u3011]*[\]\)\uff09\u3011]\s*"#,
            in: title,
            with: " "
        )
        title = replacing(#"(?i)\bsuper\s*simple(?:\s*songs)?\b"#, in: title, with: " ")
        title = replacing(#"(?i)\bbaby\s*bus\b|宝宝巴士"#, in: title, with: " ")
        title = replacing(#"(?i)(?:\s+[-\u2013\u2014|]\s+)(?:official(?:\s+(?:music\s+)?video)?|karaoke|sing[\s_-]*along|lyrics?|kids?|\bmv\b).*$"#, in: title, with: "")
        title = replacing(#"(?i)\b(?:4k|8k|\d{3,4}p)\b"#, in: title, with: " ")
        title = replacing(#"(?i)\.(?:mp4|m4v|mkv|mov|webm)$"#, in: title, with: "")
        title = replacing(#"[_]+"#, in: title, with: " ")
        title = replacing(#"\s{2,}"#, in: title, with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-|–—")))

        return LyricsTitleMetadata(
            searchTitle: title.isEmpty ? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines) : title,
            sourceHint: sourceHint,
            versionHint: versionHint
        )
    }

    private static func containsStandaloneTag(_ tag: String, in text: String) -> Bool {
        matches("(?i)(?:^|[^a-z0-9])\(tag)(?:$|[^a-z0-9])", in: text)
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}

struct TimedLyricLine: Codable, Sendable {
    let time: Double
    let text: String
    let endTime: Double?

    init(time: Double, text: String, endTime: Double? = nil) {
        self.time = time
        self.text = text
        self.endTime = endTime
    }
}

struct LyricsCandidate: Codable, Identifiable, Sendable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double
    let lines: [TimedLyricLine]
    let matchScore: Double
    let providerName: String?
    /// AI v1/v2 共用的稳定源 identity；普通候选为 nil。
    let identityAnchor: String?

    // 【MODIFIED】显式 initializer 为 AI Lyrics 允许传入稳定 anchor，同时保持旧调用点无需改动。
    /// 创建歌词候选；输入为来源元数据、文本时间线和可选 identity anchor，输出为可持久候选，不修改 repository/UI。
    init(
        id: Int,
        trackName: String,
        artistName: String,
        albumName: String?,
        duration: Double,
        lines: [TimedLyricLine],
        matchScore: Double,
        providerName: String?,
        identityAnchor: String? = nil
    ) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.lines = lines
        self.matchScore = matchScore
        self.providerName = providerName
        self.identityAnchor = identityAnchor
    }

    var previewText: String {
        lines.prefix(2).map(\.text).joined(separator: "  ·  ")
    }

    var matchPercentage: Int {
        Int(max(0, min(100, 100 - matchScore)).rounded())
    }

    /// 【MODIFIED】v2 绑定稳定来源/ID/规范文本，禁止 timestamp、offset 和展示型 provider 后缀参与。
    var persistentIdentifier: String {
        LyricsIdentity.makeV2(
            candidateID: id,
            providerName: providerName,
            trackName: trackName,
            artistName: artistName,
            lines: lines,
            identityAnchor: identityAnchor
        )
    }
}

// 【MODIFIED】分析阶段与普通候选来源分开，禁止再用 selectionOrigin 或展示文案推断。
enum LyricsAnalysisSource: String, Codable, Equatable, Sendable {
    case asr
    case deepSeek

    var displayName: String {
        switch self {
        case .asr: return "腾讯 ASR"
        case .deepSeek: return "DeepSeek 校准"
        }
    }
}

/// 一份可重复采用的分析歌词；输入来源、候选和证据哈希，输出可持久记录，不修改当前播放选择。
struct StoredLyricsAnalysisResult: Codable, Sendable {
    let source: LyricsAnalysisSource
    let candidate: LyricsCandidate
    let lyricsContentHash: String
    let asrEvidenceHash: String
    let createdAt: Date
}

/// 一首媒体的 ASR/DeepSeek 并列结果；两者可同时保留，只有人工“采用”才会另外写入默认歌词 binding。
struct StoredLyricsAnalysisBundle: Codable, Sendable {
    let mediaID: String
    let mediaFingerprint: String
    let mediaSourceID: String?
    let mediaTitle: String
    var pinnedOrdinaryPlayback: LyricsPlayback?
    var asrResult: StoredLyricsAnalysisResult?
    var deepSeekResult: StoredLyricsAnalysisResult?
    var updatedAt: Date

    func result(for source: LyricsAnalysisSource) -> StoredLyricsAnalysisResult? {
        switch source {
        case .asr: return asrResult
        case .deepSeek: return deepSeekResult
        }
    }

    var bestAvailableResult: StoredLyricsAnalysisResult? {
        deepSeekResult ?? asrResult
    }
}

// 【MODIFIED】歌词哈希用于去重和标识采用版本，不代替媒体内容哈希。
enum LyricsContentHash {
    /// 对规范化时间轴生成 SHA256；输入候选与来源，输出稳定摘要，不修改文件或 UI。
    static func make(candidate: LyricsCandidate, source: LyricsAnalysisSource) -> String {
        let lines = candidate.lines.map {
            "\(String(format: "%.3f", $0.time))|\(String(format: "%.3f", $0.endTime ?? $0.time))|\($0.text)"
        }.joined(separator: "\n")
        let raw = "babyplayer-analyzed-lyrics-v1|\(source.rawValue)|\(lines)"
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private enum LyricsIdentity {
    // 【MODIFIED】v2 仅使用稳定来源和规范文本；AI anchor 让文本有限修复不改 identity。
    /// 生成 v2 identity；输入为稳定来源、candidate ID、规范文本和可选 AI anchor，输出为摘要字符串，不修改状态。
    static func makeV2(
        candidateID: Int,
        providerName: String?,
        trackName: String,
        artistName: String,
        lines: [TimedLyricLine],
        identityAnchor: String?
    ) -> String {
        let provider = stableProviderCategory(providerName)
        let normalizedText = lines.map { normalizedIdentityText($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let stableContent = identityAnchor ?? (provider == "ai" ? "ai-candidate" : normalizedText)
        let raw = [
            "babyplayer-lyrics-v2",
            provider,
            String(candidateID),
            normalizedIdentityText(trackName),
            normalizedIdentityText(artistName),
            stableContent
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "v2:\(provider):\(candidateID):\(digest)"
    }

    /// 把展示 provider 折叠为稳定来源类别；输入为可选展示名，输出为小写类别，不修改状态。
    private static func stableProviderCategory(_ providerName: String?) -> String {
        let raw = providerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let folded = raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        if folded.hasPrefix("ai ") || folded.hasPrefix("ai·") { return "ai" }
        if folded.contains("本地歌本") { return "songbook" }
        if folded.contains("lrclib") { return "lrclib" }
        return folded.components(separatedBy: "·").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    /// 规范 identity 文本；输入为歌词/元数据，输出为去大小写、变音和标点的 token 序列，不修改状态。
    private static func normalizedIdentityText(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
        .joined(separator: " ")
    }

    /// 从 v1/v2 persisted key 读取 candidate ID；输入为旧或新 identifier，输出为可选 Int，不修改状态。
    static func candidateID(inPersistedIdentifier identifier: String) -> Int? {
        let parts = identifier.split(separator: ":", omittingEmptySubsequences: false)
        if parts.first == "v2", parts.count >= 4 { return Int(parts[2]) }
        guard parts.count >= 3 else { return nil }
        return Int(parts[parts.count - 2])
    }

    /// 保留 v1 算法仅供解码旧 binding 时推导 legacy key，新候选不再调用。
    static func make(
        candidateID: Int,
        providerName: String?,
        trackName: String,
        artistName: String,
        lines: [TimedLyricLine]
    ) -> String {
        let content = lines.map { "\(String(format: "%.3f", $0.time))|\($0.text)" }
            .joined(separator: "\n")
        let raw = [
            "babyplayer-lyrics-v1",
            providerName ?? "unknown",
            String(candidateID),
            trackName,
            artistName,
            content
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(providerName ?? "lyrics"):\(candidateID):\(digest)"
    }
}

struct LyricsTimingAdjustment: Codable, Equatable, Sendable {
    var autoOffsetSeconds: Double
    var manualAdjustmentSeconds: Double

    var effectiveOffsetSeconds: Double {
        Self.clamp(autoOffsetSeconds + manualAdjustmentSeconds)
    }

    mutating func adjustManually(by delta: Double) {
        setEffectiveOffset(effectiveOffsetSeconds + delta)
    }

    mutating func setEffectiveOffset(_ value: Double) {
        manualAdjustmentSeconds = Self.clamp(value) - autoOffsetSeconds
    }

    mutating func resetManualAdjustment() {
        manualAdjustmentSeconds = 0
    }

    private static func clamp(_ value: Double) -> Double {
        min(LyricsPlayback.maximumOffsetSeconds, max(-LyricsPlayback.maximumOffsetSeconds, value))
    }
}

struct LyricsBinding: Codable, Identifiable, Sendable {
    var id: String { mediaID }

    let mediaID: String
    let mediaFingerprint: String
    let mediaSourceID: String?
    let mediaTitle: String
    let sourceCandidateID: Int
    let sourceTrackName: String
    let sourceArtistName: String
    let sourceDuration: Double
    let lines: [TimedLyricLine]
    /// 兼容 0.4 及更早版本；新版本的真实状态保存在 timingAdjustments。
    var offsetSeconds: Double
    let selectionOrigin: LyricsSelectionOrigin?
    let selectedLyricIdentifier: String?
    var timingAdjustments: [String: LyricsTimingAdjustment]?
    let confirmedAt: Date
    var updatedAt: Date
}

enum LyricsSelectionOrigin: String, Codable, Equatable, Sendable {
    case automatic
    case asr
    case manual
}

struct LyricsPlayback: Codable, Sendable {
    static let maximumOffsetSeconds: Double = 600

    let candidateID: Int
    let trackName: String
    let artistName: String
    let sourceDuration: Double
    let lines: [TimedLyricLine]
    let lyricIdentifier: String
    var timingAdjustment: LyricsTimingAdjustment
    var isConfirmed: Bool
    var selectionOrigin: LyricsSelectionOrigin

    var autoOffsetSeconds: Double {
        get { timingAdjustment.autoOffsetSeconds }
        set { timingAdjustment.autoOffsetSeconds = newValue }
    }

    var manualAdjustmentSeconds: Double {
        get { timingAdjustment.manualAdjustmentSeconds }
        set { timingAdjustment.manualAdjustmentSeconds = newValue }
    }

    var offsetSeconds: Double {
        get { timingAdjustment.effectiveOffsetSeconds }
        set { timingAdjustment.setEffectiveOffset(newValue) }
    }

    init(
        candidateID: Int,
        trackName: String,
        artistName: String,
        sourceDuration: Double,
        lines: [TimedLyricLine],
        autoOffsetSeconds: Double,
        manualAdjustmentSeconds: Double,
        isConfirmed: Bool,
        selectionOrigin: LyricsSelectionOrigin,
        lyricIdentifier: String? = nil,
        providerName: String? = nil
    ) {
        self.candidateID = candidateID
        self.trackName = trackName
        self.artistName = artistName
        self.sourceDuration = sourceDuration
        self.lines = lines
        self.lyricIdentifier = lyricIdentifier ?? LyricsIdentity.make(
            candidateID: candidateID,
            providerName: providerName,
            trackName: trackName,
            artistName: artistName,
            lines: lines
        )
        timingAdjustment = LyricsTimingAdjustment(
            autoOffsetSeconds: autoOffsetSeconds,
            manualAdjustmentSeconds: manualAdjustmentSeconds
        )
        self.isConfirmed = isConfirmed
        self.selectionOrigin = selectionOrigin
    }

    /// 保留旧调用点的构造语义：传入的总偏移作为自动基线，人工增量从 0 开始。
    init(
        candidateID: Int,
        trackName: String,
        artistName: String,
        sourceDuration: Double,
        lines: [TimedLyricLine],
        offsetSeconds: Double,
        isConfirmed: Bool,
        selectionOrigin: LyricsSelectionOrigin,
        lyricIdentifier: String? = nil,
        providerName: String? = nil
    ) {
        self.init(
            candidateID: candidateID,
            trackName: trackName,
            artistName: artistName,
            sourceDuration: sourceDuration,
            lines: lines,
            autoOffsetSeconds: offsetSeconds,
            manualAdjustmentSeconds: 0,
            isConfirmed: isConfirmed,
            selectionOrigin: selectionOrigin,
            lyricIdentifier: lyricIdentifier,
            providerName: providerName
        )
    }
}

struct LyricsPlainTextReference: Sendable {
    let id: Int
    let title: String
    let artist: String
    let plainLyrics: String
}

enum BabyLyricsError: LocalizedError {
    case noSyncedLyrics
    case invalidServerResponse

    var errorDescription: String? {
        switch self {
        case .noSyncedLyrics:
            return "没有找到带时间轴的歌词"
        case .invalidServerResponse:
            return "在线歌词服务暂时不可用"
        }
    }
}

private struct LRCLibTrack: Decodable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double
    let instrumental: Bool
    let syncedLyrics: String?
}

private struct BundledLyricsCatalog: Decodable {
    let tracks: [BundledLyricsTrack]
}

/// 可由家长在构建 App 前填充的已授权本地曲目；不依赖 AI 或运行时抓取。
private struct BundledLyricsTrack: Decodable {
    let id: Int
    let trackID: String
    let title: String
    let aliases: [String]
    let artist: String
    let source: String?
    let version: String?
    let duration: Double?
    let plainLyrics: String?
    let syncedLyrics: String?
}

/// tvOS 不允许 App 自行写入 Documents / Application Support；歌词文件保存在
/// App 私有 Caches，Mac 本地分析服务保留可重建的权威 ASR 结果。
enum BabyPlayerLyricsStoragePolicy {
    static func writableStorageBase(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
    }
}

actor BabyLyricsRepository {
    static let shared = BabyLyricsRepository()

    private let fileManager = FileManager.default
    private let cachesDirectory: URL?
    private let applicationSupportDirectory: URL?
    private let bundledCatalogData: Data?
    private var candidateMemoryCache: [String: [LyricsCandidate]] = [:]
    private var bindingMemoryCache: [String: LyricsBinding?] = [:]
    private var analysisMemoryCache: [String: StoredLyricsAnalysisBundle?] = [:]
    private var bundledCatalogCache: [BundledLyricsTrack]?

    init(
        cachesDirectory: URL? = nil,
        applicationSupportDirectory: URL? = nil,
        bundledCatalogData: Data? = nil
    ) {
        self.cachesDirectory = cachesDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
        self.bundledCatalogData = bundledCatalogData
    }

    func resolvedLyrics(for media: LyricsMediaDescriptor) async throws -> LyricsPlayback? {
        if let binding = binding(for: media) {
            return playback(from: binding)
        }

        let candidates = try await searchCandidates(for: media)
        return resolvedLyrics(for: media, candidates: candidates)
    }

    func storedLyrics(for media: LyricsMediaDescriptor) -> LyricsPlayback? {
        binding(for: media).map(playback(from:))
    }

    func resolvedLyrics(
        for media: LyricsMediaDescriptor,
        candidates: [LyricsCandidate]
    ) -> LyricsPlayback? {
        if let binding = binding(for: media) {
            return playback(from: binding)
        }

        // 【MODIFIED】首份候选只作即时显示，不持久化为“已固定”，也不自动触发分析。
        guard let candidate = candidates.first else { return nil }
        let playback = LyricsPlayback(
            candidateID: candidate.id,
            trackName: candidate.trackName,
            artistName: candidate.artistName,
            sourceDuration: candidate.duration,
            lines: candidate.lines,
            autoOffsetSeconds: media.songStartSeconds ?? 0,
            manualAdjustmentSeconds: 0,
            // 网络歌词只是声音分析完成前的即时兜底，不应被视为最终绑定。
            isConfirmed: false,
            selectionOrigin: .automatic,
            lyricIdentifier: candidate.persistentIdentifier,
            providerName: candidate.providerName
        )
        return playback
    }

    /// 恢复该候选自己的校时；没有历史记录时从歌曲段起点建立独立基线。
    func playback(
        for candidate: LyricsCandidate,
        media: LyricsMediaDescriptor,
        selectionOrigin: LyricsSelectionOrigin
    ) -> LyricsPlayback {
        let identifier = candidate.persistentIdentifier
        let adjustment = timingAdjustment(
            identifier: identifier,
            candidateID: candidate.id,
            binding: binding(for: media),
            defaultAutoOffset: media.songStartSeconds ?? 0
        )
        return LyricsPlayback(
            candidateID: candidate.id,
            trackName: candidate.trackName,
            artistName: candidate.artistName,
            sourceDuration: candidate.duration,
            lines: candidate.lines,
            autoOffsetSeconds: adjustment.autoOffsetSeconds,
            manualAdjustmentSeconds: adjustment.manualAdjustmentSeconds,
            isConfirmed: selectionOrigin != .manual,
            selectionOrigin: selectionOrigin,
            lyricIdentifier: identifier,
            providerName: candidate.providerName
        )
    }

    // 【MODIFIED】分析结果位于 Application Support，只有 App 卸载或确认媒体已删除时才清理。
    /// 读取媒体的持久分析结果；输入媒体描述，输出 ASR/DeepSeek bundle，不改变默认歌词。
    func analysisBundle(for media: LyricsMediaDescriptor) -> StoredLyricsAnalysisBundle? {
        if let cached = analysisMemoryCache[media.id] { return cached }
        if let exact = try? loadAnalysisBundleFromDisk(mediaID: media.id) {
            analysisMemoryCache[media.id] = exact
            return exact
        }
        if let fallback = try? loadAllAnalysisBundles().first(where: { stored in
            let sourceMatches = media.mediaSourceID.map { $0 == stored.mediaSourceID } ?? false
            return sourceMatches
                || stored.mediaFingerprint == mediaFingerprint(for: media)
                || stored.mediaFingerprint == legacyMediaFingerprint(for: media)
        }) {
            let migrated = StoredLyricsAnalysisBundle(
                mediaID: media.id,
                mediaFingerprint: mediaFingerprint(for: media),
                mediaSourceID: media.mediaSourceID,
                mediaTitle: media.title,
                pinnedOrdinaryPlayback: fallback.pinnedOrdinaryPlayback,
                asrResult: fallback.asrResult,
                deepSeekResult: fallback.deepSeekResult,
                updatedAt: Date()
            )
            try? saveAnalysisBundleToDisk(migrated)
            analysisMemoryCache[media.id] = migrated
            return migrated
        }
        analysisMemoryCache[media.id] = nil
        return nil
    }

    /// 保存人工运行的 ASR 结果；新证据会使基于旧 ASR 的 DeepSeek 结果过期，不修改当前歌词。
    @discardableResult
    func storeASRResult(
        _ candidate: LyricsCandidate,
        asrEvidenceHash: String,
        for media: LyricsMediaDescriptor
    ) throws -> StoredLyricsAnalysisBundle {
        var bundle = analysisBundle(for: media) ?? emptyAnalysisBundle(for: media)
        let result = StoredLyricsAnalysisResult(
            source: .asr,
            candidate: candidate,
            lyricsContentHash: LyricsContentHash.make(candidate: candidate, source: .asr),
            asrEvidenceHash: asrEvidenceHash,
            createdAt: Date()
        )
        if bundle.asrResult?.asrEvidenceHash != asrEvidenceHash {
            bundle.deepSeekResult = nil
        }
        bundle.asrResult = result
        bundle.updatedAt = Date()
        try saveAnalysisBundleToDisk(bundle)
        analysisMemoryCache[media.id] = bundle
        return bundle
    }

    /// 保存人工运行的 DeepSeek 结果；输入候选和所依赖 ASR 哈希，输出更新 bundle，不自动采用。
    @discardableResult
    func storeDeepSeekResult(
        _ candidate: LyricsCandidate,
        asrEvidenceHash: String,
        for media: LyricsMediaDescriptor
    ) throws -> StoredLyricsAnalysisBundle {
        var bundle = analysisBundle(for: media) ?? emptyAnalysisBundle(for: media)
        bundle.deepSeekResult = StoredLyricsAnalysisResult(
            source: .deepSeek,
            candidate: candidate,
            lyricsContentHash: LyricsContentHash.make(candidate: candidate, source: .deepSeek),
            asrEvidenceHash: asrEvidenceHash,
            createdAt: Date()
        )
        bundle.updatedAt = Date()
        try saveAnalysisBundleToDisk(bundle)
        analysisMemoryCache[media.id] = bundle
        return bundle
    }

    /// Repository 层强制人工优先，避免未来新 UI 绕过播放器里的保护判断。
    @discardableResult
    func applyAutomaticRecommendation(
        _ candidate: LyricsCandidate,
        autoOffsetSeconds: Double?,
        for media: LyricsMediaDescriptor,
        automationGuard: LyricsAutomationGenerationGuard? = nil,
        startedAtGeneration: Int? = nil
    ) throws -> LyricsPlayback? {
        if let existing = binding(for: media),
           (existing.selectionOrigin ?? .manual) == .manual {
            return nil
        }
        var playback = playback(for: candidate, media: media, selectionOrigin: .asr)
        if let autoOffsetSeconds {
            playback.autoOffsetSeconds = autoOffsetSeconds
        }
        // 【MODIFIED】自动 binding 的最终 gate 检查与写入在同一临界区内，manual click 不会与其交叉。
        if let automationGuard, let startedAtGeneration {
            return try automationGuard.performIfAutomaticResultIsPermitted(
                startedAt: startedAtGeneration
            ) {
                _ = try confirm(playback, for: media)
                return playback
            }
        }
        _ = try confirm(playback, for: media)
        return playback
    }

    func plainTextReference(for media: LyricsMediaDescriptor) -> LyricsPlainTextReference? {
        bundledCatalogMatches(for: media).compactMap { track in
            guard let lyrics = track.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !lyrics.isEmpty else { return nil }
            return LyricsPlainTextReference(
                id: track.id,
                title: track.title,
                artist: track.artist,
                plainLyrics: lyrics
            )
        }.first
    }

    func searchCandidates(
        for media: LyricsMediaDescriptor,
        forceRefresh: Bool = false
    ) async throws -> [LyricsCandidate] {
        let key = mediaFingerprint(for: media)
        if !forceRefresh {
            if let cached = candidateMemoryCache[key] { return cached }
            if let cached = try? loadCandidatesFromDisk(key: key) {
                candidateMemoryCache[key] = cached
                return cached
            }
        }

        let catalogTracks = bundledCatalogMatches(for: media)
        let artist = media.artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceHint = media.sourceHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let simplifiedTitle = simplifiedSearchTitle(media.searchTitle)
        var queries: [(title: String, artist: String?)] = [(media.searchTitle, artist)]
        if let sourceHint, !sourceHint.isEmpty,
           normalized(sourceHint) != normalized(artist ?? "") {
            queries.append((media.searchTitle, sourceHint))
        }
        if artist?.isEmpty == false {
            // Jellyfin 的演唱者信息有时来自专辑或文件标签；再搜一次歌名可避免错误标签漏掉结果。
            queries.append((media.searchTitle, nil))
        }
        if normalized(simplifiedTitle) != normalized(media.searchTitle) {
            queries.append((simplifiedTitle, nil))
        }
        queries.append(contentsOf: catalogTracks.map { ($0.title, $0.artist) })
        queries = uniqueQueries(queries)

        var tracks: [LRCLibTrack] = []
        var lastError: Error?
        var receivedValidResponse = false
        for query in queries {
            do {
                tracks.append(contentsOf: try await fetchTracks(
                    title: query.title,
                    artist: query.artist
                ))
                receivedValidResponse = true
            } catch {
                lastError = error
            }
        }
        let wantedTitle = normalized(media.searchTitle)
        let bundledCandidates = catalogTracks.compactMap { track -> LyricsCandidate? in
            guard track.id < 0,
                  let syncedLyrics = track.syncedLyrics,
                  !syncedLyrics.isEmpty else { return nil }
            let lines = parseSyncedLyrics(syncedLyrics)
            guard !lines.isEmpty else { return nil }
            let duration = track.duration ?? lines.last?.time ?? 0
            guard duration > 0 else { return nil }
            return LyricsCandidate(
                id: track.id,
                trackName: track.title,
                artistName: track.artist,
                albumName: track.source,
                duration: duration,
                lines: lines,
                matchScore: score(
                    trackName: track.title,
                    artistName: track.artist,
                    albumName: track.source,
                    duration: duration,
                    wantedTitle: wantedTitle,
                    media: media
                ),
                providerName: "内置曲目库"
            )
        }
        if tracks.isEmpty, bundledCandidates.isEmpty,
           !receivedValidResponse, let lastError { throw lastError }

        let onlineCandidates = tracks.compactMap { track -> LyricsCandidate? in
            guard !track.instrumental,
                  let syncedLyrics = track.syncedLyrics,
                  !syncedLyrics.isEmpty else { return nil }
            let lines = parseSyncedLyrics(syncedLyrics)
            guard !lines.isEmpty else { return nil }
            return LyricsCandidate(
                id: track.id,
                trackName: track.trackName,
                artistName: track.artistName,
                albumName: track.albumName,
                duration: track.duration,
                lines: lines,
                matchScore: score(track, wantedTitle: wantedTitle, media: media),
                providerName: "LRCLIB"
            )
        }

        let candidates = (bundledCandidates + onlineCandidates)
        .sorted {
            if $0.matchScore == $1.matchScore { return $0.id < $1.id }
            return $0.matchScore < $1.matchScore
        }

        let uniqueCandidates = Array(
            Dictionary(grouping: candidates, by: \.id)
                .compactMap { $0.value.first }
                .sorted {
                    if $0.matchScore == $1.matchScore { return $0.id < $1.id }
                    return $0.matchScore < $1.matchScore
                }
                .prefix(3)
        )
        guard !uniqueCandidates.isEmpty else { throw BabyLyricsError.noSyncedLyrics }
        candidateMemoryCache[key] = uniqueCandidates
        try? saveCandidatesToDisk(uniqueCandidates, key: key)
        return uniqueCandidates
    }

    private func fetchTracks(title: String, artist: String?) async throws -> [LRCLibTrack] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        var queryItems = [URLQueryItem(name: "track_name", value: title)]
        if let artist, !artist.isEmpty {
            queryItems.append(URLQueryItem(name: "artist_name", value: artist))
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw BabyLyricsError.invalidServerResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("BabyPlayer/0.4 (tvOS; LRCLIB lyrics selection)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BabyLyricsError.invalidServerResponse
        }
        return try JSONDecoder().decode([LRCLibTrack].self, from: data)
    }

    func binding(for media: LyricsMediaDescriptor) -> LyricsBinding? {
        if let cached = bindingMemoryCache[media.id] { return cached }
        if let exact = try? loadBindingFromDisk(mediaID: media.id) {
            bindingMemoryCache[media.id] = exact
            return exact
        }

        // Jellyfin 重建条目时 ID 可能变化；标题、演唱者和时长均一致时恢复原绑定。
        if let fallback = try? loadAllBindings().first(where: { stored in
            let sourceMatches = media.mediaSourceID.map { $0 == stored.mediaSourceID } ?? false
            return sourceMatches
                || stored.mediaFingerprint == mediaFingerprint(for: media)
                || stored.mediaFingerprint == legacyMediaFingerprint(for: media)
        }) {
            let migrated = LyricsBinding(
                mediaID: media.id,
                mediaFingerprint: fallback.mediaFingerprint,
                mediaSourceID: media.mediaSourceID,
                mediaTitle: media.title,
                sourceCandidateID: fallback.sourceCandidateID,
                sourceTrackName: fallback.sourceTrackName,
                sourceArtistName: fallback.sourceArtistName,
                sourceDuration: fallback.sourceDuration,
                lines: fallback.lines,
                offsetSeconds: fallback.offsetSeconds,
                selectionOrigin: fallback.selectionOrigin,
                selectedLyricIdentifier: fallback.selectedLyricIdentifier,
                timingAdjustments: fallback.timingAdjustments,
                confirmedAt: fallback.confirmedAt,
                updatedAt: Date()
            )
            try? saveBindingToDisk(migrated)
            bindingMemoryCache[media.id] = migrated
            return migrated
        }

        bindingMemoryCache[media.id] = nil
        return nil
    }

    func bindings(for mediaItems: [LyricsMediaDescriptor]) -> [String: LyricsBinding] {
        Dictionary(uniqueKeysWithValues: mediaItems.compactMap { media in
            binding(for: media).map { (media.id, $0) }
        })
    }

    @discardableResult
    func confirm(_ candidate: LyricsCandidate, for media: LyricsMediaDescriptor) throws -> LyricsBinding {
        let playback = playback(for: candidate, media: media, selectionOrigin: .manual)
        return try confirm(playback, for: media)
    }

    @discardableResult
    func confirm(_ playback: LyricsPlayback, for media: LyricsMediaDescriptor) throws -> LyricsBinding {
        let existing = binding(for: media)
        var timings = existing?.timingAdjustments ?? [:]
        if let existing,
           timings[existingLyricIdentifier(existing)] == nil {
            timings[existingLyricIdentifier(existing)] = LyricsTimingAdjustment(
                // 旧绑定无法可靠区分自动与人工部分；把总值视为人工值可确保迁移后不被覆盖。
                autoOffsetSeconds: 0,
                manualAdjustmentSeconds: existing.offsetSeconds
            )
        }
        timings[playback.lyricIdentifier] = playback.timingAdjustment
        let binding = LyricsBinding(
            mediaID: media.id,
            mediaFingerprint: mediaFingerprint(for: media),
            mediaSourceID: media.mediaSourceID,
            mediaTitle: media.title,
            sourceCandidateID: playback.candidateID,
            sourceTrackName: playback.trackName,
            sourceArtistName: playback.artistName,
            sourceDuration: playback.sourceDuration,
            lines: playback.lines,
            offsetSeconds: playback.offsetSeconds,
            selectionOrigin: playback.selectionOrigin,
            selectedLyricIdentifier: playback.lyricIdentifier,
            timingAdjustments: timings,
            confirmedAt: existing?.confirmedAt ?? Date(),
            updatedAt: Date()
        )
        try saveBindingToDisk(binding)
        bindingMemoryCache[media.id] = binding
        if playback.selectionOrigin == .manual {
            var analysis = analysisBundle(for: media) ?? emptyAnalysisBundle(for: media)
            analysis.pinnedOrdinaryPlayback = playback
            analysis.updatedAt = Date()
            try saveAnalysisBundleToDisk(analysis)
            analysisMemoryCache[media.id] = analysis
        }
        return binding
    }

    @discardableResult
    func updateOffset(
        for media: LyricsMediaDescriptor,
        offsetSeconds: Double
    ) throws -> LyricsBinding? {
        guard var binding = binding(for: media) else { return nil }
        let identifier = existingLyricIdentifier(binding)
        var adjustment = timingAdjustment(
            identifier: identifier,
            candidateID: binding.sourceCandidateID,
            binding: binding,
            defaultAutoOffset: 0
        )
        adjustment.setEffectiveOffset(offsetSeconds)
        var timings = binding.timingAdjustments ?? [:]
        timings[identifier] = adjustment
        binding.timingAdjustments = timings
        binding.offsetSeconds = adjustment.effectiveOffsetSeconds
        binding.updatedAt = Date()
        try saveBindingToDisk(binding)
        bindingMemoryCache[media.id] = binding
        return binding
    }

    func removeBinding(for media: LyricsMediaDescriptor) throws {
        let root = try bindingsRoot(createDirectory: false)
        if fileManager.fileExists(atPath: root.path) {
            let fingerprint = mediaFingerprint(for: media)
            let legacyFingerprint = legacyMediaFingerprint(for: media)
            let urls = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for url in urls where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let stored = try? JSONDecoder().decode(LyricsBinding.self, from: data) else { continue }
                let sourceMatches = media.mediaSourceID.map { $0 == stored.mediaSourceID } ?? false
                guard stored.mediaID == media.id
                        || sourceMatches
                        || stored.mediaFingerprint == fingerprint
                        || stored.mediaFingerprint == legacyFingerprint else { continue }
                try fileManager.removeItem(at: url)
                bindingMemoryCache[stored.mediaID] = nil
            }
        }
        bindingMemoryCache[media.id] = nil
    }

    private func playback(from binding: LyricsBinding) -> LyricsPlayback {
        let identifier = existingLyricIdentifier(binding)
        let adjustment = timingAdjustment(
            identifier: identifier,
            candidateID: binding.sourceCandidateID,
            binding: binding,
            defaultAutoOffset: 0
        )
        return LyricsPlayback(
            candidateID: binding.sourceCandidateID,
            trackName: binding.sourceTrackName,
            artistName: binding.sourceArtistName,
            sourceDuration: binding.sourceDuration,
            lines: binding.lines,
            autoOffsetSeconds: adjustment.autoOffsetSeconds,
            manualAdjustmentSeconds: adjustment.manualAdjustmentSeconds,
            // 旧的 automatic 绑定仍可被 ASR 自动替换；asr/manual 才是最终结果。
            isConfirmed: (binding.selectionOrigin ?? .manual) != .automatic,
            // Bindings written before origin tracking are treated as manual so an
            // automatic analysis never overwrites a parent's earlier choice.
            selectionOrigin: binding.selectionOrigin ?? .manual,
            lyricIdentifier: identifier
        )
    }

    private func timingAdjustment(
        identifier: String,
        candidateID: Int,
        binding: LyricsBinding?,
        defaultAutoOffset: Double
    ) -> LyricsTimingAdjustment {
        if let stored = binding?.timingAdjustments?[identifier] {
            return stored
        }
        // 【MODIFIED】已有 v1 selected key 时先按当前 candidate ID 恢复，避免 retime 切到 v2 后丢人工增量。
        if let binding,
           binding.sourceCandidateID == candidateID,
           let selectedIdentifier = binding.selectedLyricIdentifier,
           let selectedAdjustment = binding.timingAdjustments?[selectedIdentifier] {
            return selectedAdjustment
        }
        // 【MODIFIED】对多候选旧数据使用 key 中的 candidate ID 作最小可维护 fallback。
        if let legacy = binding?.timingAdjustments?.first(where: {
            LyricsIdentity.candidateID(inPersistedIdentifier: $0.key) == candidateID
        })?.value {
            return legacy
        }
        if let binding {
            let isSelectedIdentifier = binding.selectedLyricIdentifier == identifier
            let isLegacySelectedCandidate = binding.selectedLyricIdentifier == nil
                && binding.sourceCandidateID == candidateID
            if isSelectedIdentifier || isLegacySelectedCandidate {
                return LyricsTimingAdjustment(
                    autoOffsetSeconds: 0,
                    manualAdjustmentSeconds: binding.offsetSeconds
                )
            }
        }
        return LyricsTimingAdjustment(
            autoOffsetSeconds: defaultAutoOffset,
            manualAdjustmentSeconds: 0
        )
    }

    private func existingLyricIdentifier(_ binding: LyricsBinding) -> String {
        binding.selectedLyricIdentifier ?? LyricsIdentity.make(
            candidateID: binding.sourceCandidateID,
            providerName: nil,
            trackName: binding.sourceTrackName,
            artistName: binding.sourceArtistName,
            lines: binding.lines
        )
    }

    private func score(
        _ track: LRCLibTrack,
        wantedTitle: String,
        media: LyricsMediaDescriptor
    ) -> Double {
        score(
            trackName: track.trackName,
            artistName: track.artistName,
            albumName: track.albumName,
            duration: track.duration,
            wantedTitle: wantedTitle,
            media: media
        )
    }

    private func score(
        trackName: String,
        artistName: String,
        albumName: String?,
        duration: Double,
        wantedTitle: String,
        media: LyricsMediaDescriptor
    ) -> Double {
        let candidateTitle = normalized(trackName)
        let titlePenalty: Double
        if candidateTitle == wantedTitle {
            titlePenalty = 0
        } else if candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) {
            titlePenalty = 30
        } else {
            titlePenalty = 150
        }

        // 文件名中明确的 [SSS]/[宝宝巴士] 比 Jellyfin 可能误填的专辑艺人更可信。
        let wantedArtist = (media.sourceHint ?? media.artistName).map(normalized) ?? ""
        let candidateArtist = normalized(artistName)
        let artistPenalty: Double
        if wantedArtist.isEmpty {
            artistPenalty = 0
        } else if candidateArtist == wantedArtist {
            artistPenalty = 0
        } else if candidateArtist.contains(wantedArtist) || wantedArtist.contains(candidateArtist) {
            artistPenalty = 12
        } else {
            artistPenalty = 45
        }

        let versionPenalty: Double
        if let version = media.versionHint, version != "Official" {
            let candidateVersionText = normalized("\(trackName) \(albumName ?? "")")
            versionPenalty = candidateVersionText.contains(normalized(version)) ? 0 : 35
        } else {
            versionPenalty = 0
        }

        let durationPenalty: Double
        if let expectedDuration = media.expectedSongDurationSeconds {
            let difference = duration - expectedDuration
            // 未标记边界时，MP4 比歌曲长很可能只是多了片头片尾，因此降低这一方向的惩罚。
            let multiplier = !media.hasSongBoundaryHint && difference < 0 ? 0.45 : 1.6
            durationPenalty = min(90, abs(difference) * multiplier)
        } else {
            durationPenalty = 0
        }
        return titlePenalty + artistPenalty + versionPenalty + durationPenalty
    }

    private func bundledCatalogMatches(for media: LyricsMediaDescriptor) -> [BundledLyricsTrack] {
        let wantedTitle = normalized(media.searchTitle)
        return bundledCatalog().filter { track in
            let titles = [track.title] + track.aliases
            let titleMatches = titles.map(normalized).contains { candidate in
                candidate == wantedTitle
                    || candidate.contains(wantedTitle)
                    || wantedTitle.contains(candidate)
            }
            guard titleMatches else { return false }

            if let sourceHint = media.sourceHint {
                let wantedSource = normalized(sourceHint)
                let availableSource = normalized(track.source ?? track.artist)
                guard availableSource == wantedSource
                        || availableSource.contains(wantedSource)
                        || wantedSource.contains(availableSource) else { return false }
            }
            if let versionHint = media.versionHint,
               versionHint != "Official",
               normalized(track.version ?? "") != normalized(versionHint) {
                return false
            }
            return true
        }
    }

    private func bundledCatalog() -> [BundledLyricsTrack] {
        if let bundledCatalogCache { return bundledCatalogCache }
        let data: Data?
        if let bundledCatalogData {
            data = bundledCatalogData
        } else if let url = Bundle.main.url(forResource: "BabyLyricsCatalog", withExtension: "json") {
            data = try? Data(contentsOf: url)
        } else {
            data = nil
        }
        guard let data,
              let catalog = try? JSONDecoder().decode(BundledLyricsCatalog.self, from: data) else {
            bundledCatalogCache = []
            return []
        }
        bundledCatalogCache = catalog.tracks
        return catalog.tracks
    }

    private func uniqueQueries(
        _ queries: [(title: String, artist: String?)]
    ) -> [(title: String, artist: String?)] {
        var seen = Set<String>()
        return queries.filter { query in
            let key = "\(normalized(query.title))|\(normalized(query.artist ?? ""))"
            return seen.insert(key).inserted
        }
    }

    private func parseSyncedLyrics(_ lyrics: String) -> [TimedLyricLine] {
        let pattern = #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return lyrics.components(separatedBy: .newlines).compactMap { row in
            let fullRange = NSRange(row.startIndex..<row.endIndex, in: row)
            guard let match = regex.firstMatch(in: row, range: fullRange),
                  let minuteRange = Range(match.range(at: 1), in: row),
                  let secondRange = Range(match.range(at: 2), in: row),
                  let textRange = Range(match.range(at: 3), in: row),
                  let minutes = Double(row[minuteRange]),
                  let seconds = Double(row[secondRange]) else { return nil }
            let text = row[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimedLyricLine(time: minutes * 60 + seconds, text: text)
        }
        .sorted { $0.time < $1.time }
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    private func simplifiedSearchTitle(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*[\(\[（【].*?[\)\]）】]\s*"#,
            with: " ",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\s+[-–—]\s+(official|lyrics?|karaoke|sing[ -]?along|kids?).*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mediaFingerprint(for media: LyricsMediaDescriptor) -> String {
        let duration = Int((media.durationSeconds ?? 0).rounded())
        let source = normalized(media.sourceHint ?? "")
        let version = normalized(media.versionHint ?? "")
        return "\(normalized(media.searchTitle))|\(normalized(media.artistName ?? ""))|\(source)|\(version)|\(duration)"
    }

    /// 兼容 0.4 及更早版本保存的三段式指纹。
    private func legacyMediaFingerprint(for media: LyricsMediaDescriptor) -> String {
        let duration = Int((media.durationSeconds ?? 0).rounded())
        let legacyTitle = media.title.replacingOccurrences(
            of: #"^\s*\d+[\s._-]*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(normalized(legacyTitle))|\(normalized(media.artistName ?? ""))|\(duration)"
    }

    private func safeFileName(_ raw: String) -> String {
        Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func candidatesRoot() throws -> URL {
        let base = cachesDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let root = base
            .appendingPathComponent("BabyPlayerLyrics", isDirectory: true)
            .appendingPathComponent("Candidates-v2", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func bindingsRoot(createDirectory: Bool = true) throws -> URL {
        let base = try durableApplicationSupportRoot(
            createDirectory: createDirectory
        )
        let root = base
            .appendingPathComponent("BabyPlayerLyrics", isDirectory: true)
            .appendingPathComponent("Bindings", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func analysisRoot(createDirectory: Bool = true) throws -> URL {
        let base = try durableApplicationSupportRoot(
            createDirectory: createDirectory
        )
        let root = base
            .appendingPathComponent("BabyPlayerLyrics", isDirectory: true)
            .appendingPathComponent("AnalysisResults-v1", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    /// tvOS 真机仅允许这里使用 Caches；注入目录仍用于隔离单元测试。
    /// 输入是否需要创建目录，输出 App 私有歌词目录；只在保存时创建目录。
    private func durableApplicationSupportRoot(createDirectory: Bool) throws -> URL {
        if let applicationSupportDirectory {
            if createDirectory {
                try fileManager.createDirectory(
                    at: applicationSupportDirectory,
                    withIntermediateDirectories: true
                )
            }
            return applicationSupportDirectory
        }
        let root = BabyPlayerLyricsStoragePolicy.writableStorageBase(
            fileManager: fileManager
        )
        if createDirectory {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func candidateURL(key: String) throws -> URL {
        try candidatesRoot().appendingPathComponent(safeFileName(key)).appendingPathExtension("json")
    }

    private func bindingURL(mediaID: String, createDirectory: Bool = true) throws -> URL {
        try bindingsRoot(createDirectory: createDirectory)
            .appendingPathComponent(safeFileName(mediaID))
            .appendingPathExtension("json")
    }

    private func analysisURL(mediaID: String, createDirectory: Bool = true) throws -> URL {
        try analysisRoot(createDirectory: createDirectory)
            .appendingPathComponent(safeFileName(mediaID))
            .appendingPathExtension("json")
    }

    private func loadCandidatesFromDisk(key: String) throws -> [LyricsCandidate] {
        let data = try Data(contentsOf: candidateURL(key: key))
        return try JSONDecoder().decode([LyricsCandidate].self, from: data)
    }

    private func saveCandidatesToDisk(_ candidates: [LyricsCandidate], key: String) throws {
        let data = try JSONEncoder().encode(candidates)
        try data.write(to: candidateURL(key: key), options: .atomic)
    }

    private func loadBindingFromDisk(mediaID: String) throws -> LyricsBinding {
        let data = try Data(contentsOf: bindingURL(mediaID: mediaID, createDirectory: false))
        return try JSONDecoder().decode(LyricsBinding.self, from: data)
    }

    private func loadAllBindings() throws -> [LyricsBinding] {
        let root = try bindingsRoot(createDirectory: false)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(LyricsBinding.self, from: data)
        }
    }

    private func saveBindingToDisk(_ binding: LyricsBinding) throws {
        let data = try JSONEncoder().encode(binding)
        try data.write(to: bindingURL(mediaID: binding.mediaID), options: .atomic)
    }

    private func emptyAnalysisBundle(for media: LyricsMediaDescriptor) -> StoredLyricsAnalysisBundle {
        StoredLyricsAnalysisBundle(
            mediaID: media.id,
            mediaFingerprint: mediaFingerprint(for: media),
            mediaSourceID: media.mediaSourceID,
            mediaTitle: media.title,
            pinnedOrdinaryPlayback: nil,
            asrResult: nil,
            deepSeekResult: nil,
            updatedAt: Date()
        )
    }

    private func loadAnalysisBundleFromDisk(mediaID: String) throws -> StoredLyricsAnalysisBundle {
        let data = try Data(contentsOf: analysisURL(mediaID: mediaID, createDirectory: false))
        return try JSONDecoder().decode(StoredLyricsAnalysisBundle.self, from: data)
    }

    private func loadAllAnalysisBundles() throws -> [StoredLyricsAnalysisBundle] {
        let root = try analysisRoot(createDirectory: false)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(StoredLyricsAnalysisBundle.self, from: data)
        }
    }

    private func saveAnalysisBundleToDisk(_ bundle: StoredLyricsAnalysisBundle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bundle)
        try data.write(to: analysisURL(mediaID: bundle.mediaID), options: .atomic)
    }
}
