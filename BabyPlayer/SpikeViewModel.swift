//
// SpikeViewModel.swift
// BabyPlayer 产品状态：首次配对、持久授权、儿童首页和播放队列。
// 最近修改：2026-08-24 将 Jellyfin 本机媒体路径随队列交给 Mac 本地歌词分析。
//

import Combine
import Foundation
import Security

enum BabyPlayerAppState {
    case onboarding
    case loading
    case home
    case unavailable
}

enum BabyPlayerOnboardingStep {
    case welcome
    case server
    case code
    case success
}

enum BabyPlayerPlaybackBehavior: String, CaseIterable, Identifiable {
    case repeatOne = "单曲循环"
    case sequential = "顺序播放"
    case repeatAll = "列表循环"
    case shuffle = "随机播放"

    var id: String { rawValue }
}

/// 视频的本地偏好；状态只影响 BabyPlayer，不修改任何媒体源文件。
enum BabyPlayerRating: String, CaseIterable, Identifiable {
    case unrated = "未评分"
    case liked = "喜欢"
    case disliked = "不喜欢"
    case blocked = "屏蔽"

    var id: String { rawValue }

    var rankingWeight: Int {
        switch self {
        case .liked: return 1
        case .disliked: return -1
        case .unrated, .blocked: return 0
        }
    }
}

/// 媒体源只负责定位文件；BabyPlayer 的评分、屏蔽、续播和字幕使用这个来源无关身份。
/// 目前以规范化文件名建立兼容身份；同一目录出现重名时退回来源 ID，避免错误串数据。
struct BabyPlayerContentIdentityInput: Equatable, Sendable {
    let sourceID: String
    let displayName: String
    let fileNameOrPath: String
}

enum BabyPlayerContentIdentityResolver {
    static func mappings(
        for inputs: [BabyPlayerContentIdentityInput]
    ) -> [String: String] {
        let candidates = inputs.map { input in
            (input, BabyPlayerLocalMediaMigrationKey.make(fileNameOrPath: input.fileNameOrPath))
        }
        let counts = Dictionary(grouping: candidates.compactMap(\.1), by: { $0 })
            .mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: candidates.map { input, candidate in
            let resolved = candidate.flatMap { counts[$0] == 1 ? $0 : nil }
            return (input.sourceID, resolved ?? input.sourceID)
        })
    }

    /// 把来源 ID 下的旧评分归并到内容 ID；屏蔽优先，喜欢/不喜欢冲突时不猜测。
    static func migratedRatings(
        _ ratings: [String: BabyPlayerRating],
        aliases: [String: String]
    ) -> [String: BabyPlayerRating] {
        var grouped: [String: [BabyPlayerRating]] = [:]
        for (storedID, rating) in ratings {
            grouped[aliases[storedID] ?? storedID, default: []].append(rating)
        }
        return grouped.reduce(into: [:]) { result, entry in
            let values = entry.value
            if values.contains(.blocked) {
                result[entry.key] = .blocked
            } else if Set(values) == [.liked] {
                result[entry.key] = .liked
            } else if Set(values) == [.disliked] {
                result[entry.key] = .disliked
            }
        }
    }

    static func migratedResumeState(
        _ state: BabyPlayerPlaybackResumeState?,
        aliases: [String: String]
    ) -> BabyPlayerPlaybackResumeState? {
        guard let state, let contentID = aliases[state.itemID], contentID != state.itemID else {
            return state
        }
        return BabyPlayerPlaybackResumeState(
            itemID: contentID,
            positionSeconds: state.positionSeconds,
            durationSeconds: state.durationSeconds,
            updatedAt: state.updatedAt
        )
    }
}

struct BabyPlayerBlockedContentItem: Identifiable, Equatable {
    let id: String
    let title: String
}

/// 批量 AI 只跳过家长明确屏蔽的项目；“不喜欢”仍是可见内容偏好，不等同于拉黑。
enum BabyPlayerBatchEligibilityPolicy {
    static func shouldInclude(rating: BabyPlayerRating) -> Bool {
        rating != .blocked
    }
}

enum BabyPlayerRepeatMode {
    case stopAtEnd
    case repeatOne
    case repeatAll
}

enum BabyPlayerLyricsMode: String, CaseIterable, Identifiable {
    case off = "关闭"
    case english = "英文"
    case chinese = "中文"
    case bilingual = "中英双语"

    var id: String { rawValue }
}

enum BabyPlayerSmartSkipPreferencePolicy {
    /// Apple TV 本机的全局播放偏好默认开启；与媒体来源及当前歌曲无关。
    static func resolvedValue(storedValue: Bool?) -> Bool {
        storedValue ?? true
    }
}

/// ASR 重扫首先服务于声音证据和智能跳过。已有验证英文时直接复用，
/// 只有首次缺少 DeepSeek 结果才自动继续校准。
enum BabyPlayerPostASRWorkflowPolicy {
    static func shouldRunDeepSeek(existingResult: StoredLyricsAnalysisResult?) -> Bool {
        existingResult == nil
    }
}

/// 将服务端候选收缩为播放器可采用的边界；不修改歌词的媒体时间轴。
enum BabyPlayerSmartSkipBoundaryPolicy {
    static let minimumSkipSeconds = 3.0
    static let minimumPlayableBodySeconds = 10.0
    private static let introLyricSafetySeconds = 0.75
    private static let outroNaturalTailSeconds = 2.0

    static func storedBoundary(
        from plan: BabyPlayerVoiceWindowPlan?,
        expectedMediaDuration: Double?,
        asrSegments: [BabyPlayerASRSegment]? = nil
    ) -> StoredSmartPlaybackBoundary? {
        guard let plan,
              plan.fallbackReason == nil,
              plan.plannerStatus == "sparse" || plan.plannerStatus == "full_coverage",
              let duration = plan.mediaDurationSeconds,
              duration.isFinite,
              duration > minimumPlayableBodySeconds else { return nil }
        return validatedStoredBoundary(
            StoredSmartPlaybackBoundary(
                introEndSeconds: confirmedIntroEnd(
                    vadCandidate: plan.smartIntroEndSeconds,
                    segments: asrSegments
                ),
                outroStartSeconds: confirmedOutroStart(
                    vadCandidate: plan.smartOutroStartSeconds,
                    segments: asrSegments,
                    duration: duration
                ),
                mediaDurationSeconds: duration,
                plannerVersion: plan.plannerVersion,
                createdAt: Date()
            ),
            expectedMediaDuration: expectedMediaDuration
        )
    }

    /// VAD 只能说明“像人声”；真正跳点由第一段可信 ASR 歌词确认。
    /// 这会过滤掉“BD.”一类短噪声，但保留高人声置信的短唱词。
    private static func confirmedIntroEnd(
        vadCandidate: Double?,
        segments: [BabyPlayerASRSegment]?
    ) -> Double? {
        guard let segments else { return vadCandidate }
        guard vadCandidate != nil,
              let first = segments.first(where: isTrustworthyLyricSegment) else { return nil }
        return max(0, first.startSeconds - introLyricSafetySeconds)
    }

    /// 片尾同样用最后一段可信歌词收口，并留出少量安全余量。
    private static func confirmedOutroStart(
        vadCandidate: Double?,
        segments: [BabyPlayerASRSegment]?,
        duration: Double
    ) -> Double? {
        guard let segments else { return vadCandidate }
        guard vadCandidate != nil,
              let last = segments.last(where: isTrustworthyLyricSegment) else { return nil }
        return min(duration, last.endSeconds + outroNaturalTailSeconds)
    }

    private static func isTrustworthyLyricSegment(_ segment: BabyPlayerASRSegment) -> Bool {
        let lexicalWords = segment.words.filter { word in
            word.text.unicodeScalars.contains(where: CharacterSet.letters.contains)
                && word.isPossibleInstrumentalHallucination == false
        }
        let duration = segment.endSeconds - segment.startSeconds
        guard duration.isFinite, duration >= 0.5, !lexicalWords.isEmpty else { return false }
        if lexicalWords.count >= 2, duration >= 0.8 { return true }
        let scored = lexicalWords.compactMap(\.voiceActivityScore)
        guard !scored.isEmpty else { return false }
        return scored.reduce(0, +) / Double(scored.count) >= 0.45
    }

    /// 重新采用持久边界前校验媒体时长，防止同一 Jellyfin ID 被替换后沿用旧跳点。
    static func validatedStoredBoundary(
        _ boundary: StoredSmartPlaybackBoundary?,
        expectedMediaDuration: Double?
    ) -> StoredSmartPlaybackBoundary? {
        guard let boundary else { return nil }
        let duration = boundary.mediaDurationSeconds
        guard duration.isFinite, duration > minimumPlayableBodySeconds else { return nil }
        if let expectedMediaDuration,
           expectedMediaDuration.isFinite,
           expectedMediaDuration > 0 {
            let tolerance = max(2, expectedMediaDuration * 0.02)
            guard abs(duration - expectedMediaDuration) <= tolerance else { return nil }
        }
        let intro = boundary.introEndSeconds.flatMap { value -> Double? in
            guard value.isFinite,
                  value >= minimumSkipSeconds,
                  value <= duration - minimumPlayableBodySeconds else { return nil }
            return value
        }
        let outro = boundary.outroStartSeconds.flatMap { value -> Double? in
            guard value.isFinite,
                  value >= minimumPlayableBodySeconds,
                  duration - value >= minimumSkipSeconds else { return nil }
            return value
        }
        if let intro, let outro, outro - intro < minimumPlayableBodySeconds {
            return nil
        }
        guard intro != nil || outro != nil else { return nil }
        return StoredSmartPlaybackBoundary(
            introEndSeconds: intro,
            outroStartSeconds: outro,
            mediaDurationSeconds: duration,
            plannerVersion: boundary.plannerVersion,
            createdAt: boundary.createdAt
        )
    }
}

/// 播放边界只负责选优先级，不参与歌词选择、歌词偏移或 ASR 时间戳换算。
enum BabyPlayerPlaybackBoundaryPolicy {
    static func introTarget(
        chapter: Double?,
        smart: Double?,
        smartEnabled: Bool,
        manualSkipSeconds: Double,
        resumeTarget: Double?
    ) -> Double {
        let automatic = chapter ?? (smartEnabled ? smart : nil) ?? positive(manualSkipSeconds)
        return max(automatic ?? 0, resumeTarget ?? 0)
    }

    static func outroTarget(
        chapter: Double?,
        smart: Double?,
        smartEnabled: Bool,
        manualSkipSeconds: Double,
        duration: Double?
    ) -> Double? {
        if let chapter { return chapter }
        if smartEnabled, let smart { return smart }
        guard let manual = positive(manualSkipSeconds),
              let duration,
              duration.isFinite,
              duration > manual else { return nil }
        return duration - manual
    }

    private static func positive(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }
}

/// 智能片尾从安全边界开始渐弱，避免直接切到下一首。
enum BabyPlayerOutroTransitionPolicy {
    static let fadeDurationSeconds: TimeInterval = 1.5
    static let fadeStepCount = 6
}

// 【MODIFIED】版本化的字幕默认策略：本次升级会把旧的“关闭”一次性迁移为英文，之后仍尊重用户手工关闭。
enum BabyPlayerLyricsDefaultPolicy {
    static func resolvedMode(
        storedMode: BabyPlayerLyricsMode?,
        hasAppliedEnabledByDefaultMigration: Bool
    ) -> BabyPlayerLyricsMode {
        if !hasAppliedEnabledByDefaultMigration { return .english }
        return storedMode ?? .english
    }
}

/// 一条播放队列项；URL 可能包含授权信息，因此只保存在内存中。
struct BabyPlayerQueueItem: Identifiable {
    let id: String
    /// 评分、屏蔽和续播使用的跨来源身份；播放队列仍用 `id` 区分具体来源条目。
    let preferenceID: String
    let title: String
    /// HTTP/Jellyfin 播放地址；SMB 项使用自定义 scheme 作内存标识。
    let url: URL
    /// Samba 的延迟播放引用；Jellyfin 为 nil。
    let smbPlaybackResource: SMBPlaybackResource?
    let lyricsMedia: LyricsMediaDescriptor
    /// 【MODIFIED】仅作为 Mac 开发服务的本机文件定位，不写日志、不用于 Apple TV 直接读取。
    let localMediaPath: String?
    let chapterIntroEndSeconds: Double?
    let chapterOutroStartSeconds: Double?
    var smartIntroEndSeconds: Double?
    var smartOutroStartSeconds: Double?
}

/// 交给系统播放器的完整会话设置。
struct SpikePlaybackSelection: Identifiable {
    let id = UUID()
    let items: [BabyPlayerQueueItem]
    let startIndex: Int
    let repeatMode: BabyPlayerRepeatMode
    let repeatCount: Int
    let initialBehavior: BabyPlayerPlaybackBehavior
    let sessionDuration: TimeInterval?
    let introSkipSeconds: Double
    let outroSkipSeconds: Double
    let lyricsMode: BabyPlayerLyricsMode
    /// 是否采用 AI 分析出的智能边界；这是 Apple TV 本机、跨媒体源的全局偏好。
    let smartSkipEnabled: Bool
    /// 只用于会话首曲；自动切到后续曲目时始终从歌曲起点播放。
    let startPositionSeconds: Double?
}

/// 家长批量补全页中的单条状态；每首成功后立即持久化，停止或退出不会回滚已完成结果。
enum BabyPlayerBatchAnalysisItemState: Equatable {
    case completed
    case pending(String)
    case processing(String)
    case quotaLimited(String)
    case failed(String)

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }

    var detailText: String {
        switch self {
        case .completed: return "双语字幕已就绪"
        case .pending(let text), .processing(let text), .quotaLimited(let text), .failed(let text):
            return text
        }
    }
}

struct BabyPlayerBatchAnalysisItem: Identifiable, Equatable {
    let id: String
    let title: String
    let durationSeconds: Double?
    var requiresASR: Bool
    var state: BabyPlayerBatchAnalysisItemState
}

/// “已生成”表示完整 AI 资产已落到 Apple TV：ASR、DeepSeek 英文，以及英文歌曲所需的中文翻译。
/// 智能片头/片尾可能因没有可信边界而为空，但 ASR 已完成时不应无限重复分析。
enum BabyPlayerBatchAnalysisCompletionPolicy {
    static func isComplete(_ bundle: StoredLyricsAnalysisBundle?) -> Bool {
        guard let bundle,
              bundle.asrResult != nil,
              let deepSeek = bundle.deepSeekResult else { return false }
        guard BabyPlayerLyricsLanguagePolicy.isPredominantlyEnglish(
            deepSeek.candidate.lines
        ) else { return true }
        guard let translation = bundle.chineseTranslation else { return false }
        return BabyPlayerBilingualLyricsComposer.compose(
            english: deepSeek,
            translation: translation
        ) != nil
    }

    static func pendingStage(_ bundle: StoredLyricsAnalysisBundle?) -> String {
        guard let bundle, bundle.asrResult != nil else { return "待 ASR 与片头片尾分析" }
        guard let deepSeek = bundle.deepSeekResult else { return "待 DeepSeek 英文校准" }
        if BabyPlayerLyricsLanguagePolicy.isPredominantlyEnglish(deepSeek.candidate.lines),
           bundle.chineseTranslation == nil {
            return "待生成中文字幕"
        }
        return "待补全 AI 资产"
    }
}

/// Apple TV 本地续播点；不包含带授权信息的播放 URL。
struct BabyPlayerPlaybackResumeState: Codable, Equatable, Sendable {
    let itemID: String
    let positionSeconds: Double
    let durationSeconds: Double?
    let updatedAt: Date
}

enum BabyPlayerPlaybackResumePolicy {
    static let minimumPositionSeconds = 3.0
    static let completionToleranceSeconds = 5.0

    /// 过早退出或已到片尾不作为“未播完”，避免首页永久占位。
    static func resumablePosition(
        elapsed: Double,
        duration: Double?
    ) -> Double? {
        guard elapsed.isFinite, elapsed >= minimumPositionSeconds else { return nil }
        if let duration, duration.isFinite, duration > 0,
           elapsed >= duration - completionToleranceSeconds {
            return nil
        }
        return elapsed
    }

    /// 未播完曲目置顶，其余顺序保持不变。
    static func prioritizedIDs(_ ids: [String], resuming itemID: String?) -> [String] {
        guard let itemID, ids.contains(itemID) else { return ids }
        return [itemID] + ids.filter { $0 != itemID }
    }
}

private struct StoredJellyfinCredentials: Codable {
    let serverAddress: String
    let userID: String
    let accessToken: String
}

/// 访问令牌存入 Keychain，不写入 UserDefaults 或日志。
private enum JellyfinCredentialStore {
    private static let service = "com.wufengyu.BabyPlayer.jellyfin"
    private static let account = "default"
    #if DEBUG
    private static let simulatorFallbackKey = "BabyPlayer.Debug.JellyfinCredentials"
    #endif

    static func load() -> StoredJellyfinCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let credentials = try? JSONDecoder().decode(StoredJellyfinCredentials.self, from: data) {
            return credentials
        }
        #if DEBUG
        guard let fallbackData = UserDefaults.standard.data(forKey: simulatorFallbackKey) else { return nil }
        return try? JSONDecoder().decode(StoredJellyfinCredentials.self, from: fallbackData)
        #else
        return nil
        #endif
    }

    static func save(_ credentials: StoredJellyfinCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
        #if DEBUG
        // 无签名的 tvOS 模拟器包在重装时可能丢失 Keychain；仅 Debug 保存同一份本地兜底。
        UserDefaults.standard.set(data, forKey: simulatorFallbackKey)
        #endif
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: simulatorFallbackKey)
        #endif
    }
}

@MainActor
final class SpikeViewModel: ObservableObject {
    @Published var serverAddress = ""
    @Published private(set) var appState: BabyPlayerAppState = .onboarding
    @Published private(set) var onboardingStep: BabyPlayerOnboardingStep = .welcome
    @Published private(set) var statusText = ""
    @Published private(set) var quickConnectCode: String?
    @Published private(set) var mediaItems: [JellyfinMediaItem] = [] {
        didSet { registerJellyfinMediaItems(mediaItems) }
    }
    @Published private(set) var isWorking = false
    @Published var activePlayback: SpikePlaybackSelection?
    @Published private(set) var playbackResumeState: BabyPlayerPlaybackResumeState?
    @Published private(set) var ratings: [String: BabyPlayerRating] = [:]
    @Published private(set) var contentIdentityRevision = 0
    @Published var playbackTimerMinutes = 0 {
        didSet { UserDefaults.standard.set(playbackTimerMinutes, forKey: Self.playbackTimerKey) }
    }
    @Published var introSkipSeconds = 0 {
        didSet { UserDefaults.standard.set(introSkipSeconds, forKey: Self.introSkipKey) }
    }
    @Published var outroSkipSeconds = 0 {
        didSet { UserDefaults.standard.set(outroSkipSeconds, forKey: Self.outroSkipKey) }
    }
    @Published var lyricsMode: BabyPlayerLyricsMode = .english {
        didSet { UserDefaults.standard.set(lyricsMode.rawValue, forKey: Self.lyricsModeKey) }
    }
    @Published var smartSkipEnabled = true {
        didSet { UserDefaults.standard.set(smartSkipEnabled, forKey: Self.smartSkipEnabledKey) }
    }
    @Published private(set) var batchAnalysisItems: [BabyPlayerBatchAnalysisItem] = []
    @Published private(set) var batchAnalysisUsage: BabyPlayerASRUsage?
    @Published private(set) var batchAnalysisStatusText = "正在读取 AI 字幕状态…"
    @Published private(set) var isBatchAnalyzing = false
    @Published private(set) var isBatchAnalysisPaused = false

    private var authenticatedUserID: String?
    private var accessToken: String?
    private var operationTask: Task<Void, Never>?
    private var coverPrewarmTask: Task<Void, Never>?
    private var playbackPreparationTask: Task<Void, Never>?
    private var batchAnalysisTask: Task<Void, Never>?
    private var contentAliases: [String: String] = [:]
    private var contentTitles: [String: String] = [:]

    private static let playbackTimerKey = "BabyPlayer.PlaybackTimerMinutes"
    private static let introSkipKey = "BabyPlayer.IntroSkipSeconds"
    private static let outroSkipKey = "BabyPlayer.OutroSkipSeconds"
    private static let lyricsModeKey = "BabyPlayer.LyricsMode"
    private static let lyricsEnabledByDefaultMigrationKey = "BabyPlayer.LyricsEnabledByDefaultV1"
    private static let smartSkipEnabledKey = "BabyPlayer.SmartSkipEnabledV1"
    private static let ratingsKey = "BabyPlayer.MediaRatings"
    private static let playbackResumeKey = "BabyPlayer.PlaybackResumeV1"
    private static let contentAliasesKey = "BabyPlayer.ContentAliasesV1"
    private static let contentTitlesKey = "BabyPlayer.ContentTitlesV1"

    var completedBatchAnalysisItems: [BabyPlayerBatchAnalysisItem] {
        batchAnalysisItems.filter { $0.state.isCompleted }
    }

    var pendingBatchAnalysisItems: [BabyPlayerBatchAnalysisItem] {
        batchAnalysisItems.filter { !$0.state.isCompleted }
    }

    var batchAnalysisSummary: String {
        let completed = completedBatchAnalysisItems.count
        return "总计 \(batchAnalysisItems.count) · 已完成 \(completed) · 待生成 \(max(0, batchAnalysisItems.count - completed))"
    }

    var batchAnalysisUsageText: String {
        guard let usage = batchAnalysisUsage else { return "ASR 额度读取中…" }
        return "ASR 剩余 \(formatBatchDuration(usage.remainingSeconds)) / \(formatBatchDuration(usage.limitSeconds)) · 预计可新增 \(estimatedBatchASRItemCount(using: usage.remainingSeconds)) 条"
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.playbackTimerKey) != nil {
            playbackTimerMinutes = max(0, defaults.integer(forKey: Self.playbackTimerKey))
        }
        if defaults.object(forKey: Self.introSkipKey) != nil {
            introSkipSeconds = max(0, defaults.integer(forKey: Self.introSkipKey))
        }
        if defaults.object(forKey: Self.outroSkipKey) != nil {
            outroSkipSeconds = max(0, defaults.integer(forKey: Self.outroSkipKey))
        }
        let savedLyricsMode = defaults.string(forKey: Self.lyricsModeKey)
            .flatMap(BabyPlayerLyricsMode.init(rawValue:))
        let hasAppliedLyricsMigration = defaults.bool(
            forKey: Self.lyricsEnabledByDefaultMigrationKey
        )
        lyricsMode = BabyPlayerLyricsDefaultPolicy.resolvedMode(
            storedMode: savedLyricsMode,
            hasAppliedEnabledByDefaultMigration: hasAppliedLyricsMigration
        )
        if !hasAppliedLyricsMigration {
            defaults.set(lyricsMode.rawValue, forKey: Self.lyricsModeKey)
            defaults.set(true, forKey: Self.lyricsEnabledByDefaultMigrationKey)
        }
        let storedSmartSkipEnabled = defaults.object(forKey: Self.smartSkipEnabledKey).map { _ in
            defaults.bool(forKey: Self.smartSkipEnabledKey)
        }
        smartSkipEnabled = BabyPlayerSmartSkipPreferencePolicy.resolvedValue(
            storedValue: storedSmartSkipEnabled
        )
        if storedSmartSkipEnabled == nil {
            defaults.set(smartSkipEnabled, forKey: Self.smartSkipEnabledKey)
        }
        #if DEBUG
        print("BABYPLAYER_SMART_SKIP_SETTING enabled=\(smartSkipEnabled)")
        #endif
        if let storedRatings = defaults.dictionary(forKey: Self.ratingsKey) as? [String: String] {
            ratings = storedRatings.reduce(into: [:]) { result, entry in
                if let rating = BabyPlayerRating(rawValue: entry.value), rating != .unrated {
                    result[entry.key] = rating
                }
            }
        }
        if let data = defaults.data(forKey: Self.playbackResumeKey) {
            playbackResumeState = try? JSONDecoder().decode(
                BabyPlayerPlaybackResumeState.self,
                from: data
            )
        }
        contentAliases = defaults.dictionary(forKey: Self.contentAliasesKey) as? [String: String] ?? [:]
        contentTitles = defaults.dictionary(forKey: Self.contentTitlesKey) as? [String: String] ?? [:]
        applyContentIdentityMigration()
        Task { [weak self] in
            let persistedAliases = await BabyLyricsRepository.shared.persistedContentAliases()
            self?.registerPersistedContentAliases(persistedAliases)
        }

        guard let credentials = JellyfinCredentialStore.load() else { return }
        serverAddress = credentials.serverAddress
        BabyPlayerServiceConfiguration.updateJellyfinServerAddress(credentials.serverAddress)
        authenticatedUserID = credentials.userID
        accessToken = credentials.accessToken
        appState = .loading
        operationTask = Task { [weak self] in
            await self?.restoreSavedSession()
        }
    }

    /// BabyPlayer 只读取 Jellyfin 的“音乐视频”库，因此首页无需再做伪分类。
    var filteredMediaItems: [JellyfinMediaItem] {
        let visible = mediaItems.filter { rating(for: $0.id) != .blocked }
        guard let resumeID = playbackResumeState?.itemID,
              let current = visible.first(where: { preferenceID(for: $0.id) == resumeID }) else {
            return visible
        }
        return [current] + visible.filter { preferenceID(for: $0.id) != resumeID }
    }

    /// 屏蔽清单按内容身份保存；当前媒体源离线时也能显示和解除。
    var blockedContentItems: [BabyPlayerBlockedContentItem] {
        ratings.compactMap { contentID, rating in
            guard rating == .blocked else { return nil }
            return BabyPlayerBlockedContentItem(
                id: contentID,
                title: contentTitles[contentID] ?? "已屏蔽视频"
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var connectionSummary: String {
        accessToken == nil ? "未连接" : "已连接"
    }

    func showServerStep() {
        onboardingStep = .server
        statusText = ""
    }

    /// 检查服务器并启动 Quick Connect；批准后自动换取令牌并读取媒体库。
    func beginQuickConnect() {
        replaceOperation { [weak self] in
            guard let self else { return }
            do {
                let client = try self.makeClient()
                let info = try await client.fetchPublicInfo()
                guard info.startupWizardCompleted else {
                    self.statusText = "Jellyfin 还没准备好，请先完成 Mac 上的初始设置。"
                    return
                }
                guard try await client.isQuickConnectEnabled() else {
                    throw JellyfinSpikeError.quickConnectDisabled
                }

                let request = try await client.initiateQuickConnect()
                self.quickConnectCode = request.code
                self.onboardingStep = .code
                self.statusText = "请在 Mac 上的 Jellyfin 中输入这个数字码"

                for _ in 0..<90 {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let state = try await client.fetchQuickConnectState(secret: request.secret)
                    guard state.authenticated else { continue }

                    let authentication = try await client.authenticateWithQuickConnect(secret: request.secret)
                    guard let userID = authentication.user?.id,
                          let accessToken = authentication.accessToken else {
                        throw JellyfinSpikeError.incompleteAuthentication
                    }

                    let videos = try await client.fetchVideos(userID: userID, accessToken: accessToken)
                    self.authenticatedUserID = userID
                    self.accessToken = accessToken
                    self.mediaItems = videos
                    self.prewarmCovers(for: videos)
                    JellyfinCredentialStore.save(
                        StoredJellyfinCredentials(
                            serverAddress: self.serverAddress,
                            userID: userID,
                            accessToken: accessToken
                        )
                    )
                    BabyPlayerServiceConfiguration.updateJellyfinServerAddress(self.serverAddress)
                    self.quickConnectCode = nil
                    self.statusText = "已找到 \(videos.count) 个视频"
                    self.onboardingStep = .success
                    return
                }

                self.statusText = "配对码已超时，请重试。"
            } catch is CancellationError {
                return
            } catch {
                self.statusText = self.readableMessage(for: error)
            }
        }
    }

    func enterHome() {
        guard !mediaItems.isEmpty else {
            appState = .unavailable
            return
        }
        appState = .home
        statusText = ""
    }

    func retryLoading() {
        guard authenticatedUserID != nil, accessToken != nil else {
            startRePairing()
            return
        }
        appState = .loading
        operationTask = Task { [weak self] in
            await self?.restoreSavedSession()
        }
    }

    func refreshVideos() {
        guard let authenticatedUserID, let accessToken else {
            startRePairing()
            return
        }
        replaceOperation { [weak self] in
            guard let self else { return }
            do {
                let videos = try await self.makeClient().fetchVideos(
                    userID: authenticatedUserID,
                    accessToken: accessToken
                )
                self.mediaItems = videos
                self.prewarmCovers(for: videos)
                self.statusText = "已更新 \(videos.count) 个视频"
            } catch {
                self.statusText = self.readableMessage(for: error)
            }
        }
    }

    /// 让 Jellyfin 先重新扫描磁盘目录，扫描完成后再替换 BabyPlayer 列表。
    func rescanLibrary() {
        guard let authenticatedUserID, let accessToken else {
            startRePairing()
            return
        }
        replaceOperation { [weak self] in
            guard let self else { return }
            do {
                let client = try self.makeClient()
                self.statusText = "正在扫描媒体库…"
                try await client.startLibraryScan(accessToken: accessToken)

                var hasSeenRunningTask = false
                for attempt in 0..<30 {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if let isRunning = try? await client.isLibraryScanRunning(accessToken: accessToken) {
                        if isRunning {
                            hasSeenRunningTask = true
                        } else if hasSeenRunningTask || attempt >= 5 {
                            break
                        }
                    } else if attempt >= 7 {
                        break
                    }
                }

                let videos = try await client.fetchVideos(
                    userID: authenticatedUserID,
                    accessToken: accessToken
                )
                self.mediaItems = videos
                self.prewarmCovers(for: videos)
                self.statusText = "扫描完成，现在有 \(videos.count) 个视频"
            } catch is CancellationError {
                return
            } catch {
                self.statusText = self.readableMessage(for: error)
            }
        }
    }

    func startRePairing() {
        operationTask?.cancel()
        coverPrewarmTask?.cancel()
        operationTask = nil
        quickConnectCode = nil
        isWorking = false
        onboardingStep = .server
        appState = .onboarding
        statusText = ""
    }

    func clearPairing() {
        operationTask?.cancel()
        coverPrewarmTask?.cancel()
        playbackPreparationTask?.cancel()
        batchAnalysisTask?.cancel()
        operationTask = nil
        batchAnalysisTask = nil
        JellyfinCredentialStore.delete()
        BabyPlayerServiceConfiguration.updateJellyfinServerAddress(nil)
        authenticatedUserID = nil
        accessToken = nil
        mediaItems = []
        quickConnectCode = nil
        isWorking = false
        isBatchAnalyzing = false
        isBatchAnalysisPaused = false
        batchAnalysisItems = []
        onboardingStep = .welcome
        appState = .onboarding
        statusText = ""
    }

    /// 为 UI 提供跨媒体源的封面输入；来源自带封面优先，缺失时提供视频 URL 给抽帧器。
    func coverSource(for item: JellyfinMediaItem) -> BabyPlayerCoverSource? {
        guard let accessToken,
              let client = try? makeClient(),
              let videoURL = try? client.directPlaybackURL(for: item, accessToken: accessToken)
        else { return nil }
        let duration = item.runTimeTicks.map { Double($0) / 10_000_000.0 }
        return BabyPlayerCoverSource(
            providerImageURL: client.primaryImageURL(for: item, accessToken: accessToken),
            videoURL: videoURL,
            smbPlaybackResource: nil,
            duration: duration,
            cacheKey: "jellyfin:\(item.id)"
        )
    }

    /// 点击封面默认无限循环当前歌曲；播放页可随时切换模式。
    func play(_ item: JellyfinMediaItem) {
        guard let index = filteredMediaItems.firstIndex(where: { $0.id == item.id }) else { return }
        // 封面点播默认只循环当前歌曲，但把完整库交给播放器，便于播放中切换为顺序或随机。
        presentPlayback(
            items: filteredMediaItems,
            startIndex: index,
            behaviorOverride: .repeatOne
        )
    }

    /// 顶部快捷按钮总是完整播放列表；卡片点播仍遵循家长设置。
    func playAll(shuffled: Bool) {
        guard !filteredMediaItems.isEmpty else { return }
        presentPlayback(
            items: filteredMediaItems,
            startIndex: 0,
            behaviorOverride: shuffled ? .shuffle : .sequential
        )
    }

    /// 【MODIFIED】按照本地偏好播放：喜欢优先，未评分随机，不喜欢排在最后。
    func playAllByPreference() {
        let visibleItems = filteredMediaItems
        guard !visibleItems.isEmpty else { return }
        let liked = visibleItems.filter { rating(for: $0.id) == .liked }.shuffled()
        let unrated = visibleItems.filter { rating(for: $0.id) == .unrated }.shuffled()
        let disliked = visibleItems.filter { rating(for: $0.id) == .disliked }.shuffled()
        presentPlayback(
            items: liked + unrated + disliked,
            startIndex: 0,
            behaviorOverride: .sequential
        )
    }

    /// 返回视频当前的本地偏好；没有记录时返回未评分。
    func rating(for itemID: String) -> BabyPlayerRating {
        ratings[preferenceID(for: itemID)] ?? .unrated
    }

    /// 【MODIFIED】保存本地偏好；不触碰 Jellyfin、U 盘或 NAS 中的原始视频。
    func setRating(_ rating: BabyPlayerRating, for itemID: String) {
        let itemID = preferenceID(for: itemID)
        if rating == .unrated {
            ratings.removeValue(forKey: itemID)
        } else {
            ratings[itemID] = rating
        }
        persistRatings()
    }

    /// 家长从设置页解除屏蔽；解除后项目回到未评分状态，不自动提升排序。
    func unblock(contentID: String) {
        setRating(.unrated, for: contentID)
    }

    func preferenceID(for sourceID: String) -> String {
        contentAliases[sourceID] ?? sourceID
    }

    func contentMigrationKey(for sourceID: String) -> String? {
        let resolved = preferenceID(for: sourceID)
        return resolved.hasPrefix("filename-sha256:") ? resolved : nil
    }

    /// 来源适配器在拿到目录后登记一次别名；之后运行只依赖 Apple TV 本地映射。
    func registerSMBMediaItems(_ items: [SMBSpikeMediaItem]) {
        registerContentItems(items.map {
            BabyPlayerContentIdentityInput(
                sourceID: "smb:\($0.path)",
                displayName: $0.displayName,
                fileNameOrPath: $0.name
            )
        })
    }

    private func registerJellyfinMediaItems(_ items: [JellyfinMediaItem]) {
        registerContentItems(items.map {
            BabyPlayerContentIdentityInput(
                sourceID: $0.id,
                displayName: $0.name,
                fileNameOrPath: $0.path ?? $0.name
            )
        })
    }

    private func registerContentItems(_ items: [BabyPlayerContentIdentityInput]) {
        guard !items.isEmpty else { return }
        let resolved = BabyPlayerContentIdentityResolver.mappings(for: items)
        var changed = false
        for item in items {
            let contentID = resolved[item.sourceID] ?? item.sourceID
            if contentAliases[item.sourceID] != contentID {
                contentAliases[item.sourceID] = contentID
                changed = true
            }
            if contentTitles[contentID] != item.displayName {
                contentTitles[contentID] = item.displayName
                changed = true
            }
        }
        guard changed else { return }
        UserDefaults.standard.set(contentAliases, forKey: Self.contentAliasesKey)
        UserDefaults.standard.set(contentTitles, forKey: Self.contentTitlesKey)
        applyContentIdentityMigration()
        contentIdentityRevision &+= 1
        logSharedContentState()
    }

    private func registerPersistedContentAliases(
        _ aliases: [BabyPlayerPersistedContentAlias]
    ) {
        guard !aliases.isEmpty else { return }
        var changed = false
        for alias in aliases {
            if contentAliases[alias.sourceID] != alias.contentID {
                contentAliases[alias.sourceID] = alias.contentID
                changed = true
            }
            if contentTitles[alias.contentID] == nil {
                contentTitles[alias.contentID] = alias.title
                changed = true
            }
        }
        guard changed else { return }
        UserDefaults.standard.set(contentAliases, forKey: Self.contentAliasesKey)
        UserDefaults.standard.set(contentTitles, forKey: Self.contentTitlesKey)
        applyContentIdentityMigration()
        contentIdentityRevision &+= 1
        logSharedContentState()
    }

    private func applyContentIdentityMigration() {
        let migratedRatings = BabyPlayerContentIdentityResolver.migratedRatings(
            ratings,
            aliases: contentAliases
        )
        if migratedRatings != ratings {
            ratings = migratedRatings
            persistRatings()
        }
        let migratedResume = BabyPlayerContentIdentityResolver.migratedResumeState(
            playbackResumeState,
            aliases: contentAliases
        )
        if migratedResume != playbackResumeState {
            playbackResumeState = migratedResume
            persistPlaybackResume()
        }
    }

    private func persistRatings() {
        UserDefaults.standard.set(ratings.mapValues(\.rawValue), forKey: Self.ratingsKey)
    }

    private func persistPlaybackResume() {
        if let playbackResumeState,
           let data = try? JSONEncoder().encode(playbackResumeState) {
            UserDefaults.standard.set(data, forKey: Self.playbackResumeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.playbackResumeKey)
        }
    }

    private func logSharedContentState() {
        #if DEBUG
        let sharedRatings = ratings.keys.filter { $0.hasPrefix("filename-sha256:") }.count
        let legacyRatings = ratings.count - sharedRatings
        let blocked = ratings.values.filter { $0 == .blocked }.count
        let resumeShared = playbackResumeState?.itemID.hasPrefix("filename-sha256:") ?? true
        print(
            "BABYPLAYER_SHARED_STATE_RESULT "
                + "aliases=\(contentAliases.count) ratings=\(ratings.count) "
                + "shared_ratings=\(sharedRatings) legacy_ratings=\(legacyRatings) "
                + "blocked=\(blocked) resume_shared=\(resumeShared)"
        )
        #endif
    }

    func endPlayback() {
        activePlayback = nil
    }

    /// 保存当前未播完曲目；自然播完或靠近片尾时清除。
    func updatePlaybackResume(
        itemID: String,
        elapsed: Double,
        duration: Double?
    ) {
        guard let position = BabyPlayerPlaybackResumePolicy.resumablePosition(
            elapsed: elapsed,
            duration: duration
        ) else {
            if playbackResumeState?.itemID == itemID {
                playbackResumeState = nil
                UserDefaults.standard.removeObject(forKey: Self.playbackResumeKey)
            }
            return
        }
        // 每两秒一个持久点已足够精确，避免 0.5 秒回调频繁写入。
        if let existing = playbackResumeState,
           existing.itemID == itemID,
           abs(existing.positionSeconds - position) < 2 {
            return
        }
        let state = BabyPlayerPlaybackResumeState(
            itemID: itemID,
            positionSeconds: position,
            durationSeconds: duration,
            updatedAt: Date()
        )
        playbackResumeState = state
        persistPlaybackResume()
    }

    func clearPlaybackResume(for itemID: String) {
        guard playbackResumeState?.itemID == itemID else { return }
        playbackResumeState = nil
        UserDefaults.standard.removeObject(forKey: Self.playbackResumeKey)
    }

    func incrementPlaybackTimer() { playbackTimerMinutes = min(180, playbackTimerMinutes + 5) }
    func decrementPlaybackTimer() { playbackTimerMinutes = max(0, playbackTimerMinutes - 5) }
    func incrementIntroSkip() { introSkipSeconds = min(120, introSkipSeconds + 5) }
    func decrementIntroSkip() { introSkipSeconds = max(0, introSkipSeconds - 5) }
    func incrementOutroSkip() { outroSkipSeconds = min(120, outroSkipSeconds + 5) }
    func decrementOutroSkip() { outroSkipSeconds = max(0, outroSkipSeconds - 5) }

    /// 刷新家长页统计；只读取 Apple TV 已保存结果和 ASR 额度，不触发任何付费分析。
    func refreshBatchAnalysisInventory() {
        Task { [weak self] in
            guard let self else { return }
            await self.rebuildBatchAnalysisInventory()
            await self.refreshBatchAnalysisUsage()
        }
    }

    /// 从未完成项继续；任务使用 utility 优先级且不控制播放器，前台播放可照常进行。
    func startBatchAnalysis() {
        guard !isBatchAnalyzing else { return }
        batchAnalysisTask?.cancel()
        isBatchAnalyzing = true
        isBatchAnalysisPaused = false
        batchAnalysisStatusText = "正在准备批量 AI 任务…"
        batchAnalysisTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runBatchAnalysis()
        }
    }

    func stopBatchAnalysis() {
        batchAnalysisTask?.cancel()
        batchAnalysisTask = nil
        isBatchAnalyzing = false
        isBatchAnalysisPaused = true
        batchAnalysisStatusText = "任务已暂停；已完成结果均已保存，可随时继续"
    }

    private func rebuildBatchAnalysisInventory() async {
        var inventory: [BabyPlayerBatchAnalysisItem] = []
        for item in batchEligibleMediaItems {
            let descriptor = analysisDescriptor(for: item)
            let bundle = await BabyLyricsRepository.shared.analysisBundle(for: descriptor)
            inventory.append(
                BabyPlayerBatchAnalysisItem(
                    id: item.id,
                    title: item.name,
                    durationSeconds: descriptor.expectedSongDurationSeconds
                        ?? descriptor.durationSeconds,
                    requiresASR: bundle?.asrResult == nil,
                    state: BabyPlayerBatchAnalysisCompletionPolicy.isComplete(bundle)
                        ? .completed
                        : .pending(BabyPlayerBatchAnalysisCompletionPolicy.pendingStage(bundle))
                )
            )
        }
        batchAnalysisItems = inventory
        if inventory.isEmpty {
            batchAnalysisStatusText = "媒体库中没有可处理的未屏蔽视频"
        } else if !isBatchAnalyzing {
            batchAnalysisStatusText = "已有结果直接复用；未完成项会从缺失阶段继续"
        }
    }

    private func refreshBatchAnalysisUsage() async {
        do {
            batchAnalysisUsage = try await BabyPlayerASRClient().usage()
        } catch {
            if !isBatchAnalyzing {
                batchAnalysisStatusText = (error as? LocalizedError)?.errorDescription
                    ?? "暂时无法读取 ASR 额度"
            }
        }
    }

    private func runBatchAnalysis() async {
        defer {
            isBatchAnalyzing = false
            batchAnalysisTask = nil
        }

        await rebuildBatchAnalysisInventory()
        await refreshBatchAnalysisUsage()
        guard !Task.isCancelled else { return }

        let queue = await makeQueueItems(from: batchEligibleMediaItems)
        let queueIDs = Set(queue.map(\.id))
        for index in batchAnalysisItems.indices
        where !queueIDs.contains(batchAnalysisItems[index].id)
            && !batchAnalysisItems[index].state.isCompleted {
            batchAnalysisItems[index].state = .failed("媒体地址：无法建立播放地址")
        }

        var partialItems: [BabyPlayerQueueItem] = []
        var asrItems: [BabyPlayerQueueItem] = []
        for item in queue {
            let bundle = await BabyLyricsRepository.shared.analysisBundle(for: item.lyricsMedia)
            guard !BabyPlayerBatchAnalysisCompletionPolicy.isComplete(bundle) else { continue }
            if bundle?.asrResult == nil {
                asrItems.append(item)
            } else {
                partialItems.append(item)
            }
        }
        // 先补完不消耗 ASR 的半成品，再用剩余额度优先覆盖更多短视频。
        asrItems.sort {
            ($0.lyricsMedia.expectedSongDurationSeconds ?? .greatestFiniteMagnitude)
                < ($1.lyricsMedia.expectedSongDurationSeconds ?? .greatestFiniteMagnitude)
        }
        let orderedItems = partialItems + asrItems
        guard !orderedItems.isEmpty else {
            batchAnalysisStatusText = "全部视频的双语 AI 字幕都已生成"
            return
        }

        for (position, item) in orderedItems.enumerated() {
            guard !Task.isCancelled else { return }
            let progressPrefix = "\(position + 1)/\(orderedItems.count) · \(item.title)"
            var bundle = await BabyLyricsRepository.shared.analysisBundle(for: item.lyricsMedia)
            if BabyPlayerBatchAnalysisCompletionPolicy.isComplete(bundle) {
                setBatchItemState(id: item.id, state: .completed)
                continue
            }

            if bundle?.asrResult == nil {
                setBatchItemState(id: item.id, state: .processing("ASR 与片头片尾分析中"))
                batchAnalysisStatusText = progressPrefix + " · ASR 与片头片尾"
                do {
                    let analysis = try await BabyPlayerASRCoordinator.shared.recognize(
                        item: item,
                        forceRefresh: false,
                        onStage: { [weak self] stage in
                            guard let self else { return }
                            let detail = self.batchStageText(stage)
                            self.setBatchItemState(
                                id: item.id,
                                state: .processing(detail)
                            )
                            self.batchAnalysisStatusText = progressPrefix + " · " + detail
                        }
                    )
                    let candidate = try analysis.lyricsCandidate(
                        title: item.lyricsMedia.searchTitle,
                        mediaFingerprint: item.lyricsMedia.asrFingerprint
                    )
                    bundle = try await BabyLyricsRepository.shared.storeASRResult(
                        candidate,
                        asrEvidenceHash: analysis.evidenceHash,
                        smartPlaybackBoundary: BabyPlayerSmartSkipBoundaryPolicy.storedBoundary(
                            from: analysis.voiceWindowPlan,
                            expectedMediaDuration: item.lyricsMedia.durationSeconds,
                            asrSegments: analysis.segments
                        ),
                        for: item.lyricsMedia
                    )
                    setBatchItemRequiresASR(id: item.id, requiresASR: false)
                    await refreshBatchAnalysisUsage()
                } catch is CancellationError {
                    return
                } catch {
                    let message = BabyPlayerAnalysisErrorPresentation.message(
                        error,
                        fallback: "ASR 处理失败"
                    )
                    if let asrError = error as? BabyPlayerASRError,
                       case .monthlyLimit = asrError {
                        setBatchItemState(id: item.id, state: .quotaLimited("ASR 额度：" + message))
                    } else {
                        setBatchItemState(id: item.id, state: .failed("ASR：" + message))
                    }
                    isBatchAnalysisPaused = true
                    batchAnalysisStatusText = "已暂停：\(item.title) 的 ASR 失败 · \(message)"
                    return
                }
            }

            guard !Task.isCancelled, let asrResult = bundle?.asrResult else { return }
            if bundle?.deepSeekResult == nil {
                setBatchItemState(id: item.id, state: .processing("DeepSeek 英文校准中"))
                batchAnalysisStatusText = progressPrefix + " · DeepSeek 英文校准"
                do {
                    let candidates = (try? await BabyLyricsRepository.shared.searchCandidates(
                        for: item.lyricsMedia
                    )) ?? []
                    let reconciliation = try await runBatchAuxiliaryStage(
                        name: "DeepSeek",
                        itemID: item.id,
                        progressPrefix: progressPrefix
                    ) { attempt in
                        try await BabyPlayerASRCoordinator.shared.reconcile(
                            item: item,
                            candidates: Array(candidates.prefix(3)),
                            forceRefresh: attempt > 1
                        )
                    }
                    bundle = try await BabyLyricsRepository.shared.storeDeepSeekResult(
                        reconciliation.candidate,
                        asrEvidenceHash: asrResult.asrEvidenceHash,
                        for: item.lyricsMedia
                    )
                } catch is CancellationError {
                    return
                } catch {
                    let message = BabyPlayerAnalysisErrorPresentation.message(
                        error,
                        fallback: "DeepSeek 校准失败"
                    )
                    setBatchItemState(id: item.id, state: .failed("DeepSeek：" + message))
                    batchAnalysisStatusText = progressPrefix + " · " + message
                    continue
                }
            }

            guard !Task.isCancelled, let english = bundle?.deepSeekResult else { continue }
            if BabyPlayerLyricsLanguagePolicy.isPredominantlyEnglish(english.candidate.lines),
               bundle?.chineseTranslation == nil {
                setBatchItemState(id: item.id, state: .processing("中文字幕生成中"))
                batchAnalysisStatusText = progressPrefix + " · 中文字幕"
                do {
                    let translation = try await runBatchAuxiliaryStage(
                        name: "中文字幕",
                        itemID: item.id,
                        progressPrefix: progressPrefix
                    ) { _ in
                        try await BabyPlayerLyricsTranslationClient().translate(
                            english: english,
                            mediaFingerprint: item.lyricsMedia.translationFingerprint
                        )
                    }
                    bundle = try await BabyLyricsRepository.shared.storeChineseTranslation(
                        translation,
                        for: item.lyricsMedia
                    )
                } catch is CancellationError {
                    return
                } catch {
                    let message = BabyPlayerAnalysisErrorPresentation.message(
                        error,
                        fallback: "中文字幕生成失败"
                    )
                    setBatchItemState(id: item.id, state: .failed("中文字幕：" + message))
                    batchAnalysisStatusText = progressPrefix + " · " + message
                    continue
                }
            }

            if BabyPlayerBatchAnalysisCompletionPolicy.isComplete(bundle) {
                setBatchItemState(id: item.id, state: .completed)
                batchAnalysisStatusText = progressPrefix + " · 已保存到 Apple TV"
            } else {
                setBatchItemState(id: item.id, state: .failed("AI 结果不完整，可稍后继续"))
            }
        }

        await refreshBatchAnalysisUsage()
        let failedCount = pendingBatchAnalysisItems.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
        batchAnalysisStatusText = failedCount == 0
            ? "本轮可生成项目已全部完成"
            : "本轮完成；另有 \(failedCount) 条可稍后继续"
    }

    private func setBatchItemState(id: String, state: BabyPlayerBatchAnalysisItemState) {
        guard let index = batchAnalysisItems.firstIndex(where: { $0.id == id }) else { return }
        batchAnalysisItems[index].state = state
    }

    private func setBatchItemRequiresASR(id: String, requiresASR: Bool) {
        guard let index = batchAnalysisItems.firstIndex(where: { $0.id == id }) else { return }
        batchAnalysisItems[index].requiresASR = requiresASR
    }

    /// DeepSeek 与翻译允许短暂网络错误自动重试；ASR 不走这里，仍按家长规则首次失败即暂停。
    private func runBatchAuxiliaryStage<T>(
        name: String,
        itemID: String,
        progressPrefix: String,
        operation: (Int) async throws -> T
    ) async throws -> T {
        let maximumAttempts = 3
        for attempt in 1...maximumAttempts {
            do {
                return try await operation(attempt)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < maximumAttempts,
                      BabyPlayerAIAnalysisRetryPolicy.shouldRetry(error) else {
                    throw error
                }
                let delay = BabyPlayerAIAnalysisRetryPolicy.delay(afterFailureCount: attempt)
                let retryText = "\(name) 暂时失败，\(Int(delay)) 秒后重试（\(attempt)/\(maximumAttempts)）"
                setBatchItemState(id: itemID, state: .processing(retryText))
                batchAnalysisStatusText = progressPrefix + " · " + retryText
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw BabyPlayerASRError.invalidResponse
    }

    private func batchStageText(_ stage: BabyPlayerASRProcessingStage) -> String {
        switch stage {
        case .preparingAudio: return "准备 ASR 音频"
        case .recognizing: return "ASR 识别中"
        case .aligning: return "时间轴对齐中"
        case .refining: return "歌词优化中"
        }
    }

    private func estimatedBatchASRItemCount(using remainingSeconds: Int) -> Int {
        var remaining = Double(max(0, remainingSeconds))
        var count = 0
        let durations = pendingBatchAnalysisItems
            .filter(\.requiresASR)
            .compactMap(\.durationSeconds)
            .filter { $0.isFinite && $0 > 0 }
            .sorted()
        for duration in durations where duration <= remaining {
            remaining -= ceil(duration)
            count += 1
        }
        return count
    }

    private func formatBatchDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(minutes) 分"
    }

    private var batchEligibleMediaItems: [JellyfinMediaItem] {
        mediaItems.filter {
            BabyPlayerBatchEligibilityPolicy.shouldInclude(rating: rating(for: $0.id))
        }
    }

    private func restoreSavedSession() async {
        guard let authenticatedUserID, let accessToken else {
            appState = .onboarding
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try Task.checkCancellation()
            let videos = try await makeClient().fetchVideos(
                userID: authenticatedUserID,
                accessToken: accessToken
            )
            try Task.checkCancellation()
            mediaItems = videos
            prewarmCovers(for: videos)
            appState = .home
            statusText = ""
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            appState = .unavailable
            statusText = "暂时看不到内容，请稍后再试"
        }
    }

    /// 【MODIFIED】媒体列表到达后在后台预热缺失封面，不阻塞首页和播放入口。
    private func prewarmCovers(for items: [JellyfinMediaItem]) {
        coverPrewarmTask?.cancel()
        let sources = items.compactMap { coverSource(for: $0) }
        coverPrewarmTask = Task.detached(priority: .utility) {
            await BabyPlayerCoverGenerator.prewarm(sources: sources)
        }
    }

    private func presentPlayback(
        items: [JellyfinMediaItem],
        startIndex: Int,
        behaviorOverride: BabyPlayerPlaybackBehavior? = nil
    ) {
        playbackPreparationTask?.cancel()
        playbackPreparationTask = Task { [weak self] in
            await self?.prepareAndPresentPlayback(
                items: items,
                startIndex: startIndex,
                behaviorOverride: behaviorOverride
            )
        }
    }

    private func prepareAndPresentPlayback(
        items: [JellyfinMediaItem],
        startIndex: Int,
        behaviorOverride: BabyPlayerPlaybackBehavior?
    ) async {
        guard accessToken != nil else {
            startRePairing()
            return
        }
        let queue = await makeQueueItems(from: items)
        guard !queue.isEmpty else {
            statusText = "这些视频暂时无法播放"
            return
        }

        let effectiveBehavior = behaviorOverride ?? .repeatOne
        let repeatMode: BabyPlayerRepeatMode
        switch effectiveBehavior {
        case .repeatOne:
            repeatMode = .repeatOne
        case .repeatAll:
            repeatMode = .repeatAll
        case .sequential, .shuffle:
            repeatMode = .stopAtEnd
        }

        let requestedStartID = items.indices.contains(startIndex) ? items[startIndex].id : nil
        let queueStartIndex = requestedStartID.flatMap { requestedID in
            queue.firstIndex(where: { $0.id == requestedID })
        } ?? 0

        activePlayback = SpikePlaybackSelection(
            items: queue,
            startIndex: queueStartIndex,
            repeatMode: repeatMode,
            repeatCount: effectiveBehavior == .repeatOne ? 0 : 1,
            initialBehavior: effectiveBehavior,
            sessionDuration: playbackTimerMinutes == 0 ? nil : TimeInterval(playbackTimerMinutes * 60),
            introSkipSeconds: Double(introSkipSeconds),
            outroSkipSeconds: Double(outroSkipSeconds),
            lyricsMode: lyricsMode,
            smartSkipEnabled: smartSkipEnabled,
            startPositionSeconds: playbackResumeState.flatMap { state in
                state.itemID == queue[queueStartIndex].preferenceID ? state.positionSeconds : nil
            }
        )
    }

    /// 统一把媒体源项目变成播放器/后台 AI 都可消费的队列；只生成 URL 和读取本地智能边界。
    private func makeQueueItems(from items: [JellyfinMediaItem]) async -> [BabyPlayerQueueItem] {
        guard let accessToken,
              let client = try? makeClient() else { return [] }
        var preparedItems: [(
            item: JellyfinMediaItem,
            url: URL,
            lyricsMedia: LyricsMediaDescriptor,
            chapterIntro: Double?,
            chapterOutro: Double?
        )] = []
        for item in items {
            guard !Task.isCancelled else { return [] }
            guard let url = try? client.directPlaybackURL(
                for: item,
                accessToken: accessToken
            ) else { continue }
            let markers = chapterMarkers(for: item)
            preparedItems.append((
                item,
                url,
                analysisDescriptor(for: item),
                markers.introEnd,
                markers.outroStart
            ))
        }
        let storedSmartConfigurations = await BabyLyricsRepository.shared
            .smartPlaybackConfigurations(for: preparedItems.map { $0.lyricsMedia })
        guard !Task.isCancelled else { return [] }
        return preparedItems.map { prepared in
            let storedConfiguration = storedSmartConfigurations[prepared.item.id]
            let storedSmartBoundary = BabyPlayerSmartSkipBoundaryPolicy.validatedStoredBoundary(
                storedConfiguration?.boundary,
                expectedMediaDuration: prepared.lyricsMedia.durationSeconds
            )
            return BabyPlayerQueueItem(
                id: prepared.item.id,
                preferenceID: preferenceID(for: prepared.item.id),
                title: prepared.item.name,
                url: prepared.url,
                smbPlaybackResource: nil,
                lyricsMedia: prepared.lyricsMedia,
                localMediaPath: prepared.item.path,
                chapterIntroEndSeconds: prepared.chapterIntro,
                chapterOutroStartSeconds: prepared.chapterOutro,
                smartIntroEndSeconds: storedSmartBoundary?.introEndSeconds,
                smartOutroStartSeconds: storedSmartBoundary?.outroStartSeconds
            )
        }
    }

    private func analysisDescriptor(for item: JellyfinMediaItem) -> LyricsMediaDescriptor {
        let markers = chapterMarkers(for: item)
        let duration = item.runTimeTicks.map { Double($0) / 10_000_000 }
        let inferredSongStart = markers.introEnd
            ?? (introSkipSeconds > 0 ? Double(introSkipSeconds) : nil)
        let inferredSongEnd = markers.outroStart
            ?? duration.flatMap { total in
                outroSkipSeconds > 0 && total > Double(outroSkipSeconds)
                    ? total - Double(outroSkipSeconds)
                    : nil
            }
        return Self.lyricsDescriptor(
            from: item,
            songStartSeconds: inferredSongStart,
            songEndSeconds: inferredSongEnd,
            localMediaMigrationKey: contentMigrationKey(for: item.id)
        )
    }

    private static func lyricsDescriptor(
        from item: JellyfinMediaItem,
        songStartSeconds: Double?,
        songEndSeconds: Double?,
        localMediaMigrationKey: String?
    ) -> LyricsMediaDescriptor {
        let titleMetadata = LyricsTitleMetadata.parse(item.name)
        return LyricsMediaDescriptor(
            id: item.id,
            title: item.name,
            searchTitle: titleMetadata.searchTitle,
            artistName: item.artists?.first,
            sourceHint: titleMetadata.sourceHint,
            versionHint: titleMetadata.versionHint,
            durationSeconds: item.runTimeTicks.map { Double($0) / 10_000_000 },
            songStartSeconds: songStartSeconds,
            songEndSeconds: songEndSeconds,
            mediaSourceID: item.mediaSources?.first?.id,
            localMediaMigrationKey: localMediaMigrationKey
        )
    }

    private func chapterMarkers(for item: JellyfinMediaItem) -> (introEnd: Double?, outroStart: Double?) {
        guard let chapters = item.chapters, !chapters.isEmpty else { return (nil, nil) }
        let normalized = chapters.map { ($0, $0.name.lowercased()) }
        let introIndex = normalized.firstIndex { _, name in
            name.contains("intro") || name.contains("opening") || name.contains("片头")
        }
        let introEnd = introIndex.flatMap { index -> Double? in
            guard chapters.indices.contains(index + 1) else { return nil }
            return Double(chapters[index + 1].startPositionTicks) / 10_000_000
        }
        let outro = normalized.first { _, name in
            name.contains("outro") || name.contains("credits") || name.contains("ending") || name.contains("片尾")
        }?.0
        let outroStart = outro.map { Double($0.startPositionTicks) / 10_000_000 }
        return (introEnd, outroStart)
    }

    private func replaceOperation(_ operation: @escaping @MainActor () async -> Void) {
        operationTask?.cancel()
        isWorking = true
        operationTask = Task { [weak self] in
            await operation()
            guard !Task.isCancelled else { return }
            self?.isWorking = false
        }
    }

    private func makeClient() throws -> JellyfinSpikeClient {
        let client = try JellyfinSpikeClient(serverAddress: serverAddress, deviceID: Self.deviceID())
        BabyPlayerServiceConfiguration.updateJellyfinServerAddress(serverAddress)
        return client
    }

    private static func deviceID() -> String {
        let defaultsKey = "BabyPlayer.DeviceID"
        if let existingID = UserDefaults.standard.string(forKey: defaultsKey) {
            return existingID
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: defaultsKey)
        return newID
    }

    private func readableMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "暂时无法连接 Jellyfin，请检查服务器后重试。"
    }
}
