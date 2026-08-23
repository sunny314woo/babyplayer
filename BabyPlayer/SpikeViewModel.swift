//
// SpikeViewModel.swift
// BabyPlayer 产品状态：首次配对、持久授权、儿童首页和播放队列。
// 最近修改：2026-08-22 增加本地喜欢、不喜欢、屏蔽记录和按喜好播放。
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

    /// LRCLIB 可直接提供原文；中文翻译需要另行配置合规的翻译服务。
    var isCurrentlyAvailable: Bool {
        self == .off || self == .english
    }
}

/// 一条播放队列项；URL 可能包含授权信息，因此只保存在内存中。
struct BabyPlayerQueueItem: Identifiable {
    let id: String
    let title: String
    let url: URL
    let lyricsMedia: LyricsMediaDescriptor
    let chapterIntroEndSeconds: Double?
    let chapterOutroStartSeconds: Double?
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
    @Published private(set) var mediaItems: [JellyfinMediaItem] = []
    @Published private(set) var isWorking = false
    @Published var activePlayback: SpikePlaybackSelection?
    @Published private(set) var ratings: [String: BabyPlayerRating] = [:]
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

    private var authenticatedUserID: String?
    private var accessToken: String?
    private var operationTask: Task<Void, Never>?
    private var coverPrewarmTask: Task<Void, Never>?

    private static let playbackTimerKey = "BabyPlayer.PlaybackTimerMinutes"
    private static let introSkipKey = "BabyPlayer.IntroSkipSeconds"
    private static let outroSkipKey = "BabyPlayer.OutroSkipSeconds"
    private static let lyricsModeKey = "BabyPlayer.LyricsMode"
    private static let ratingsKey = "BabyPlayer.MediaRatings"

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
        if let rawLyricsMode = defaults.string(forKey: Self.lyricsModeKey),
           let savedLyricsMode = BabyPlayerLyricsMode(rawValue: rawLyricsMode),
           savedLyricsMode.isCurrentlyAvailable {
            lyricsMode = savedLyricsMode
        }
        if let storedRatings = defaults.dictionary(forKey: Self.ratingsKey) as? [String: String] {
            ratings = storedRatings.reduce(into: [:]) { result, entry in
                if let rating = BabyPlayerRating(rawValue: entry.value), rating != .unrated {
                    result[entry.key] = rating
                }
            }
        }

        guard let credentials = JellyfinCredentialStore.load() else { return }
        serverAddress = credentials.serverAddress
        authenticatedUserID = credentials.userID
        accessToken = credentials.accessToken
        appState = .loading
        operationTask = Task { [weak self] in
            await self?.restoreSavedSession()
        }
    }

    /// BabyPlayer 只读取 Jellyfin 的“音乐视频”库，因此首页无需再做伪分类。
    var filteredMediaItems: [JellyfinMediaItem] {
        mediaItems.filter { rating(for: $0.id) != .blocked }
    }

    /// 当前媒体库中被家长屏蔽的项目；只在家长设置中展示。
    var blockedMediaItems: [JellyfinMediaItem] {
        mediaItems.filter { rating(for: $0.id) == .blocked }
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
        operationTask = nil
        JellyfinCredentialStore.delete()
        authenticatedUserID = nil
        accessToken = nil
        mediaItems = []
        quickConnectCode = nil
        isWorking = false
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
        ratings[itemID] ?? .unrated
    }

    /// 【MODIFIED】保存本地偏好；不触碰 Jellyfin、U 盘或 NAS 中的原始视频。
    func setRating(_ rating: BabyPlayerRating, for itemID: String) {
        if rating == .unrated {
            ratings.removeValue(forKey: itemID)
        } else {
            ratings[itemID] = rating
        }
        UserDefaults.standard.set(ratings.mapValues(\.rawValue), forKey: Self.ratingsKey)
    }

    /// 家长从设置页解除屏蔽；解除后项目回到未评分状态，不自动提升排序。
    func unblock(_ item: JellyfinMediaItem) {
        setRating(.unrated, for: item.id)
    }

    func endPlayback() {
        activePlayback = nil
    }

    func incrementPlaybackTimer() { playbackTimerMinutes = min(180, playbackTimerMinutes + 5) }
    func decrementPlaybackTimer() { playbackTimerMinutes = max(0, playbackTimerMinutes - 5) }
    func incrementIntroSkip() { introSkipSeconds = min(120, introSkipSeconds + 5) }
    func decrementIntroSkip() { introSkipSeconds = max(0, introSkipSeconds - 5) }
    func incrementOutroSkip() { outroSkipSeconds = min(120, outroSkipSeconds + 5) }
    func decrementOutroSkip() { outroSkipSeconds = max(0, outroSkipSeconds - 5) }

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
        guard let accessToken,
              let client = try? makeClient() else {
            startRePairing()
            return
        }

        let queue = items.compactMap { item -> BabyPlayerQueueItem? in
            guard let url = try? client.directPlaybackURL(for: item, accessToken: accessToken) else { return nil }
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
            return BabyPlayerQueueItem(
                id: item.id,
                title: item.name,
                url: url,
                lyricsMedia: Self.lyricsDescriptor(
                    from: item,
                    songStartSeconds: inferredSongStart,
                    songEndSeconds: inferredSongEnd
                ),
                chapterIntroEndSeconds: markers.introEnd,
                chapterOutroStartSeconds: markers.outroStart
            )
        }
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
            lyricsMode: lyricsMode
        )
    }

    private static func lyricsDescriptor(
        from item: JellyfinMediaItem,
        songStartSeconds: Double?,
        songEndSeconds: Double?
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
            mediaSourceID: item.mediaSources?.first?.id
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
        try JellyfinSpikeClient(serverAddress: serverAddress, deviceID: Self.deviceID())
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
