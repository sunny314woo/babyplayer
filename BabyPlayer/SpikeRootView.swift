//
// SpikeRootView.swift
// BabyPlayer V1 界面：家长配对、儿童首页、家长设置和系统播放器入口。
// 最近修改：2026-08-22 接入应用封面、封面抽帧和本地评分入口。
//

import SwiftUI

enum BabyPlayerPalette {
    static let ink = Color.white
    static let muted = Color(red: 0.64, green: 0.67, blue: 0.72)
    static let coral = Color(red: 0.40, green: 0.67, blue: 1.00)
    static let berry = Color(red: 0.55, green: 0.49, blue: 0.96)
    static let leaf = Color(red: 0.42, green: 0.82, blue: 0.64)
    static let sun = Color(red: 0.98, green: 0.78, blue: 0.34)
    static let milk = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let dayPanel = Color(red: 0.08, green: 0.10, blue: 0.14)
    static let sleepPanel = Color(red: 0.10, green: 0.09, blue: 0.15)
}

struct SpikeRootView: View {
    @StateObject private var model = SpikeViewModel()
    @StateObject private var smbModel = SMBHomeViewModel()
    @State private var showSettings = false
    @State private var activeMediaSource = BabyPlayerMediaSourcePreference.load()

    var body: some View {
        Group {
            if activeMediaSource == .samba {
                SMBChildrenHomeView(
                    model: smbModel,
                    preferences: model,
                    showSettings: $showSettings
                )
            } else {
                switch model.appState {
                case .onboarding:
                    OnboardingView(model: model)
                case .loading:
                    LoadingLibraryView(repair: model.startRePairing)
                case .home:
                    ChildrenHomeView(model: model, showSettings: $showSettings)
                case .unavailable:
                    UnavailableLibraryView(
                        retry: model.retryLoading,
                        repair: model.startRePairing
                    )
                }
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            ParentSettingsView(
                model: model,
                smbModel: smbModel,
                activeMediaSource: activeMediaSource,
                selectJellyfin: { selectMediaSource(.jellyfin) },
                selectSamba: { selectMediaSource(.samba) },
                close: { showSettings = false }
            )
        }
        .fullScreenCover(item: $model.activePlayback) { selection in
            SystemPlayerView(
                selection: selection,
                onExit: model.endPlayback,
                onRate: { itemID, rating in
                    model.setRating(rating, for: itemID)
                },
                ratingFor: model.rating(for:),
                onProgress: model.updatePlaybackResume,
                onFinished: model.clearPlaybackResume,
                onSmartSkipEnabledChange: { model.smartSkipEnabled = $0 }
            )
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $smbModel.activePlayback) { selection in
            SystemPlayerView(
                selection: selection,
                onExit: smbModel.endPlayback,
                onRate: { itemID, rating in
                    model.setRating(rating, for: itemID)
                },
                ratingFor: model.rating(for:),
                onProgress: model.updatePlaybackResume,
                onFinished: model.clearPlaybackResume,
                onSmartSkipEnabledChange: { model.smartSkipEnabled = $0 }
            )
            .ignoresSafeArea()
        }
        .onReceive(smbModel.$mediaItems) { items in
            model.registerSMBMediaItems(items)
        }
    }

    private func selectMediaSource(_ source: BabyPlayerMediaSourceKind) {
        BabyPlayerMediaSourcePreference.save(source)
        activeMediaSource = source
        showSettings = false
        if source == .samba {
            smbModel.connectIfNeeded()
        }
    }
}

struct OrchardBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.065, blue: 0.085),
                    BabyPlayerPalette.milk,
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(BabyPlayerPalette.coral.opacity(0.09))
                .frame(width: 760, height: 760)
                .blur(radius: 90)
                .offset(x: -640, y: -430)
            Circle()
                .fill(BabyPlayerPalette.berry.opacity(0.08))
                .frame(width: 680, height: 680)
                .blur(radius: 100)
                .offset(x: 720, y: 430)
            Circle()
                .fill(Color.white.opacity(0.025))
                .frame(width: 520, height: 520)
                .blur(radius: 80)
                .offset(x: 520, y: -430)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Onboarding

private struct OnboardingView: View {
    @ObservedObject var model: SpikeViewModel

    var body: some View {
        ZStack {
            OrchardBackground()
            switch model.onboardingStep {
            case .welcome:
                welcome
            case .server:
                server
            case .code:
                pairingCode
            case .success:
                success
            }
        }
        .foregroundStyle(BabyPlayerPalette.ink)
    }

    private var welcome: some View {
        VStack(spacing: 34) {
            ZStack {
                Image("BabyPlayerCover")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 280, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                    .shadow(color: BabyPlayerPalette.coral.opacity(0.28), radius: 30, y: 16)
            }
            Text("BabyPlayer")
                .font(.system(size: 70, weight: .bold, design: .rounded))
            Text("打开就能看，专属宝宝的 Apple TV 播放器")
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
            Button("开始设置", action: model.showServerStep)
                .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.coral))
        }
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("连接家里的媒体库")
                .font(.system(size: 54, weight: .bold, design: .rounded))
            Text("请输入 Jellyfin 服务器地址")
                .font(.title2)
                .foregroundStyle(BabyPlayerPalette.muted)
            TextField("例如 http://192.168.1.100:8096", text: $model.serverAddress)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 28)
                .frame(width: 980, height: 78)
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(BabyPlayerPalette.coral.opacity(0.75), lineWidth: 3)
                }
            HStack(spacing: 22) {
                Button("连接并生成配对码", action: model.beginQuickConnect)
                    .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.coral))
                    .disabled(model.isWorking)
                if model.isWorking { ProgressView() }
            }
            if !model.statusText.isEmpty {
                Text(model.statusText)
                    .font(.title3)
                    .foregroundStyle(BabyPlayerPalette.muted)
            }
        }
        .padding(64)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 38))
    }

    private var pairingCode: some View {
        VStack(spacing: 30) {
            Text("在 Jellyfin 中批准 BabyPlayer")
                .font(.system(size: 48, weight: .bold, design: .rounded))
            Text(model.statusText)
                .font(.title2)
                .foregroundStyle(BabyPlayerPalette.muted)
            HStack(spacing: 16) {
                ForEach(Array((model.quickConnectCode ?? "------").enumerated()), id: \.offset) { _, digit in
                    Text(String(digit))
                        .font(.system(size: 70, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.black.opacity(0.86))
                        .frame(width: 118, height: 142)
                        .background(
                            LinearGradient(
                                colors: [.white, Color(red: 1.00, green: 0.87, blue: 0.82)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: RoundedRectangle(cornerRadius: 24)
                        )
                        .shadow(color: BabyPlayerPalette.coral.opacity(0.16), radius: 28, y: 18)
                }
            }
            HStack(spacing: 12) {
                if model.isWorking {
                    ProgressView()
                    Text("批准后会自动继续")
                        .font(.title3)
                        .foregroundStyle(BabyPlayerPalette.muted)
                } else {
                    Button("重新生成配对码", action: model.beginQuickConnect)
                        .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.coral))
                }
            }
        }
    }

    private var success: some View {
        VStack(spacing: 34) {
            Image(systemName: "checkmark")
                .font(.system(size: 78, weight: .heavy))
                .foregroundStyle(Color(red: 0.31, green: 0.48, blue: 0.35))
                .frame(width: 154, height: 154)
                .background(BabyPlayerPalette.leaf.opacity(0.42), in: Circle())
            Text("配对成功")
                .font(.system(size: 58, weight: .bold, design: .rounded))
            Text(model.statusText)
                .font(.title2)
                .foregroundStyle(BabyPlayerPalette.muted)
            Button("进入 BabyPlayer", action: model.enterHome)
                .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.coral))
        }
    }
}

// MARK: - Home

private struct ChildrenHomeView: View {
    @ObservedObject var model: SpikeViewModel
    @Binding var showSettings: Bool

    private var pages: [[JellyfinMediaItem]] {
        stride(from: 0, to: model.filteredMediaItems.count, by: 12).map { start in
            Array(model.filteredMediaItems[start..<min(start + 12, model.filteredMediaItems.count)])
        }
    }

    var body: some View {
        ZStack {
            OrchardBackground()
            VStack(alignment: .leading, spacing: 14) {
                header
                mediaPages
                footer
            }
            // SwiftUI 已应用 tvOS 80/60pt 安全区，不再重复叠加大边距。
            .padding(.horizontal, 4)
        }
        .onExitCommand { }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("音乐视频")
                .font(.system(size: 31, weight: .bold, design: .rounded))
            Text("\(model.filteredMediaItems.count) 首")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
            Button {
                model.playAll(shuffled: false)
            } label: {
                Label("顺序播放", systemImage: "play.fill")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(LowContrastButtonStyle())
            Button {
                model.playAll(shuffled: true)
            } label: {
                Label("随机播放", systemImage: "shuffle")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(LowContrastButtonStyle())
            Button {
                model.playAllByPreference()
            } label: {
                Label("偏好优先", systemImage: "heart.fill")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(LowContrastButtonStyle())
            Spacer()
            Button(action: model.rescanLibrary) {
                Label(model.isWorking ? "扫描中" : "刷新媒体库", systemImage: "arrow.clockwise")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(LowContrastButtonStyle())
            .disabled(model.isWorking)
            Button {
                showSettings = true
            } label: {
                Label("家长设置", systemImage: "gearshape.fill")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(LowContrastButtonStyle())
        }
    }

    @ViewBuilder
    private var mediaPages: some View {
        if pages.isEmpty {
            Text("这个分类还没有内容")
                .font(.title2)
                .foregroundStyle(BabyPlayerPalette.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                        MediaGridPage(
                            items: page,
                            coverSource: model.coverSource,
                            play: model.play
                        )
                        .containerRelativeFrame(.vertical)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .background(BabyPlayerPalette.dayPanel.opacity(0.92), in: RoundedRectangle(cornerRadius: 26))
            .clipShape(RoundedRectangle(cornerRadius: 28))
        }
    }

    private var footer: some View {
        HStack {
            Text(model.statusText.isEmpty
                 ? "上下翻页  ·  \(model.filteredMediaItems.count) 个视频"
                 : model.statusText)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
            Spacer()
            Text("定时和片头片尾在家长设置中修改")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
        }
    }

}

/// Samba 与 Jennifer 共用同一个 BabyPlayer 首页信息架构。
/// 区别只在数据来源和 AVAsset 构建方式，儿童不会进入服务器设置页播放。
private struct SMBChildrenHomeView: View {
    @ObservedObject var model: SMBHomeViewModel
    @ObservedObject var preferences: SpikeViewModel
    @Binding var showSettings: Bool

    private var visibleItems: [SMBSpikeMediaItem] {
        let items = model.mediaItems.filter {
            preferences.rating(for: sourceID(for: $0)) != .blocked
        }
        guard let resumeID = preferences.playbackResumeState?.itemID,
              let current = items.first(where: {
                  preferences.preferenceID(for: sourceID(for: $0)) == resumeID
              }) else {
            return items
        }
        return [current] + items.filter {
            preferences.preferenceID(for: sourceID(for: $0)) != resumeID
        }
    }

    private var pages: [[SMBSpikeMediaItem]] {
        stride(from: 0, to: visibleItems.count, by: 12).map { start in
            Array(visibleItems[start..<min(start + 12, visibleItems.count)])
        }
    }

    var body: some View {
        ZStack {
            OrchardBackground()
            VStack(alignment: .leading, spacing: 14) {
                header
                mediaPages
                footer
            }
            .padding(.horizontal, 4)
        }
        .task { model.connectIfNeeded() }
        .onExitCommand { }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("音乐视频")
                .font(.system(size: 31, weight: .bold, design: .rounded))
            Text("\(visibleItems.count) 首")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
            Button {
                play(items: visibleItems, startIndex: 0, behavior: .sequential)
            } label: {
                Label("顺序播放", systemImage: "play.fill")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(LowContrastButtonStyle())
            .disabled(visibleItems.isEmpty)
            Button {
                play(items: visibleItems, startIndex: 0, behavior: .shuffle)
            } label: {
                Label("随机播放", systemImage: "shuffle")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(LowContrastButtonStyle())
            .disabled(visibleItems.isEmpty)
            Button {
                let liked = visibleItems.filter {
                    preferences.rating(for: sourceID(for: $0)) == .liked
                }.shuffled()
                let unrated = visibleItems.filter {
                    preferences.rating(for: sourceID(for: $0)) == .unrated
                }.shuffled()
                let disliked = visibleItems.filter {
                    preferences.rating(for: sourceID(for: $0)) == .disliked
                }.shuffled()
                play(items: liked + unrated + disliked, startIndex: 0, behavior: .sequential)
            } label: {
                Label("偏好优先", systemImage: "heart.fill")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(LowContrastButtonStyle())
            .disabled(visibleItems.isEmpty)
            Spacer()
            Button(action: model.connectAndScan) {
                Label(model.isWorking ? "扫描中" : "刷新媒体库", systemImage: "arrow.clockwise")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(LowContrastButtonStyle())
            .disabled(model.isWorking)
            Button { showSettings = true } label: {
                Label("家长设置", systemImage: "gearshape.fill")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
            }
            .buttonStyle(LowContrastButtonStyle())
        }
    }

    @ViewBuilder
    private var mediaPages: some View {
        if pages.isEmpty {
            VStack(spacing: 22) {
                if model.isWorking { ProgressView() }
                Text(model.statusText)
                    .font(.title2)
                    .foregroundStyle(BabyPlayerPalette.muted)
                    .multilineTextAlignment(.center)
                if !model.isWorking {
                    Button("重新连接", action: model.connectAndScan)
                        .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.coral))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                        SMBMediaGridPage(
                            items: page,
                            coverSource: model.coverSource(for:)
                        ) { item in
                            guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
                            play(items: visibleItems, startIndex: index, behavior: .repeatOne)
                        }
                        .containerRelativeFrame(.vertical)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .background(BabyPlayerPalette.dayPanel.opacity(0.92), in: RoundedRectangle(cornerRadius: 26))
            .clipShape(RoundedRectangle(cornerRadius: 28))
        }
    }

    private var footer: some View {
        HStack {
            Text(model.statusText)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
            Spacer()
            Text("光猫 U 盘 · Samba · 播放不经过 Mac")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
        }
    }

    private func sourceID(for item: SMBSpikeMediaItem) -> String {
        "smb:\(item.path)"
    }

    private func play(
        items: [SMBSpikeMediaItem],
        startIndex: Int,
        behavior: BabyPlayerPlaybackBehavior
    ) {
        guard !items.isEmpty else { return }
        let selectedID = sourceID(for: items[min(max(0, startIndex), items.count - 1)])
        let selectedPreferenceID = preferences.preferenceID(for: selectedID)
        model.play(
            items,
            startIndex: startIndex,
            behavior: behavior,
            playbackTimerMinutes: preferences.playbackTimerMinutes,
            introSkipSeconds: preferences.introSkipSeconds,
            outroSkipSeconds: preferences.outroSkipSeconds,
            lyricsMode: preferences.lyricsMode,
            smartSkipEnabled: preferences.smartSkipEnabled,
            preferenceID: { item in
                preferences.preferenceID(for: sourceID(for: item))
            },
            localMediaMigrationKey: { item in
                preferences.contentMigrationKey(for: sourceID(for: item))
            },
            startPositionSeconds: preferences.playbackResumeState.flatMap {
                $0.itemID == selectedPreferenceID ? $0.positionSeconds : nil
            }
        )
    }
}

private struct SMBMediaGridPage: View {
    let items: [SMBSpikeMediaItem]
    let coverSource: (SMBSpikeMediaItem) -> BabyPlayerCoverSource
    let play: (SMBSpikeMediaItem) -> Void

    private let columns = Array(
        repeating: GridItem(.fixed(414), spacing: 14, alignment: .top),
        count: 4
    )

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
            ForEach(items) { item in
                Button { play(item) } label: {
                    MediaCard(
                        title: item.displayName,
                        coverSource: coverSource(item),
                        tint: BabyPlayerPalette.coral
                    )
                }
                .buttonStyle(MediaCardButtonStyle(tint: BabyPlayerPalette.coral))
                .accessibilityLabel("播放 \(item.displayName)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct MediaGridPage: View {
    let items: [JellyfinMediaItem]
    let coverSource: (JellyfinMediaItem) -> BabyPlayerCoverSource?
    let play: (JellyfinMediaItem) -> Void

    private let columns = Array(
        repeating: GridItem(.fixed(414), spacing: 14, alignment: .top),
        count: 4
    )

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
            ForEach(items) { item in
                Button {
                    play(item)
                } label: {
                    MediaCard(
                        title: item.name,
                        coverSource: coverSource(item),
                        tint: BabyPlayerPalette.coral
                    )
                }
                .buttonStyle(MediaCardButtonStyle(tint: BabyPlayerPalette.coral))
                .accessibilityLabel("播放 \(item.name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct MediaCard: View {
    let title: String
    let coverSource: BabyPlayerCoverSource?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MediaCoverView(source: coverSource, tint: tint)
            .id(coverSource?.viewIdentity ?? "no-cover")
            .frame(width: 400, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.28), in: Circle())
                    .padding(10)
            }
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.ink)
                .lineLimit(1)
                .frame(width: 400, alignment: .leading)
        }
    }

}

// MARK: - Settings and states
// 最近修改：2026-08-23 取消完整歌曲 M4A 音频库入口，家长设置只保留声音分析额度。

private struct ParentSettingsView: View {
    @ObservedObject var model: SpikeViewModel
    @ObservedObject var smbModel: SMBHomeViewModel
    let activeMediaSource: BabyPlayerMediaSourceKind
    let selectJellyfin: () -> Void
    let selectSamba: () -> Void
    let close: () -> Void
    // 【MODIFIED】额度读取与临时分段生命周期解耦，不展示已取消的完整音频库。
    @StateObject private var asrUsage = BabyPlayerASRUsageViewModel()
    @State private var confirmClear = false
    @State private var showsBatchAnalysis = false
    @State private var showsMediaSourceSelection = false
    @State private var showsSMBConnectionEditor = false

    var body: some View {
        ZStack {
            OrchardBackground()
            if showsSMBConnectionEditor {
                SMBSpikeView {
                    showsSMBConnectionEditor = false
                    smbModel.connectAndScan()
                }
            } else if showsMediaSourceSelection {
                ParentMediaSourceSelectionView(
                    jellyfinSummary: model.connectionSummary,
                    activeMediaSource: activeMediaSource,
                    selectJellyfin: {
                        showsMediaSourceSelection = false
                        selectJellyfin()
                    },
                    selectSMB: {
                        showsMediaSourceSelection = false
                        selectSamba()
                    },
                    close: { showsMediaSourceSelection = false }
                )
            } else if showsBatchAnalysis {
                BabyPlayerBatchAnalysisView(
                    model: model,
                    close: { showsBatchAnalysis = false }
                )
            } else {
                settingsContent
            }
        }
        .onExitCommand {
            if showsSMBConnectionEditor {
                showsSMBConnectionEditor = false
                smbModel.connectAndScan()
            } else if showsMediaSourceSelection {
                showsMediaSourceSelection = false
            } else if showsBatchAnalysis {
                showsBatchAnalysis = false
            } else {
                close()
            }
        }
        .task {
            asrUsage.refresh()
            model.refreshBatchAnalysisInventory()
        }
        .alert("清除 Jellyfin 配对？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) { }
            Button("清除", role: .destructive) {
                close()
                model.clearPairing()
            }
        } message: {
            Text("下次打开 BabyPlayer 需要重新输入配对码。")
        }
    }

    private var settingsContent: some View {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("家长设置")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                    Spacer()
                    Button("完成", action: close)
                        .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.berry))
                }

                ScrollView {
                    VStack(spacing: 2) {
                        if BabyPlayerFeatureFlags.isSMBDirectPlaybackSpikeEnabled {
                            Button {
                                showsMediaSourceSelection = true
                            } label: {
                                SettingsActionRow(
                                    title: "媒体源",
                                    value: activeMediaSource == .samba
                                        ? "光猫 U 盘 · Samba · \(smbModel.mediaItems.isEmpty ? "连接中" : "已连接")"
                                        : "Jennifer · Jellyfin · \(model.connectionSummary)"
                                )
                            }
                        } else {
                            SettingsInfoRow(
                                title: "媒体源",
                                value: "Jennifer · Jellyfin · \(model.connectionSummary)"
                            )
                        }
                        if BabyPlayerFeatureFlags.isSMBDirectPlaybackSpikeEnabled {
                            Button {
                                showsSMBConnectionEditor = true
                            } label: {
                                SettingsActionRow(
                                    title: "编辑 Samba 连接",
                                    value: "服务器、共享、目录与账号"
                                )
                            }
                        }
                        Button {
                            if activeMediaSource == .samba {
                                smbModel.connectAndScan()
                            } else {
                                model.rescanLibrary()
                            }
                        } label: {
                            SettingsActionRow(
                                title: activeMediaSource == .samba
                                    ? "刷新光猫 U 盘"
                                    : "刷新 Jennifer 媒体库",
                                value: "\(activeMediaSource == .samba ? smbModel.mediaItems.count : model.mediaItems.count) 个视频"
                            )
                        }
                        Button {
                            close()
                            model.startRePairing()
                        } label: {
                            SettingsActionRow(title: "重新配对", value: "Quick Connect")
                        }
                        SettingsLyricsModeMenu(selection: $model.lyricsMode)
                        SettingsInfoRow(title: "本月声音分析", value: asrUsage.usageText)
                        Button {
                            model.refreshBatchAnalysisInventory()
                            showsBatchAnalysis = true
                        } label: {
                            SettingsActionRow(
                                title: "批量生成 AI 双语字幕",
                                value: model.batchAnalysisItems.isEmpty && !model.mediaItems.isEmpty
                                    ? "读取中…"
                                    : model.batchAnalysisSummary
                            )
                        }
                        blockedRatingsSection
                        SettingsIntegerMenu(
                            title: "定时关闭",
                            options: [0, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180],
                            selection: $model.playbackTimerMinutes,
                            valueText: { $0 == 0 ? "关闭" : "\($0) 分钟" }
                        )
                        SettingsIntegerMenu(
                            title: "手工片头（备用）",
                            options: [0, 5, 10, 15, 20, 30, 45, 60, 90, 120],
                            selection: $model.introSkipSeconds,
                            valueText: { $0 == 0 ? "未设置" : "\($0) 秒" }
                        )
                        SettingsIntegerMenu(
                            title: "手工片尾（备用）",
                            options: [0, 5, 10, 15, 20, 30, 45, 60, 90, 120],
                            selection: $model.outroSkipSeconds,
                            valueText: { $0 == 0 ? "未设置" : "\($0) 秒" }
                        )
                        SettingsInfoRow(title: "关于", value: "BabyPlayer 0.4")
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            SettingsActionRow(title: "清除配对", value: "")
                        }
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .padding(12)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 28))
                }
            }
            .foregroundStyle(BabyPlayerPalette.ink)
            // 与首页一致：依赖 tvOS 安全区，只保留少量版面呼吸空间。
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
    }

    /// 家长可查看并解除屏蔽；儿童首页不会渲染这组记录。
    @ViewBuilder
    private var blockedRatingsSection: some View {
        if model.blockedContentItems.isEmpty {
            SettingsInfoRow(title: "屏蔽的视频", value: "暂无")
        } else {
            SettingsInfoRow(title: "屏蔽的视频", value: "\(model.blockedContentItems.count) 个")
            ForEach(model.blockedContentItems) { item in
                Button {
                    model.unblock(contentID: item.id)
                } label: {
                    SettingsActionRow(title: item.title, value: "解除屏蔽")
                }
            }
        }
    }
}

/// 家长手工选择播放轨道；SMB 模式直接进入路由器 U 盘媒体库。
private struct ParentMediaSourceSelectionView: View {
    let jellyfinSummary: String
    let activeMediaSource: BabyPlayerMediaSourceKind
    let selectJellyfin: () -> Void
    let selectSMB: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("选择媒体源")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                    Text("手工切换播放轨道；播放中不会自动跳到另一个来源。")
                        .font(.system(size: 21, weight: .medium, design: .rounded))
                        .foregroundStyle(BabyPlayerPalette.muted)
                }
                Spacer()
                Button("返回", action: close)
                    .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.berry))
            }

            VStack(spacing: 16) {
                Button(action: selectJellyfin) {
                    MediaSourceChoiceLabel(
                        icon: "desktopcomputer",
                        title: "Jennifer",
                        subtitle: "Jellyfin · \(jellyfinSummary) · 需要 Mac 服务",
                        badge: activeMediaSource == .jellyfin ? "当前默认" : "选择"
                    )
                }
                Button(action: selectSMB) {
                    MediaSourceChoiceLabel(
                        icon: "externaldrive.connected.to.line.below",
                        title: "光猫 U 盘（Samba）",
                        subtitle: "192.168.1.1 · usb-0781-060116_1/sss73 · 播放不经过 Mac",
                        badge: activeMediaSource == .samba ? "当前默认" : "选择"
                    )
                }
            }
            .buttonStyle(MediaSourceChoiceButtonStyle())

            Text("字幕生成仍可使用 Mac；Mac 离线时只影响新字幕任务，不影响 U 盘视频和已有字幕。")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
            Spacer()
        }
        .foregroundStyle(BabyPlayerPalette.ink)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}

private struct MediaSourceChoiceLabel: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .semibold))
                .frame(width: 76)
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(BabyPlayerPalette.muted)
            }
            Spacer()
            Text(badge)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .padding(.horizontal, 18)
                .frame(height: 42)
                .background(BabyPlayerPalette.leaf.opacity(0.3), in: Capsule())
            Image(systemName: "chevron.right")
                .foregroundStyle(BabyPlayerPalette.muted)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, minHeight: 116)
        .contentShape(RoundedRectangle(cornerRadius: 24))
    }
}

private struct MediaSourceChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MediaSourceChoiceFocusLabel(configuration: configuration)
    }
}

private struct MediaSourceChoiceFocusLabel: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .background(
                isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 24)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(
                        isFocused ? BabyPlayerPalette.coral : Color.white.opacity(0.18),
                        lineWidth: isFocused ? 4 : 2
                    )
            }
            .scaleEffect(isFocused ? 1.018 : (configuration.isPressed ? 0.985 : 1))
            .shadow(color: isFocused ? BabyPlayerPalette.coral.opacity(0.25) : .clear, radius: 18, y: 8)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

/// 家长批量 AI 工作台：左右两栏直接对照已完成与待生成项目，任务在后台串行运行。
private enum BabyPlayerBatchPalette {
    static let surface = Color(red: 0.035, green: 0.055, blue: 0.085)
    static let elevated = Color(red: 0.065, green: 0.09, blue: 0.13)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 0.82, green: 0.86, blue: 0.92)
    static let completedPanel = Color(red: 0.025, green: 0.12, blue: 0.085)
    static let completedRow = Color(red: 0.045, green: 0.19, blue: 0.135)
    static let completedAccent = Color(red: 0.35, green: 0.94, blue: 0.63)
    static let pendingPanel = Color(red: 0.15, green: 0.075, blue: 0.035)
    static let pendingRow = Color(red: 0.24, green: 0.115, blue: 0.045)
    static let pendingAccent = Color(red: 1.0, green: 0.68, blue: 0.25)
    static let progress = Color(red: 0.35, green: 0.76, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.82, blue: 0.28)
}

private struct BabyPlayerBatchAnalysisView: View {
    @ObservedObject var model: SpikeViewModel
    let close: () -> Void

    private var progress: Double {
        guard !model.batchAnalysisItems.isEmpty else { return 0 }
        return Double(model.completedBatchAnalysisItems.count)
            / Double(model.batchAnalysisItems.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AI 字幕果园")
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .foregroundStyle(BabyPlayerBatchPalette.primaryText)
                    Text("Mac 本地 8011 处理 · 已有结果从缺失阶段继续 · ASR 失败自动暂停")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(BabyPlayerBatchPalette.secondaryText)
                }
                Spacer()
                Text(model.batchAnalysisUsageText)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 22)
                    .frame(height: 54)
                    .background(BabyPlayerBatchPalette.warning, in: Capsule())
                Button("返回", action: close)
                    .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.berry))
            }

            HStack(spacing: 14) {
                Text(model.batchAnalysisSummary)
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(BabyPlayerBatchPalette.primaryText)
                ProgressView(value: progress)
                    .tint(BabyPlayerBatchPalette.progress)
                    .frame(maxWidth: .infinity)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 23, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(BabyPlayerBatchPalette.progress)
            }
            .padding(.horizontal, 22)
            .frame(height: 64)
            .background(BabyPlayerBatchPalette.elevated, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.24), lineWidth: 2)
            }

            HStack(alignment: .top, spacing: 18) {
                BatchAnalysisColumn(
                    title: "已生成",
                    subtitle: "双语字幕已保存在 Apple TV",
                    count: model.completedBatchAnalysisItems.count,
                    accent: BabyPlayerBatchPalette.completedAccent,
                    background: BabyPlayerBatchPalette.completedPanel,
                    rowBackground: BabyPlayerBatchPalette.completedRow,
                    items: model.completedBatchAnalysisItems
                )
                BatchAnalysisColumn(
                    title: "等待生成",
                    subtitle: "Mac 本地处理 · 按 ASR 剩余额度从短视频开始",
                    count: model.pendingBatchAnalysisItems.count,
                    accent: BabyPlayerBatchPalette.pendingAccent,
                    background: BabyPlayerBatchPalette.pendingPanel,
                    rowBackground: BabyPlayerBatchPalette.pendingRow,
                    items: model.pendingBatchAnalysisItems
                )
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 18) {
                if model.isBatchAnalyzing {
                    Button("暂停任务", action: model.stopBatchAnalysis)
                        .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.berry))
                } else {
                    Button(
                        model.isBatchAnalysisPaused ? "继续生成" : "一键补全",
                        action: model.startBatchAnalysis
                    )
                    .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.coral))
                    .disabled(model.pendingBatchAnalysisItems.isEmpty)
                }
                Button("刷新统计", action: model.refreshBatchAnalysisInventory)
                    .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerBatchPalette.elevated))
                    .disabled(model.isBatchAnalyzing)
                Text(model.batchAnalysisStatusText)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(BabyPlayerBatchPalette.primaryText)
                    .lineLimit(2)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 58)
                    .background(BabyPlayerBatchPalette.elevated, in: RoundedRectangle(cornerRadius: 16))
                Spacer()
            }
            .frame(minHeight: 68)
        }
        .foregroundStyle(BabyPlayerBatchPalette.primaryText)
        .background(BabyPlayerBatchPalette.surface.opacity(0.92))
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .task { model.refreshBatchAnalysisInventory() }
    }
}

private struct BatchAnalysisColumn: View {
    let title: String
    let subtitle: String
    let count: Int
    let accent: Color
    let background: Color
    let rowBackground: Color
    let items: [BabyPlayerBatchAnalysisItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 31, weight: .heavy, design: .rounded))
                        .foregroundStyle(BabyPlayerBatchPalette.primaryText)
                    Text(subtitle)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(BabyPlayerBatchPalette.secondaryText)
                }
                Spacer()
                Text("\(count)")
                    .font(.system(size: 36, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    if items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(accent)
                            Text(title == "已生成" ? "还没有完整结果" : "全部完成")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(BabyPlayerBatchPalette.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(items) { item in
                            BatchAnalysisItemRow(
                                item: item,
                                accent: accent,
                                background: rowBackground
                            )
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .stroke(accent, lineWidth: 3)
        }
    }
}

private struct BatchAnalysisItemRow: View {
    let item: BabyPlayerBatchAnalysisItem
    let accent: Color
    let background: Color

    private var icon: String {
        switch item.state {
        case .completed: return "checkmark.circle.fill"
        case .processing: return "waveform.circle.fill"
        case .quotaLimited: return "hourglass.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .pending: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .failed: return BabyPlayerPalette.berry
        case .quotaLimited: return BabyPlayerBatchPalette.warning
        case .completed, .processing, .pending: return accent
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(BabyPlayerBatchPalette.primaryText)
                    .lineLimit(1)
                Text(item.state.detailText)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(BabyPlayerBatchPalette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.state.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .tint(statusColor)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 70)
        .background(background, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct SettingsLyricsModeMenu: View {
    @Binding var selection: BabyPlayerLyricsMode

    var body: some View {
        Menu {
            Button {
                selection = .english
            } label: {
                if selection != .off {
                    Label("自动选择（双语优先）", systemImage: "checkmark")
                } else {
                    Text("自动选择（双语优先）")
                }
            }
            Button {
                selection = .off
            } label: {
                if selection == .off {
                    Label("关闭", systemImage: "checkmark")
                } else {
                    Text("关闭")
                }
            }
        } label: {
            SettingsActionRow(
                title: "在线歌词",
                value: selection == .off ? "关闭" : "自动 · 双语优先"
            )
        }
    }
}

private struct SettingsIntegerMenu: View {
    let title: String
    let options: [Int]
    @Binding var selection: Int
    let valueText: (Int) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(valueText(option), systemImage: "checkmark")
                    } else {
                        Text(valueText(option))
                    }
                }
            }
        } label: {
            SettingsActionRow(title: title, value: valueText(selection))
        }
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
            Spacer()
            Text(value)
                .font(.system(size: 23, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
        }
        .padding(.horizontal, 28)
        .frame(height: 78)
        .contentShape(Rectangle())
    }
}

private struct SettingsActionRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
            Spacer()
            Text(value)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
            Image(systemName: "chevron.right")
                .foregroundStyle(BabyPlayerPalette.muted.opacity(0.65))
        }
        .padding(.horizontal, 28)
        .frame(height: 78)
        .contentShape(Rectangle())
    }
}

/// tvOS 没有 SwiftUI Stepper，因此使用两个可独立聚焦的加减按钮。
private struct SettingsAdjustmentRow: View {
    let title: String
    let value: String
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
            Spacer()
            Text(value)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
                .frame(minWidth: 220, alignment: .trailing)
            Button(action: decrement) {
                Image(systemName: "minus")
                    .frame(width: 42, height: 42)
            }
            Button(action: increment) {
                Image(systemName: "plus")
                    .frame(width: 42, height: 42)
            }
        }
        .buttonStyle(.bordered)
        .tint(BabyPlayerPalette.coral.opacity(0.72))
        .padding(.horizontal, 28)
        .frame(height: 82)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BabyPlayerPalette.ink.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct LoadingLibraryView: View {
    let repair: () -> Void

    var body: some View {
        ZStack {
            OrchardBackground()
            VStack(spacing: 24) {
                ProgressView()
                    .controlSize(.large)
                Text("正在准备宝宝的视频…")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(BabyPlayerPalette.ink)
                Button("取消并重新配对", action: repair)
                    .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.coral))
            }
        }
    }
}

private struct UnavailableLibraryView: View {
    let retry: () -> Void
    let repair: () -> Void

    var body: some View {
        ZStack {
            OrchardBackground()
            VStack(spacing: 26) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 66, weight: .semibold))
                    .foregroundStyle(BabyPlayerPalette.berry)
                Text("暂时看不到内容")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(BabyPlayerPalette.ink)
                Text("请检查 Mac 上的 Jellyfin，然后再试一次")
                    .font(.title2)
                    .foregroundStyle(BabyPlayerPalette.muted)
                HStack(spacing: 20) {
                    Button("重试", action: retry)
                    Button("重新配对", action: repair)
                }
                .buttonStyle(PrimaryPillButtonStyle(tint: BabyPlayerPalette.coral))
            }
        }
    }
}

// MARK: - Focus styles

private struct PrimaryPillButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        FocusAwareButtonLabel(configuration: configuration, tint: tint)
    }
}

private struct FocusAwareButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 25, weight: .bold, design: .rounded))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .padding(.horizontal, 34)
            .frame(minWidth: 220, minHeight: 64)
            .background(isFocused ? Color.white : tint, in: Capsule())
            .overlay {
                if isFocused {
                    Capsule().stroke(tint.opacity(0.32), lineWidth: 7)
                }
            }
            .scaleEffect(isFocused ? 1.05 : (configuration.isPressed ? 0.97 : 1))
            .shadow(color: isFocused ? tint.opacity(0.24) : .clear, radius: 20, y: 10)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

private struct MediaCardButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        MediaCardFocusLabel(configuration: configuration, tint: tint)
    }
}

private struct MediaCardFocusLabel: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(7)
            .background(isFocused ? Color.white.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 23))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 23)
                        .stroke(Color.white.opacity(0.96), lineWidth: 6)
                }
            }
            .scaleEffect(isFocused ? 1.055 : (configuration.isPressed ? 0.98 : 1))
            .offset(y: isFocused ? -5 : 0)
            .shadow(color: isFocused ? tint.opacity(0.22) : .clear, radius: 22, y: 14)
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct LowContrastButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LowContrastFocusLabel(configuration: configuration)
    }
}

private struct LowContrastFocusLabel: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : BabyPlayerPalette.muted)
            .background(isFocused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(BabyPlayerPalette.berry.opacity(0.28), lineWidth: 6)
                }
            }
            .scaleEffect(isFocused ? 1.05 : 1)
    }
}

private struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsRowFocusLabel(configuration: configuration)
    }
}

private struct SettingsRowFocusLabel: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(BabyPlayerPalette.ink)
            .background(isFocused ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 17))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(BabyPlayerPalette.ink.opacity(0.08))
                    .frame(height: 1)
            }
            .scaleEffect(isFocused ? 1.012 : 1)
    }
}
