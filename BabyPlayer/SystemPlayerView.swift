//
// SystemPlayerView.swift
// 系统播放器桥接：队列、循环、自动下一首、限时播放和片头片尾跳过。
// 最近修改：2026-08-22 增加当前视频的喜欢、不喜欢和屏蔽菜单。
//

import AVKit
import SwiftUI

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
    private var lyricsSaveTask: Task<Void, Never>?
    private var lyricsSelectionTask: Task<Void, Never>?
    private var lyricLines: [TimedLyricLine] = []
    private var lyricPlayback: LyricsPlayback?
    private var lyricCandidates: [LyricsCandidate] = []
    private var isSearchingLyrics = false
    private var isAnalyzingSound = false
    private var lyricsSearchMessage: String?
    private var soundAnalysisMessage: String?
    private var pendingLyricSelectionIdentifier: String?
    private var currentLyricsMode: BabyPlayerLyricsMode = .off
    private var currentLyricIndex: Int?
    private var lyricsContainer: UIView?
    private var lyricsLabel: UILabel?
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
    }

    private func prepareLyrics(for item: BabyPlayerQueueItem, mode: BabyPlayerLyricsMode) {
        lyricsTask?.cancel()
        lyricsSelectionTask?.cancel()
        pendingLyricSelectionIdentifier = nil
        currentLyricsMode = mode
        lyricLines = []
        lyricPlayback = nil
        lyricCandidates = []
        isSearchingLyrics = true
        isAnalyzingSound = false
        lyricsSearchMessage = nil
        soundAnalysisMessage = nil
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
            var playback = storedPlayback
            var foundCandidates: [LyricsCandidate] = []
            do {
                let candidates = try await BabyLyricsRepository.shared.searchCandidates(
                    for: item.lyricsMedia
                )
                guard !Task.isCancelled, self.currentQueueItem?.id == item.id else { return }
                foundCandidates = Array(candidates.prefix(3))
                self.lyricCandidates = foundCandidates
                playback = await BabyLyricsRepository.shared.resolvedLyrics(
                    for: item.lyricsMedia,
                    candidates: candidates
                )
            } catch {
                guard !Task.isCancelled, self.currentQueueItem?.id == item.id else { return }
                self.lyricCandidates = []
                self.lyricsSearchMessage = (error as? LocalizedError)?.errorDescription
                    ?? "在线歌词服务暂时不可用"
            }

            guard !Task.isCancelled, self.currentQueueItem?.id == item.id else { return }
            self.isSearchingLyrics = false
            self.lyricPlayback = playback
            if mode != .off, let playback {
                self.lyricLines = playback.lines
                if let elapsed = self.player?.currentTime().seconds, elapsed.isFinite {
                    self.updateLyrics(at: elapsed)
                }
            }
            self.updateLyricsTransportMenu()

            let canAutomaticallyAnalyze = mode != .off
                && (playback == nil || playback?.selectionOrigin == .automatic)
            guard canAutomaticallyAnalyze else { return }
            self.isAnalyzingSound = true
            self.soundAnalysisMessage = "等待播放缓冲稳定…"
            self.updateLyricsTransportMenu()
            guard await self.waitForPlaybackBuffer(itemID: item.id) else {
                guard !Task.isCancelled, self.currentQueueItem?.id == item.id else { return }
                self.isAnalyzingSound = false
                self.soundAnalysisMessage = "播放优先：本次暂缓声音分析"
                self.updateLyricsTransportMenu()
                return
            }
            self.soundAnalysisMessage = nil
            do {
                let outcome = try await BabyPlayerASRCoordinator.shared.analyze(
                    item: item,
                    candidates: foundCandidates,
                    reference: plainReference
                )
                guard !Task.isCancelled, self.currentQueueItem?.id == item.id else { return }
                self.lyricCandidates = Array(outcome.candidates.prefix(4))
                self.soundAnalysisMessage = outcome.message
                if let selected = outcome.selected,
                   self.lyricPlayback?.selectionOrigin != .manual,
                   let verified = try await BabyLyricsRepository.shared.applyAutomaticRecommendation(
                       selected,
                       autoOffsetSeconds: outcome.offsetSeconds,
                       for: item.lyricsMedia
                   ) {
                    self.lyricPlayback = verified
                    if mode != .off {
                        self.lyricLines = verified.lines
                        self.currentLyricIndex = nil
                        if let elapsed = self.player?.currentTime().seconds, elapsed.isFinite {
                            self.updateLyrics(at: elapsed)
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled, self.currentQueueItem?.id == item.id else { return }
                if case BabyPlayerASRError.notConfigured = error {
                    self.soundAnalysisMessage = nil
                } else {
                    self.soundAnalysisMessage = (error as? LocalizedError)?.errorDescription
                        ?? "声音歌词生成暂时不可用"
                }
            }
            self.isAnalyzingSound = false
            self.updateLyricsTransportMenu()
        }
    }

    /// 避免远程 MP4 同时播放和导出时争抢局域网带宽；缓冲不稳就让本轮分析让路。
    private func waitForPlaybackBuffer(itemID: String) async -> Bool {
        for _ in 0..<20 {
            guard !Task.isCancelled, currentQueueItem?.id == itemID else { return false }
            if player?.currentItem?.isPlaybackLikelyToKeepUp == true { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func updateLyrics(at elapsed: Double) {
        guard elapsed.isFinite, !lyricLines.isEmpty else { return }
        let adjustedElapsed = elapsed - (lyricPlayback?.offsetSeconds ?? 0)
        let index = lyricLines.lastIndex { $0.time <= adjustedElapsed }
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
                title: "正在生成时间轴并校正文案…",
                image: UIImage(systemName: "waveform.badge.magnifyingglass")
            ) { _ in }
            analyzing.attributes = .disabled
            children.append(analyzing)
        } else if let soundAnalysisMessage {
            let result = UIAction(
                title: soundAnalysisMessage,
                image: UIImage(systemName: "waveform")
            ) { _ in }
            result.attributes = .disabled
            children.append(result)
        }

        if let playback = lyricPlayback {
            let offset = playback.offsetSeconds
            let statusTitle = playback.isConfirmed ? "已绑定" : "已选择·未确认"
            let status = UIAction(
                title: "\(statusTitle)  总计 \(formattedOffset(offset)) · 自动 \(formattedOffset(playback.autoOffsetSeconds)) · 手动 \(formattedOffset(playback.manualAdjustmentSeconds))",
                image: UIImage(systemName: playback.isConfirmed ? "checkmark.circle.fill" : "questionmark.circle")
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

        transportBarCustomMenuItems = [
            UIMenu(
                title: "字幕与歌词",
                image: UIImage(systemName: "captions.bubble.fill"),
                children: children
            ),
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
            return
        }
        guard let item = currentQueueItem else {
            updateLyricsTransportMenu()
            return
        }
        prepareLyrics(for: item, mode: mode)
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
        playback.timingAdjustment.adjustManually(by: delta)
        applyManualTiming(playback, for: media)
    }

    private func setLyricsOffset(_ offset: Double) {
        guard var playback = lyricPlayback,
              let media = currentQueueItem?.lyricsMedia else { return }
        playback.offsetSeconds = offset
        applyManualTiming(playback, for: media)
    }

    private func resetManualLyricsAdjustment() {
        guard var playback = lyricPlayback,
              let media = currentQueueItem?.lyricsMedia else { return }
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
