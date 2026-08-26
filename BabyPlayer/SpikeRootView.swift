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
    @State private var showSettings = false

    var body: some View {
        Group {
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
        .fullScreenCover(isPresented: $showSettings) {
            ParentSettingsView(model: model) {
                showSettings = false
            }
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
                onFinished: model.clearPlaybackResume
            )
                .ignoresSafeArea()
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
    let close: () -> Void
    // 【MODIFIED】额度读取与临时分段生命周期解耦，不展示已取消的完整音频库。
    @StateObject private var asrUsage = BabyPlayerASRUsageViewModel()
    @State private var confirmClear = false

    var body: some View {
        ZStack {
            OrchardBackground()
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
                        SettingsInfoRow(title: "Jellyfin 连接", value: model.connectionSummary)
                        Button {
                            model.rescanLibrary()
                        } label: {
                            SettingsActionRow(title: "扫描并刷新媒体库", value: "\(model.mediaItems.count) 个视频")
                        }
                        Button {
                            close()
                            model.startRePairing()
                        } label: {
                            SettingsActionRow(title: "重新配对", value: "Quick Connect")
                        }
                        SettingsLyricsModeMenu(selection: $model.lyricsMode)
                        SettingsInfoRow(title: "本月声音分析", value: asrUsage.usageText)
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
        .onExitCommand(perform: close)
        .task { asrUsage.refresh() }
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

    /// 家长可查看并解除屏蔽；儿童首页不会渲染这组记录。
    @ViewBuilder
    private var blockedRatingsSection: some View {
        if model.blockedMediaItems.isEmpty {
            SettingsInfoRow(title: "屏蔽的视频", value: "暂无")
        } else {
            SettingsInfoRow(title: "屏蔽的视频", value: "\(model.blockedMediaItems.count) 个")
            ForEach(model.blockedMediaItems) { item in
                Button {
                    model.unblock(item)
                } label: {
                    SettingsActionRow(title: item.name, value: "解除屏蔽")
                }
            }
        }
    }
}

private struct SettingsLyricsModeMenu: View {
    @Binding var selection: BabyPlayerLyricsMode

    var body: some View {
        Menu {
            ForEach(BabyPlayerLyricsMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    if mode == selection {
                        Label(mode.rawValue, systemImage: "checkmark")
                    } else if mode.isCurrentlyAvailable {
                        Text(mode.rawValue)
                    } else {
                        Text("\(mode.rawValue)（需翻译服务）")
                    }
                }
                .disabled(!mode.isCurrentlyAvailable)
            }
        } label: {
            SettingsActionRow(
                title: "在线歌词",
                value: selection == .english ? "英文 · LRCLIB" : selection.rawValue
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
