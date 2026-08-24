//
// SystemPlayerView.swift
// 系统播放器桥接：队列、循环、自动下一首、限时播放和片头片尾跳过。
// 最近修改：2026-08-22 增加当前视频的喜欢、不喜欢和屏蔽菜单。
// 当前主要功能：管理 tvOS 播放、普通歌词、AI 歌词渐进结果和人工绑定优先级。
// 最近修改：2026-08-23 为 Version C 增加即时 manual lock 与后台结果 generation 保护。
// 最近修改：2026-08-23 在播放画面增加可持续可见的 AI 歌词分阶段进度卡。
// 最近修改：2026-08-23 为单曲循环的可恢复 AI 失败增加不阻塞播放的封顶退避重试。
// 最近修改：2026-08-23 让同 fingerprint 分段分析跨单曲循环复用，并按真实准备、识别、校准、优化阶段反馈。
//

import AVKit
import Foundation
import SwiftUI

enum BabyPlayerLyricTimeline {
    static func visibleLineIndex(at elapsed: Double, lines: [TimedLyricLine]) -> Int? {
        guard let index = lines.lastIndex(where: { $0.time <= elapsed }) else { return nil }
        if let endTime = lines[index].endTime, elapsed > endTime {
            return nil
        }
        return index
    }
}

// 【MODIFIED】AI 进度必须在菜单关闭后仍然可见，而不是只写回下次打开的菜单标题。
enum BabyPlayerAILyricsProgress: Equatable {
    case preparingAudio(index: Int, total: Int)
    case recognizing(index: Int, total: Int)
    case aligning
    case refining
    case completed
    case unmatched
    case warning(String)
    case failed(String)
    case deferred(String)
    case retrying(attempt: Int, delaySeconds: Int, reason: String)

    /// 生成菜单中的简短状态；无额外输入，输出单行文案，不修改 UI 或 repository。
    var menuTitle: String {
        switch self {
        case .preparingAudio(let index, let total):
            return "正在准备 AI 音频（\(index)/\(total)）…"
        case .recognizing(let index, let total):
            return "正在进行语音识别（\(index)/\(total)）…"
        case .aligning: return "正在校准歌词…"
        case .refining: return "正在优化歌词…"
        case .completed: return "AI 优化完成"
        case .unmatched: return "未确认匹配，保留普通歌词"
        case .warning(let message), .failed(let message), .deferred(let message):
            return message
        case .retrying(let attempt, let delaySeconds, _):
            return "单曲循环：\(delaySeconds) 秒后第 \(attempt) 次重试"
        }
    }

    /// 生成播放画面进度卡文案；无额外输入，输出多行里程碑，不修改 UI 或 repository。
    var overlayText: String {
        switch self {
        case .preparingAudio(let index, let total):
            return "AI 歌词\n● 正在准备 AI 音频（\(index)/\(total)）…\n○ 语音识别\n○ 歌词校准\n○ 歌词优化"
        case .recognizing(let index, let total):
            return "AI 歌词\n✓ AI 音频已准备（\(index)/\(total)）\n● 正在进行语音识别…\n○ 歌词校准\n○ 歌词优化"
        case .aligning:
            return "AI 歌词\n✓ 语音识别已经完成\n● 正在校准歌词…\n○ 歌词优化"
        case .refining:
            return "AI 歌词\n✓ 语音识别已经完成\n✓ 时间轴已重新完成对齐\n● 正在优化歌词…"
        case .completed:
            return "AI 歌词\n✓ 语音识别已经完成\n✓ 时间轴已重新完成对齐\n✓ 字幕内容已完成对齐"
        case .unmatched:
            return "AI 歌词\n✓ 语音识别已经完成\n⚠ 未确认为同一首歌\n普通歌词保持不变"
        case .warning(let message):
            return "AI 歌词\n✓ 语音识别已经完成\n✓ 时间轴已重新完成对齐\n⚠ \(message)"
        case .failed(let message):
            return "AI 歌词\n✕ \(message)"
        case .deferred(let message):
            return "AI 歌词\n○ \(message)"
        case .retrying(let attempt, let delaySeconds, let reason):
            return "AI 歌词\n⚠ \(reason)\n↻ 单曲循环已保持播放\n\(delaySeconds) 秒后第 \(attempt) 次自动重试"
        }
    }
}

// 【MODIFIED】用纯内存 generation 使人工点击在任何 await 之前立即使后台自动结果失效。
final class LyricsAutomationGenerationGuard: @unchecked Sendable {
    private let stateLock = NSLock()
    private var storedGeneration = 0
    private var storedManualLock = false

    var generation: Int {
        stateLock.withLock { storedGeneration }
    }

    var isManuallyLocked: Bool {
        stateLock.withLock { storedManualLock }
    }

    /// 为新媒体重置保护；无输入，返回新 generation，会清除旧媒体的 manual lock 并修改内存状态。
    @discardableResult
    func resetForNewMedia() -> Int {
        stateLock.withLock {
            storedGeneration &+= 1
            storedManualLock = false
            return storedGeneration
        }
    }

    /// 在用户开始选择时锁定；无输入，返回新 generation，会立即修改内存锁状态。
    @discardableResult
    func lockManually() -> Int {
        stateLock.withLock {
            storedGeneration &+= 1
            storedManualLock = true
            return storedGeneration
        }
    }

    /// 判断自动工作结果是否仍可应用；输入为工作启动时 generation，输出为布尔值，不修改状态。
    func permitsAutomaticResult(startedAt startedGeneration: Int) -> Bool {
        stateLock.withLock {
            !storedManualLock && storedGeneration == startedGeneration
        }
    }

    /// 在同一把锁内检查 generation 并提交自动结果；输入为启动 generation 和同步操作，输出为可选操作结果，可修改 repository。
    func performIfAutomaticResultIsPermitted<Result>(
        startedAt startedGeneration: Int,
        _ operation: () throws -> Result
    ) rethrows -> Result? {
        try stateLock.withLock {
            guard !storedManualLock, storedGeneration == startedGeneration else { return nil }
            return try operation()
        }
    }
}

struct SystemPlayerView: UIViewControllerRepresentable {
    let selection: SpikePlaybackSelection
    let onExit: () -> Void
    let onRate: (String, BabyPlayerRating) -> Void
    let ratingFor: (String) -> BabyPlayerRating

    func makeUIViewController(context: Context) -> BabyPlaylistPlayerViewController {
        let controller = BabyPlaylistPlayerViewController()
        controller.configure(
            selection: selection,
            onExit: onExit,
            onRate: onRate,
            ratingFor: ratingFor
        )
        return controller
    }

    func updateUIViewController(_ controller: BabyPlaylistPlayerViewController, context: Context) {
        controller.onExit = onExit
        controller.onRate = onRate
        controller.ratingFor = ratingFor
    }

    static func dismantleUIViewController(
        _ controller: BabyPlaylistPlayerViewController,
        coordinator: Void
    ) {
        controller.cleanUp()
    }
}

final class BabyPlaylistPlayerViewController: AVPlayerViewController {
    private enum ActivePlaybackMode: Equatable {
        case single
        case sequential
        case shuffled
    }

    var onExit: (() -> Void)?
    var onRate: ((String, BabyPlayerRating) -> Void)?
    var ratingFor: ((String) -> BabyPlayerRating)?

    private var selection: SpikePlaybackSelection?
    private var originalQueueItems: [BabyPlayerQueueItem] = []
    private var queueItems: [BabyPlayerQueueItem] = []
    private var currentIndex = 0
    private var currentPlayNumber = 1
    private var activeRepeatMode: BabyPlayerRepeatMode = .repeatOne
    private var activeRepeatCount = 0
    private var activePlaybackMode: ActivePlaybackMode = .single
    private var sessionEndsAt: Date?
    private var timerDurationMinutes: Int?
    private var currentVolume: Float = 1
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var lyricsTask: Task<Void, Never>?
    private var soundAnalysisTask: Task<Void, Never>?
    private var lyricsSaveTask: Task<Void, Never>?
    private var lyricsSelectionTask: Task<Void, Never>?
    private var lyricLines: [TimedLyricLine] = []
    private var lyricPlayback: LyricsPlayback?
    private var lyricCandidates: [LyricsCandidate] = []
    private var plainTextReference: LyricsPlainTextReference?
    private var isSearchingLyrics = false
    private var isAnalyzingSound = false
    private var lyricsSearchMessage: String?
    private var soundAnalysisMessage: String?
    private var shouldAnalyzeAfterSearch = false
    private var pendingLyricSelectionIdentifier: String?
    private let lyricsAutomationGuard = LyricsAutomationGenerationGuard()
    private var currentLyricsMode: BabyPlayerLyricsMode = .off
    private var currentLyricIndex: Int?
    private var lyricsContainer: UIView?
    private var lyricsLabel: UILabel?
    private var aiProgressContainer: UIView?
    private var aiProgressLabel: UILabel?
    private var soundAnalysisFailureCounts: [String: Int] = [:]
    private var soundAnalysisRetryNotBefore: [String: Date] = [:]
    private var preparedLyricsFingerprint: String?
    private var soundAnalysisFingerprint: String?
    private var isAdvancing = false
    private var didExit = false

    /// 配置系统播放器和评分回调；评分回调只更新 BabyPlayer 本地状态。
    func configure(
        selection: SpikePlaybackSelection,
        onExit: @escaping () -> Void,
        onRate: @escaping (String, BabyPlayerRating) -> Void,
        ratingFor: @escaping (String) -> BabyPlayerRating
    ) {
        self.selection = selection
        self.onExit = onExit
        self.onRate = onRate
        self.ratingFor = ratingFor
        originalQueueItems = selection.items
        queueItems = selection.items
        currentIndex = selection.startIndex
        currentPlayNumber = 1
        activeRepeatMode = selection.repeatMode
        activeRepeatCount = selection.repeatCount
        activePlaybackMode = {
            switch selection.initialBehavior {
            case .repeatOne: return .single
            case .sequential, .repeatAll: return .sequential
            case .shuffle: return .shuffled
            }
        }()
        currentLyricsMode = selection.lyricsMode
        sessionEndsAt = selection.sessionDuration.map { Date().addingTimeInterval($0) }
        timerDurationMinutes = selection.sessionDuration.map { Int(($0 / 60).rounded()) }
        showsPlaybackControls = true

        let playbackPlayer = AVPlayer()
        playbackPlayer.volume = currentVolume
        player = playbackPlayer
        setUpLyricsOverlay()

        if activePlaybackMode == .shuffled {
            shuffleQueueKeepingCurrentItem()
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.object as? AVPlayerItem === self.player?.currentItem else { return }
            self.handleNaturalEnd()
        }

        timeObserver = playbackPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.handleProgress(time.seconds)
        }

        playCurrentItem()
    }

    func cleanUp() {
        lyricsTask?.cancel()
        lyricsTask = nil
        soundAnalysisTask?.cancel()
        soundAnalysisTask = nil
        soundAnalysisFingerprint = nil
        Task { await BabyPlayerASRCoordinator.shared.cancelAll() }
        lyricsSelectionTask?.cancel()
        lyricsSelectionTask = nil
        player?.pause()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            finishPlayback()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    private var currentQueueItem: BabyPlayerQueueItem? {
        guard queueItems.indices.contains(currentIndex) else { return nil }
        return queueItems[currentIndex]
    }

    /// 判断当前播放媒体；输入为 media fingerprint，输出是否仍为同一声音来源，不修改状态。
    // 【MODIFIED】循环重建 queue item 时使用稳定 fingerprint，而不是播放器实例生命周期。
    private func isCurrentMedia(fingerprint: String) -> Bool {
        currentQueueItem?.lyricsMedia.asrFingerprint == fingerprint
    }

    private func playCurrentItem() {
        guard !sessionLimitReached(),
              let selection,
              let queueItem = currentQueueItem else {
            finishPlayback()
            return
        }

        isAdvancing = false
        let playerItem = AVPlayerItem(url: queueItem.url)
        playerItem.externalMetadata = [titleMetadataItem(queueItem.title)]
        player?.replaceCurrentItem(with: playerItem)
        prepareLyrics(for: queueItem, mode: currentLyricsMode)

        let introTarget = queueItem.chapterIntroEndSeconds ?? selection.introSkipSeconds
        if introTarget > 0 {
            player?.seek(
                to: CMTime(seconds: introTarget, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] finished in
                guard finished,
                      let self,
                      self.currentQueueItem?.id == queueItem.id,
                      let elapsed = self.player?.currentTime().seconds,
                      elapsed.isFinite else { return }
                // 歌词始终跟随视频的绝对播放时间，不把片头跳过量重复叠加到歌词偏移。
                self.currentLyricIndex = nil
                self.updateLyrics(at: elapsed)
            }
        }
        player?.play()
    }

    private func handleProgress(_ elapsed: Double) {
        updateLyrics(at: elapsed)
        guard !isAdvancing,
              let selection,
              let queueItem = currentQueueItem else { return }

        if sessionLimitReached() {
            finishPlayback()
            return
        }

        let outroTarget: Double?
        if let chapterTarget = queueItem.chapterOutroStartSeconds {
            outroTarget = chapterTarget
        } else if selection.outroSkipSeconds > 0,
                  let duration = player?.currentItem?.duration.seconds,
                  duration.isFinite,
                  duration > selection.outroSkipSeconds {
            outroTarget = duration - selection.outroSkipSeconds
        } else {
            outroTarget = nil
        }

        if let outroTarget, elapsed >= outroTarget {
            isAdvancing = true
            lyricsContainer?.isHidden = true
            lyricsLabel?.text = nil
            currentLyricIndex = nil
            handleNaturalEnd()
        }
    }

    private func handleNaturalEnd() {
        guard !queueItems.isEmpty else {
            finishPlayback()
            return
        }

        switch activeRepeatMode {
        case .repeatOne:
            if activeRepeatCount == 0 || currentPlayNumber < activeRepeatCount {
                currentPlayNumber += 1
                playCurrentItem()
            } else {
                finishPlayback()
            }
        case .repeatAll:
            currentPlayNumber = 1
            currentIndex = (currentIndex + 1) % queueItems.count
            playCurrentItem()
        case .stopAtEnd:
            currentPlayNumber = 1
            let nextIndex = currentIndex + 1
            if queueItems.indices.contains(nextIndex) {
                currentIndex = nextIndex
                playCurrentItem()
            } else {
                finishPlayback()
            }
        }
    }

    private func sessionLimitReached() -> Bool {
        guard let sessionEndsAt else { return false }
        return Date() >= sessionEndsAt
    }

    private func finishPlayback() {
        guard !didExit else { return }
        didExit = true
        lyricsTask?.cancel()
        soundAnalysisTask?.cancel()
        let fingerprint = soundAnalysisFingerprint
        soundAnalysisTask = nil
        soundAnalysisFingerprint = nil
        if let fingerprint {
            Task {
                await BabyPlayerASRCoordinator.shared.cancel(
                    mediaFingerprint: fingerprint
                )
            }
        }
        lyricsSelectionTask?.cancel()
        player?.pause()
        onExit?()
    }

    private func setUpLyricsOverlay() {
        loadViewIfNeeded()
        guard lyricsContainer == nil,
              let overlay = contentOverlayView else { return }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.52)
        container.layer.cornerRadius = 18
        container.layer.cornerCurve = .continuous
        container.isUserInteractionEnabled = false
        container.isHidden = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 2
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 38, weight: .semibold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.72
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 4
        label.layer.shadowOffset = CGSize(width: 0, height: 2)

        overlay.addSubview(container)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 150),
            container.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -150),
            container.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -88),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        lyricsContainer = container
        lyricsLabel = label

        // 【MODIFIED】进度卡位于画面左上方，避免遮挡底部歌词和系统播放控件。
        let progressContainer = UIView()
        progressContainer.translatesAutoresizingMaskIntoConstraints = false
        progressContainer.backgroundColor = UIColor.black.withAlphaComponent(0.68)
        progressContainer.layer.cornerRadius = 16
        progressContainer.layer.cornerCurve = .continuous
        progressContainer.isUserInteractionEnabled = false
        progressContainer.isHidden = true

        let progressLabel = UILabel()
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.numberOfLines = 0
        progressLabel.textAlignment = .left
        progressLabel.textColor = .white
        progressLabel.font = .systemFont(ofSize: 25, weight: .medium)
        progressLabel.layer.shadowColor = UIColor.black.cgColor
        progressLabel.layer.shadowOpacity = 0.7
        progressLabel.layer.shadowRadius = 3

        overlay.addSubview(progressContainer)
        progressContainer.addSubview(progressLabel)
        NSLayoutConstraint.activate([
            progressContainer.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 72),
            progressContainer.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 58),
            progressContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            progressLabel.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor, constant: 22),
            progressLabel.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: -22),
            progressLabel.topAnchor.constraint(equalTo: progressContainer.topAnchor, constant: 16),
            progressLabel.bottomAnchor.constraint(equalTo: progressContainer.bottomAnchor, constant: -16)
        ])
        aiProgressContainer = progressContainer
        aiProgressLabel = progressLabel
    }

    // 【MODIFIED】同步刷新菜单和播放画面，让遥控器点击后立即有可见反馈。
    /// 显示 AI 歌词阶段；输入为进度状态，输出 Void，会更新菜单和播放画面，不修改 repository。
    private func showAILyricsProgress(_ progress: BabyPlayerAILyricsProgress) {
        soundAnalysisMessage = progress.menuTitle
        aiProgressLabel?.text = progress.overlayText
        aiProgressContainer?.isHidden = false
        updateLyricsTransportMenu()
    }

    private func prepareLyrics(for item: BabyPlayerQueueItem, mode: BabyPlayerLyricsMode) {
        let fingerprint = item.lyricsMedia.asrFingerprint
        let isSameFingerprint = preparedLyricsFingerprint == fingerprint
        lyricsTask?.cancel()
        if !isSameFingerprint {
            let previousFingerprint = soundAnalysisFingerprint
            soundAnalysisTask?.cancel()
            soundAnalysisTask = nil
            soundAnalysisFingerprint = nil
            lyricsSelectionTask?.cancel()
            pendingLyricSelectionIdentifier = nil
            // 【MODIFIED】只有真正切歌才使旧 generation 失效；单曲循环保留 task 和 manual lock。
            lyricsAutomationGuard.resetForNewMedia()
            shouldAnalyzeAfterSearch = false
            isAnalyzingSound = false
            soundAnalysisMessage = nil
            aiProgressLabel?.text = nil
            aiProgressContainer?.isHidden = true
            if let previousFingerprint {
                Task {
                    await BabyPlayerASRCoordinator.shared.cancel(
                        mediaFingerprint: previousFingerprint
                    )
                }
            }
        }
        preparedLyricsFingerprint = fingerprint
        currentLyricsMode = mode
        lyricLines = []
        lyricPlayback = nil
        lyricCandidates = []
        plainTextReference = nil
        isSearchingLyrics = true
        lyricsSearchMessage = nil
        currentLyricIndex = nil
        lyricsLabel?.text = nil
        lyricsContainer?.isHidden = true
        updateLyricsTransportMenu()

        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let storedPlayback = await BabyLyricsRepository.shared.storedLyrics(
                for: item.lyricsMedia
            )
            let plainReference = await BabyLyricsRepository.shared.plainTextReference(
                for: item.lyricsMedia
            )
            guard !Task.isCancelled, self.isCurrentMedia(fingerprint: fingerprint) else { return }
            self.plainTextReference = plainReference
            var playback = storedPlayback
            var foundCandidates: [LyricsCandidate] = []
            do {
                let candidates = try await BabyLyricsRepository.shared.searchCandidates(
                    for: item.lyricsMedia
                )
                guard !Task.isCancelled, self.isCurrentMedia(fingerprint: fingerprint) else { return }
                foundCandidates = Array(candidates.prefix(3))
                self.lyricCandidates = foundCandidates
                playback = await BabyLyricsRepository.shared.resolvedLyrics(
                    for: item.lyricsMedia,
                    candidates: candidates
                )
            } catch {
                guard !Task.isCancelled, self.isCurrentMedia(fingerprint: fingerprint) else { return }
                self.lyricCandidates = []
                self.lyricsSearchMessage = (error as? LocalizedError)?.errorDescription
                    ?? "在线歌词服务暂时不可用"
            }

            guard !Task.isCancelled, self.isCurrentMedia(fingerprint: fingerprint) else { return }
            self.isSearchingLyrics = false
            self.lyricPlayback = playback
            if self.currentLyricsMode != .off, let playback {
                self.lyricLines = playback.lines
                if let elapsed = self.player?.currentTime().seconds, elapsed.isFinite {
                    self.updateLyrics(at: elapsed)
                }
            }
            self.updateLyricsTransportMenu()

            let canAutomaticallyAnalyze = self.shouldAnalyzeAfterSearch
                || (self.currentLyricsMode != .off
                    && (playback == nil || playback?.selectionOrigin == .automatic))
            self.shouldAnalyzeAfterSearch = false
            guard canAutomaticallyAnalyze else { return }
            self.startSoundAnalysis(
                for: item,
                candidates: foundCandidates,
                reference: plainReference,
                waitForBuffer: true
            )
        }
    }

    private func startSoundAnalysis(
        for item: BabyPlayerQueueItem,
        candidates: [LyricsCandidate],
        reference: LyricsPlainTextReference?,
        waitForBuffer: Bool,
        manuallyRequested: Bool = false
    ) {
        let fingerprint = item.lyricsMedia.asrFingerprint
        guard isCurrentMedia(fingerprint: fingerprint) else { return }
        if isAnalyzingSound, soundAnalysisFingerprint == fingerprint { return }
        // 【MODIFIED】人工点击可立即开始新一轮；自动轮询则继承上次退避。
        if manuallyRequested {
            soundAnalysisFailureCounts[fingerprint] = 0
            soundAnalysisRetryNotBefore[fingerprint] = nil
        }
        // 【MODIFIED】后台链路只能在启动 generation 仍有效时自动应用。
        let automaticGeneration = lyricsAutomationGuard.generation
        if let previousFingerprint = soundAnalysisFingerprint,
           previousFingerprint != fingerprint {
            soundAnalysisTask?.cancel()
            Task {
                await BabyPlayerASRCoordinator.shared.cancel(
                    mediaFingerprint: previousFingerprint
                )
            }
        }
        soundAnalysisFingerprint = fingerprint
        isAnalyzingSound = true
        // 【MODIFIED】当前 MVP 只准备并上传一份临时整首音频；分片计划暂不进入生产链路。
        let plannedCount = 1
        // 【MODIFIED】点击后只显示真实的本地准备阶段，不再提前宣称已调用语音识别。
        showAILyricsProgress(.preparingAudio(index: 1, total: plannedCount))

        soundAnalysisTask = Task { [weak self] in
            guard let self else { return }
            // 【MODIFIED】单曲重播重建 player item 时会继承 not-before，不会重置为立即猛烈重试。
            if let retryDate = self.soundAnalysisRetryNotBefore[fingerprint] {
                let remaining = retryDate.timeIntervalSinceNow
                if remaining > 0 {
                    let attempt = self.soundAnalysisFailureCounts[fingerprint] ?? 1
                    self.showAILyricsProgress(.retrying(
                        attempt: attempt,
                        delaySeconds: Int(remaining.rounded(.up)),
                        reason: "上一次声音分析未完成"
                    ))
                    try? await Task.sleep(for: .seconds(remaining))
                }
            }
            if waitForBuffer {
                guard await self.waitForPlaybackBuffer(fingerprint: fingerprint) else {
                    guard !Task.isCancelled,
                          self.isCurrentMedia(fingerprint: fingerprint) else { return }
                    self.isAnalyzingSound = false
                    self.showAILyricsProgress(.deferred("播放优先：本次暂缓声音分析"))
                    return
                }
            }
            guard !Task.isCancelled, self.isCurrentMedia(fingerprint: fingerprint) else { return }
            while !Task.isCancelled, self.isCurrentMedia(fingerprint: fingerprint) {
                do {
                    let outcome = try await BabyPlayerASRCoordinator.shared.analyze(
                        item: item,
                        candidates: candidates,
                        reference: reference,
                        forceLyricsRefresh: manuallyRequested,
                        onStage: { [weak self] stage in
                            guard let self,
                                  !Task.isCancelled,
                                  self.isCurrentMedia(fingerprint: fingerprint) else { return }
                            self.showAILyricsProgress(self.visibleProgress(for: stage))
                        },
                        onAILyricsV1: { [weak self] v1Outcome in
                            guard let self,
                                  !Task.isCancelled,
                                  self.isCurrentMedia(fingerprint: fingerprint) else { return }
                            await self.receiveSoundAnalysisOutcome(
                                v1Outcome,
                                for: item,
                                automaticGeneration: automaticGeneration,
                                progress: .aligning
                            )
                        }
                    )
                    guard !Task.isCancelled,
                          self.isCurrentMedia(fingerprint: fingerprint) else { return }
                    self.soundAnalysisFailureCounts[fingerprint] = nil
                    self.soundAnalysisRetryNotBefore[fingerprint] = nil
                    let finalProgress: BabyPlayerAILyricsProgress
                    if outcome.selected == nil {
                        finalProgress = .unmatched
                    } else if outcome.message == "AI 优化完成" {
                        finalProgress = .completed
                    } else {
                        finalProgress = .warning(outcome.message)
                    }
                    await self.receiveSoundAnalysisOutcome(
                        outcome,
                        for: item,
                        automaticGeneration: automaticGeneration,
                        progress: finalProgress
                    )
                    break
                } catch {
                    guard !Task.isCancelled,
                          self.isCurrentMedia(fingerprint: fingerprint) else { return }
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? "声音歌词生成暂时不可用"
                    let canRetry = self.activeRepeatMode == .repeatOne
                        && BabyPlayerAIAnalysisRetryPolicy.shouldRetry(error)
                    guard canRetry else {
                        self.showAILyricsProgress(.failed(message))
                        break
                    }
                    // 【MODIFIED】退避只 suspend 分析 Task，AVPlayer 持续播放不受影响。
                    let failureCount = (self.soundAnalysisFailureCounts[fingerprint] ?? 0) + 1
                    let delay = BabyPlayerAIAnalysisRetryPolicy.delay(
                        afterFailureCount: failureCount
                    )
                    self.soundAnalysisFailureCounts[fingerprint] = failureCount
                    self.soundAnalysisRetryNotBefore[fingerprint] = Date().addingTimeInterval(delay)
                    self.showAILyricsProgress(.retrying(
                        attempt: failureCount,
                        delaySeconds: Int(delay),
                        reason: message
                    ))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            if self.soundAnalysisFingerprint == fingerprint {
                self.isAnalyzingSound = false
                self.soundAnalysisTask = nil
                self.soundAnalysisFingerprint = nil
                self.updateLyricsTransportMenu()
            }
        }
    }

    /// 映射真实 ASR 阶段到现有轻量 UI 状态；输入为 coordinator stage，输出可见进度，不修改 UI/repository。
    // 【MODIFIED】preparing/recognizing/aligning/refining 不再混用同一“匹配中”文案。
    private func visibleProgress(
        for stage: BabyPlayerASRProcessingStage
    ) -> BabyPlayerAILyricsProgress {
        switch stage {
        case .preparingAudio(let index, let total):
            return .preparingAudio(index: index, total: total)
        case .recognizing(let index, let total):
            return .recognizing(index: index, total: total)
        case .aligning:
            return .aligning
        case .refining:
            return .refining
        }
    }

    // 【MODIFIED】AI v1/v2 共用一个接收点：始终保留候选，但只有强证据且 generation 未被 manual lock 作废时自动展示。
    /// 接收渐进 AI outcome；输入为 outcome、媒体、启动 generation 和可见进度，输出 Void，会更新 UI 并可能通过 repository 自动绑定。
    private func receiveSoundAnalysisOutcome(
        _ outcome: BabyPlayerASRMatchOutcome,
        for item: BabyPlayerQueueItem,
        automaticGeneration: Int,
        progress: BabyPlayerAILyricsProgress
    ) async {
        let fingerprint = item.lyricsMedia.asrFingerprint
        guard isCurrentMedia(fingerprint: fingerprint) else { return }
        lyricCandidates = Array(outcome.candidates.prefix(4))
        showAILyricsProgress(progress)
        guard let selected = outcome.selected,
              outcome.shouldAutomaticallyApply,
              lyricsAutomationGuard.permitsAutomaticResult(startedAt: automaticGeneration),
              lyricPlayback?.selectionOrigin != .manual,
              let verified = try? await BabyLyricsRepository.shared.applyAutomaticRecommendation(
                  selected,
                  autoOffsetSeconds: outcome.offsetSeconds,
                  for: item.lyricsMedia,
                  automationGuard: lyricsAutomationGuard,
                  startedAtGeneration: automaticGeneration
              ) else {
            updateLyricsTransportMenu()
            return
        }
        // 【MODIFIED】repository await 返回后再检查一次，禁止旧结果更新 UI。
        guard lyricsAutomationGuard.permitsAutomaticResult(startedAt: automaticGeneration) else {
            updateLyricsTransportMenu()
            return
        }
        lyricPlayback = verified
        if currentLyricsMode != .off {
            lyricLines = verified.lines
            currentLyricIndex = nil
            if let elapsed = player?.currentTime().seconds, elapsed.isFinite {
                updateLyrics(at: elapsed)
            }
        }
        updateLyricsTransportMenu()
    }

    /// 避免远程 MP4 同时播放和导出时争抢局域网带宽；缓冲不稳就让本轮分析让路。
    private func waitForPlaybackBuffer(fingerprint: String) async -> Bool {
        for _ in 0..<20 {
            guard !Task.isCancelled,
                  isCurrentMedia(fingerprint: fingerprint) else { return false }
            if player?.currentItem?.isPlaybackLikelyToKeepUp == true { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func updateLyrics(at elapsed: Double) {
        guard elapsed.isFinite, !lyricLines.isEmpty else { return }
        let adjustedElapsed = elapsed - (lyricPlayback?.offsetSeconds ?? 0)
        let index = BabyPlayerLyricTimeline.visibleLineIndex(
            at: adjustedElapsed,
            lines: lyricLines
        )
        guard index != currentLyricIndex else { return }
        currentLyricIndex = index
        guard let index else {
            lyricsContainer?.isHidden = true
            return
        }
        lyricsLabel?.text = lyricLines[index].text
        lyricsContainer?.isHidden = false
    }

    private func updateLyricsTransportMenu() {
        let isVisible = currentLyricsMode != .off
        let visibility = UIAction(
            title: isVisible ? "显示字幕：开" : "显示字幕：关",
            image: UIImage(systemName: isVisible ? "captions.bubble.fill" : "captions.bubble")
        ) { [weak self] _ in
            guard let self else { return }
            self.setLyricsMode(isVisible ? .off : .english)
        }
        visibility.state = isVisible ? .on : .off

        let english = UIAction(title: "英文", image: UIImage(systemName: "character.book.closed")) { [weak self] _ in
            self?.setLyricsMode(.english)
        }
        english.state = currentLyricsMode == .english ? .on : .off

        let chinese = UIAction(title: "中文（待接入翻译服务）") { _ in }
        chinese.attributes = .disabled
        chinese.state = currentLyricsMode == .chinese ? .on : .off

        let bilingual = UIAction(title: "中英双语（待接入翻译服务）") { _ in }
        bilingual.attributes = .disabled
        bilingual.state = currentLyricsMode == .bilingual ? .on : .off

        // AVKit 不支持 transportBarCustomMenuItems 的嵌套菜单，因此保持单层遥控器选项。
        var children: [UIMenuElement] = [visibility, english, chinese, bilingual]

        if let media = currentQueueItem?.lyricsMedia {
            let hints = [media.sourceHint, media.versionHint].compactMap { $0 }
            if !hints.isEmpty {
                let detected = UIAction(
                    title: "文件名线索：\(hints.joined(separator: " · "))",
                    image: UIImage(systemName: "tag")
                ) { _ in }
                detected.attributes = .disabled
                children.append(detected)
            }
        }

        let candidatesTitle = UIAction(
            title: "声音时间轴优先 · 3 份网络歌词 + 可选歌本兜底",
            image: UIImage(systemName: "list.number")
        ) { _ in }
        candidatesTitle.attributes = .disabled
        children.append(candidatesTitle)

        if isSearchingLyrics {
            let searching = UIAction(
                title: "正在搜索歌词…",
                image: UIImage(systemName: "magnifyingglass")
            ) { _ in }
            searching.attributes = .disabled
            children.append(searching)
        } else if lyricCandidates.isEmpty {
            let unavailable = UIAction(
                title: lyricsSearchMessage ?? "没有找到带时间轴的歌词",
                image: UIImage(systemName: "exclamationmark.bubble")
            ) { _ in }
            unavailable.attributes = .disabled
            children.append(unavailable)
        } else {
            children.append(contentsOf: lyricCandidates.enumerated().map { index, candidate in
                lyricsCandidateAction(candidate, rank: index + 1)
            })
        }

        let refresh = UIAction(
            title: "重新搜索歌词",
            image: UIImage(systemName: "arrow.clockwise")
        ) { [weak self] _ in
            self?.refreshLyricsCandidates()
        }
        if isSearchingLyrics { refresh.attributes = .disabled }
        children.append(refresh)

        if isAnalyzingSound {
            let analyzing = UIAction(
                title: soundAnalysisMessage ?? "正在校准歌词…",
                image: UIImage(systemName: "sparkles")
            ) { _ in }
            analyzing.attributes = .disabled
            children.append(analyzing)
        } else if let soundAnalysisMessage {
            let result = UIAction(
                title: soundAnalysisMessage,
                image: UIImage(systemName: "sparkles")
            ) { _ in }
            result.attributes = .disabled
            children.append(result)
        }

        if let playback = lyricPlayback {
            let offset = playback.offsetSeconds
            let statusTitle: String
            switch playback.selectionOrigin {
            case .automatic:
                statusTitle = "网络歌词兜底·待声音分析"
            case .asr:
                statusTitle = "AI 歌词·已绑定"
            case .manual:
                statusTitle = playback.isConfirmed ? "家长已绑定" : "已选择·未确认"
            }
            let status = UIAction(
                title: "\(statusTitle)  总计 \(formattedOffset(offset)) · 自动 \(formattedOffset(playback.autoOffsetSeconds)) · 手动 \(formattedOffset(playback.manualAdjustmentSeconds))",
                image: UIImage(systemName: playback.selectionOrigin == .asr || playback.isConfirmed
                    ? "checkmark.circle.fill"
                    : "questionmark.circle")
            ) { _ in }
            status.attributes = .disabled

            let earlierHalf = UIAction(title: "歌词提前 0.5 秒", image: UIImage(systemName: "gobackward.5")) { [weak self] _ in
                self?.adjustLyricsOffset(by: -0.5)
            }
            let earlierTenth = UIAction(title: "歌词提前 0.1 秒", image: UIImage(systemName: "minus.circle")) { [weak self] _ in
                self?.adjustLyricsOffset(by: -0.1)
            }
            let laterTenth = UIAction(title: "歌词延后 0.1 秒", image: UIImage(systemName: "plus.circle")) { [weak self] _ in
                self?.adjustLyricsOffset(by: 0.1)
            }
            let laterHalf = UIAction(title: "歌词延后 0.5 秒", image: UIImage(systemName: "goforward.5")) { [weak self] _ in
                self?.adjustLyricsOffset(by: 0.5)
            }
            let reset = UIAction(title: "恢复原时间", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
                self?.resetManualLyricsAdjustment()
            }
            let alignFirstLine = UIAction(
                title: "把第一句对齐到当前位置",
                image: UIImage(systemName: "scope")
            ) { [weak self] _ in
                self?.alignFirstLyricLineToCurrentTime()
            }

            var timingChildren: [UIMenuElement] = [
                status,
                alignFirstLine,
                earlierHalf,
                earlierTenth,
                laterTenth,
                laterHalf,
                reset
            ]
            if !playback.isConfirmed {
                let confirm = UIAction(
                    title: "确认并绑定这份歌词",
                    image: UIImage(systemName: "pin.fill")
                ) { [weak self] _ in
                    self?.confirmCurrentLyrics()
                }
                timingChildren.insert(confirm, at: 1)
            }

            children.append(contentsOf: timingChildren)
        }

        let soundAnalysis = UIAction(
            title: isAnalyzingSound
                ? "AI 歌词·处理中…"
                : (soundAnalysisMessage == nil ? "AI 歌词" : "重新分析 AI 歌词"),
            image: UIImage(systemName: "sparkles")
        ) { [weak self] _ in
            self?.requestSoundAnalysis()
        }
        if isAnalyzingSound {
            soundAnalysis.attributes = .disabled
        }

        transportBarCustomMenuItems = [
            UIMenu(
                title: "字幕与歌词",
                image: UIImage(systemName: "captions.bubble.fill"),
                children: children
            ),
            soundAnalysis,
            ratingMenu(),
            playbackModeMenu(),
            volumeMenu()
        ]
    }

    /// 创建当前视频的三态本地评分菜单；屏蔽后结束当前播放会话。
    private func ratingMenu() -> UIMenu {
        let currentRating = currentQueueItem.flatMap { ratingFor?($0.id) } ?? .unrated
        let like = ratingAction(
            title: "喜欢",
            rating: .liked,
            symbol: "heart.fill",
            currentRating: currentRating
        )
        let dislike = ratingAction(
            title: "不喜欢",
            rating: .disliked,
            symbol: "hand.thumbsdown.fill",
            currentRating: currentRating
        )
        let block = ratingAction(
            title: "屏蔽",
            rating: .blocked,
            symbol: "nosign",
            currentRating: currentRating
        )
        let clear = ratingAction(
            title: "清除评分",
            rating: .unrated,
            symbol: "arrow.counterclockwise",
            currentRating: currentRating
        )
        return UIMenu(
            title: currentRating == .unrated ? "视频评分" : "视频评分：\(currentRating.rawValue)",
            image: UIImage(systemName: currentRating == .liked ? "heart.fill" : "hand.thumbsup"),
            children: [like, dislike, block, clear]
        )
    }

    private func ratingAction(
        title: String,
        rating: BabyPlayerRating,
        symbol: String,
        currentRating: BabyPlayerRating
    ) -> UIAction {
        let action = UIAction(
            title: title,
            image: UIImage(systemName: symbol)
        ) { [weak self] _ in
            guard let self, let item = currentQueueItem else { return }
            onRate?(item.id, rating)
            if rating == .blocked {
                finishPlayback()
            } else {
                updateLyricsTransportMenu()
            }
        }
        action.state = currentRating == rating ? .on : .off
        return action
    }

    private func playbackModeMenu() -> UIMenu {
        let single = UIAction(title: "单曲循环", image: UIImage(systemName: "repeat.1")) { [weak self] _ in
            self?.setPlaybackMode(.single)
        }
        single.state = activePlaybackMode == .single ? .on : .off

        let sequential = UIAction(title: "顺序循环", image: UIImage(systemName: "repeat")) { [weak self] _ in
            self?.setPlaybackMode(.sequential)
        }
        sequential.state = activePlaybackMode == .sequential ? .on : .off

        let shuffled = UIAction(title: "随机播放", image: UIImage(systemName: "shuffle")) { [weak self] _ in
            self?.setPlaybackMode(.shuffled)
        }
        shuffled.state = activePlaybackMode == .shuffled ? .on : .off

        let timedSingle = UIAction(
            title: "30 分钟·单曲循环",
            image: UIImage(systemName: "timer")
        ) { [weak self] _ in
            self?.setPlaybackMode(.single, timerMinutes: 30)
        }
        let timedSequential = UIAction(
            title: "30 分钟·顺序循环",
            image: UIImage(systemName: "timer")
        ) { [weak self] _ in
            self?.setPlaybackMode(.sequential, timerMinutes: 30)
        }

        var children: [UIMenuElement] = [single, sequential, shuffled, timedSingle, timedSequential]
        if let timerDurationMinutes {
            let timerStatus = UIAction(
                title: "定时已开启：\(timerDurationMinutes) 分钟后停止",
                image: UIImage(systemName: "clock.fill")
            ) { _ in }
            timerStatus.attributes = .disabled
            let cancelTimer = UIAction(
                title: "取消定时",
                image: UIImage(systemName: "timer.square")
            ) { [weak self] _ in
                self?.cancelPlaybackTimer()
            }
            children.append(contentsOf: [timerStatus, cancelTimer])
        }

        return UIMenu(
            title: "播放模式",
            image: UIImage(systemName: activePlaybackMode == .single ? "repeat.1" : "repeat"),
            children: children
        )
    }

    private func volumeMenu() -> UIMenu {
        let high = volumeAction(title: "高", value: 1.0, symbol: "speaker.wave.3.fill")
        let mediumHigh = volumeAction(title: "中高", value: 0.75, symbol: "speaker.wave.3.fill")
        let medium = volumeAction(title: "中", value: 0.5, symbol: "speaker.wave.2.fill")
        let low = volumeAction(title: "低", value: 0.25, symbol: "speaker.wave.1.fill")
        let muted = volumeAction(title: "静音", value: 0, symbol: "speaker.slash.fill")
        return UIMenu(
            title: "声音",
            image: UIImage(systemName: currentVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"),
            children: [high, mediumHigh, medium, low, muted]
        )
    }

    private func volumeAction(title: String, value: Float, symbol: String) -> UIAction {
        let action = UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
            self?.setPlayerVolume(value)
        }
        action.state = abs(currentVolume - value) < 0.01 ? .on : .off
        return action
    }

    private func setPlaybackMode(
        _ mode: ActivePlaybackMode,
        timerMinutes: Int? = nil
    ) {
        activePlaybackMode = mode
        activeRepeatCount = 0
        currentPlayNumber = 1
        switch mode {
        case .single:
            activeRepeatMode = .repeatOne
        case .sequential:
            restoreOriginalQueueKeepingCurrentItem()
            activeRepeatMode = .repeatAll
        case .shuffled:
            shuffleQueueKeepingCurrentItem()
            activeRepeatMode = .repeatAll
        }

        if let timerMinutes {
            sessionEndsAt = Date().addingTimeInterval(TimeInterval(timerMinutes * 60))
            timerDurationMinutes = timerMinutes
        }
        updateLyricsTransportMenu()
    }

    private func restoreOriginalQueueKeepingCurrentItem() {
        let currentID = currentQueueItem?.id
        queueItems = originalQueueItems
        if let currentID,
           let restoredIndex = queueItems.firstIndex(where: { $0.id == currentID }) {
            currentIndex = restoredIndex
        } else {
            currentIndex = 0
        }
    }

    private func shuffleQueueKeepingCurrentItem() {
        guard let currentItem = currentQueueItem else { return }
        var remaining = originalQueueItems.filter { $0.id != currentItem.id }
        remaining.shuffle()
        queueItems = [currentItem] + remaining
        currentIndex = 0
    }

    private func cancelPlaybackTimer() {
        sessionEndsAt = nil
        timerDurationMinutes = nil
        updateLyricsTransportMenu()
    }

    private func setPlayerVolume(_ value: Float) {
        currentVolume = min(1, max(0, value))
        player?.volume = currentVolume
        updateLyricsTransportMenu()
    }

    private func setLyricsMode(_ mode: BabyPlayerLyricsMode) {
        guard mode.isCurrentlyAvailable else { return }
        currentLyricsMode = mode
        if mode == .off {
            lyricLines = []
            currentLyricIndex = nil
            lyricsLabel?.text = nil
            lyricsContainer?.isHidden = true
            updateLyricsTransportMenu()
            return
        }
        if let playback = lyricPlayback {
            lyricLines = playback.lines
            currentLyricIndex = nil
            if let elapsed = player?.currentTime().seconds, elapsed.isFinite {
                updateLyrics(at: elapsed)
            }
            updateLyricsTransportMenu()
            if playback.selectionOrigin == .automatic,
               let item = currentQueueItem {
                startSoundAnalysis(
                    for: item,
                    candidates: lyricCandidates,
                    reference: plainTextReference,
                    waitForBuffer: true
                )
            }
            return
        }
        guard let item = currentQueueItem else {
            updateLyricsTransportMenu()
            return
        }
        prepareLyrics(for: item, mode: mode)
    }

    private func requestSoundAnalysis() {
        guard let item = currentQueueItem else { return }
        if currentLyricsMode == .off {
            currentLyricsMode = .english
            if let playback = lyricPlayback {
                lyricLines = playback.lines
                currentLyricIndex = nil
                if let elapsed = player?.currentTime().seconds, elapsed.isFinite {
                    updateLyrics(at: elapsed)
                }
            }
        }
        guard !isAnalyzingSound else { return }
        if isSearchingLyrics {
            shouldAnalyzeAfterSearch = true
            showAILyricsProgress(.deferred("歌词搜索完成后开始声音分析"))
            return
        }
        startSoundAnalysis(
            for: item,
            candidates: lyricCandidates,
            reference: plainTextReference,
            waitForBuffer: true,
            manuallyRequested: true
        )
    }

    private func refreshLyricsCandidates() {
        guard let item = currentQueueItem else { return }
        lyricsTask?.cancel()
        isSearchingLyrics = true
        lyricsSearchMessage = nil
        updateLyricsTransportMenu()

        lyricsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await BabyLyricsRepository.shared.searchCandidates(
                    for: item.lyricsMedia,
                    forceRefresh: true
                )
                guard !Task.isCancelled, self.currentQueueItem?.id == item.id else { return }
                self.lyricCandidates = Array(candidates.prefix(3))
                self.lyricsSearchMessage = nil
            } catch {
                guard !Task.isCancelled, self.currentQueueItem?.id == item.id else { return }
                self.lyricCandidates = []
                self.lyricsSearchMessage = (error as? LocalizedError)?.errorDescription
                    ?? "在线歌词服务暂时不可用"
            }
            self.isSearchingLyrics = false
            self.updateLyricsTransportMenu()
        }
    }

    private func lyricsCandidateAction(_ candidate: LyricsCandidate, rank: Int) -> UIAction {
        let action = UIAction(
            title: "\(rank). \(candidate.trackName)",
            subtitle: candidateSubtitle(candidate),
            image: UIImage(systemName: "text.quote"),
            state: lyricPlayback?.candidateID == candidate.id ? .on : .off
        ) { [weak self] _ in
            self?.selectLyricsCandidate(candidate)
        }
        return action
    }

    private func candidateSubtitle(_ candidate: LyricsCandidate) -> String {
        let duration = Int(candidate.duration.rounded())
        let minutes = duration / 60
        let seconds = duration % 60
        let durationText = String(format: "%d:%02d", minutes, seconds)
        let differenceText: String
        if let media = currentQueueItem?.lyricsMedia,
           let referenceDuration = media.expectedSongDurationSeconds {
            let label = media.hasSongBoundaryHint ? "歌曲段相差" : "整段视频相差"
            differenceText = "\(label) \(Int(abs(candidate.duration - referenceDuration).rounded())) 秒"
        } else {
            differenceText = "未提供视频时长"
        }
        let preview = String(candidate.previewText.prefix(42))
        let provider = candidate.providerName.map { "\($0) · " } ?? ""
        return "\(provider)匹配 \(candidate.matchPercentage) 分 · \(durationText) · \(differenceText) · \(preview)"
    }

    private func selectLyricsCandidate(_ candidate: LyricsCandidate) {
        guard let media = currentQueueItem?.lyricsMedia else { return }
        // 【MODIFIED】manual lock 必须在创建 Task/await repository 之前同步生效。
        lyricsAutomationGuard.lockManually()
        currentLyricsMode = .english
        pendingLyricSelectionIdentifier = candidate.persistentIdentifier
        lyricsSelectionTask?.cancel()
        let pendingSave = lyricsSaveTask
        lyricsSelectionTask = Task { [weak self] in
            await pendingSave?.value
            guard let self, !Task.isCancelled else { return }
            let playback = await BabyLyricsRepository.shared.playback(
                for: candidate,
                media: media,
                selectionOrigin: .manual
            )
            guard !Task.isCancelled,
                  self.currentQueueItem?.lyricsMedia.id == media.id,
                  self.pendingLyricSelectionIdentifier == candidate.persistentIdentifier else { return }
            self.lyricPlayback = playback
            self.lyricLines = candidate.lines
            self.currentLyricIndex = nil
            self.lyricsSearchMessage = nil
            if let elapsed = self.player?.currentTime().seconds, elapsed.isFinite {
                self.updateLyrics(at: elapsed)
            }
            self.updateLyricsTransportMenu()
            self.persistLyricsPlayback(playback, for: media)
        }
    }

    private func adjustLyricsOffset(by delta: Double) {
        guard var playback = lyricPlayback,
              let media = currentQueueItem?.lyricsMedia else { return }
        // 【MODIFIED】人工校时同样是明确的家长意图，必须立即阻止自动覆盖。
        lyricsAutomationGuard.lockManually()
        playback.timingAdjustment.adjustManually(by: delta)
        applyManualTiming(playback, for: media)
    }

    private func setLyricsOffset(_ offset: Double) {
        guard var playback = lyricPlayback,
              let media = currentQueueItem?.lyricsMedia else { return }
        // 【MODIFIED】直接设置偏移也建立 manual lock。
        lyricsAutomationGuard.lockManually()
        playback.offsetSeconds = offset
        applyManualTiming(playback, for: media)
    }

    private func resetManualLyricsAdjustment() {
        guard var playback = lyricPlayback,
              let media = currentQueueItem?.lyricsMedia else { return }
        // 【MODIFIED】重置人工增量仍属于家长手动操作。
        lyricsAutomationGuard.lockManually()
        playback.timingAdjustment.resetManualAdjustment()
        applyManualTiming(playback, for: media)
    }

    private func applyManualTiming(
        _ playbackToApply: LyricsPlayback,
        for media: LyricsMediaDescriptor
    ) {
        var playback = playbackToApply
        playback.isConfirmed = true
        playback.selectionOrigin = .manual
        lyricPlayback = playback
        currentLyricIndex = nil
        if let elapsed = player?.currentTime().seconds, elapsed.isFinite {
            updateLyrics(at: elapsed)
        }
        updateLyricsTransportMenu()
        persistLyricsPlayback(playback, for: media)
    }

    /// 家长在第一句开始时暂停并执行；一次算出 MP4 片头带来的整体偏移。
    private func alignFirstLyricLineToCurrentTime() {
        guard let firstLine = lyricLines.first,
              let elapsed = player?.currentTime().seconds,
              elapsed.isFinite else { return }
        setLyricsOffset(elapsed - firstLine.time)
    }

    private func confirmCurrentLyrics() {
        guard var playback = lyricPlayback,
              let media = currentQueueItem?.lyricsMedia else { return }
        // 【MODIFIED】确认按下的同步时刻即锁定，不等待持久化。
        lyricsAutomationGuard.lockManually()
        playback.isConfirmed = true
        playback.selectionOrigin = .manual
        lyricPlayback = playback
        updateLyricsTransportMenu()
        persistLyricsPlayback(playback, for: media)
    }

    /// 把快速连续的多次调整串行落盘，避免旧偏移比新偏移更晚写入。
    private func persistLyricsPlayback(
        _ playback: LyricsPlayback,
        for media: LyricsMediaDescriptor
    ) {
        let pendingSave = lyricsSaveTask
        lyricsSaveTask = Task {
            await pendingSave?.value
            _ = try? await BabyLyricsRepository.shared.confirm(playback, for: media)
        }
    }

    private func formattedOffset(_ offset: Double) -> String {
        if abs(offset) < 0.05 { return "0.0 秒" }
        return String(format: "%+.1f 秒", offset)
    }

    private func titleMetadataItem(_ title: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        item.extendedLanguageTag = "zh-Hans"
        return item.copy() as? AVMetadataItem ?? item
    }
}
