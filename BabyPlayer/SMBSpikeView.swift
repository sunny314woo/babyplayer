//
// SMBSpikeView.swift
// BabyPlayer
//
// Phase A：仅在 feature flag 开启时显示的 SMB 真机诊断页和最小系统播放入口。
//

import AVFoundation
import AVKit
import SwiftUI

#if DEBUG
/// 仅供开发包真机自动化验收；密码只从当次进程环境读取，不写入日志或 Keychain。
@MainActor
enum SMBSpikeLaunchProbe {
    private static let enabledEnvironmentKey = "BABYPLAYER_SMB_SPIKE_AUTOPROBE"
    private static let passwordEnvironmentKey = "BABYPLAYER_SMB_SPIKE_PASSWORD"

    static func runIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment[enabledEnvironmentKey] == "1" else { return }
        var configuration = SMBSpikeConfigurationStore.load()
        if let injectedPassword = environment[passwordEnvironmentKey], !injectedPassword.isEmpty {
            configuration.password = injectedPassword
        }
        guard !configuration.password.isEmpty else {
            print("BABYPLAYER_SMB_SPIKE_RESULT failure stage=configuration reason=missing_password")
            return
        }

        print("BABYPLAYER_SMB_SPIKE_RESULT started")
        var stage = "configuration"

        do {
            stage = "client"
            let client = try SMBSpikeClient(configuration: configuration)
            stage = "connect"
            try await client.connect()
            stage = "scan"
            let items = try await client.listMedia()
            stage = "range_read"
            let rangeReport = try await client.verifyRandomReads(for: items[0])

            stage = "asset_load"
            let preparedAsset = SMBSpikePreparedAsset(client: client, item: items[0])
            let playable = try await preparedAsset.asset.load(.isPlayable)
            let duration = try await preparedAsset.asset.load(.duration)
            let durationSeconds = duration.seconds
            guard playable, durationSeconds.isFinite, durationSeconds > 0 else {
                throw SMBSpikeLaunchProbeError.assetNotPlayable
            }

            stage = "playback"
            let playerItem = AVPlayerItem(asset: preparedAsset.asset)
            let player = AVPlayer(playerItem: playerItem)
            player.play()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            player.pause()
            let playbackSeconds = player.currentTime().seconds
            guard playbackSeconds.isFinite, playbackSeconds >= 0.5 else {
                throw SMBSpikeLaunchProbeError.playbackDidNotAdvance
            }

            await client.disconnect()
            print(
                "BABYPLAYER_SMB_SPIKE_RESULT success " +
                "count=\(items.count) bytes=\(rangeReport.bytesRead) " +
                "playable=true playback_seconds=\(String(format: "%.2f", playbackSeconds))"
            )
        } catch {
            let cocoaError = error as NSError
            print(
                "BABYPLAYER_SMB_SPIKE_RESULT failure " +
                "stage=\(stage) domain=\(cocoaError.domain) code=\(cocoaError.code)"
            )
        }
    }
}

private enum SMBSpikeLaunchProbeError: Error {
    case assetNotPlayable
    case playbackDidNotAdvance
}
#endif

/// Samba 的正式首页状态。它保持 SMB 会话、生成标准 BabyPlayer 播放队列，
/// 设置页只负责切源，不再承载媒体列表或播放器。
@MainActor
final class SMBHomeViewModel: ObservableObject {
    @Published private(set) var mediaItems: [SMBSpikeMediaItem] = []
    @Published private(set) var statusText = "正在准备光猫 U 盘媒体库…"
    @Published private(set) var isWorking = false
    @Published var activePlayback: SpikePlaybackSelection?

    private var libraryClient: SMBSpikeClient?
    private var playbackClient: SMBSpikeClient?
    private var operationTask: Task<Void, Never>?
    private var coverPrewarmTask: Task<Void, Never>?
    private var playbackPreparationTask: Task<Void, Never>?

    init() {
        let configuration = SMBSpikeConfigurationStore.load()
        if let cachedItems = SMBSpikeLibraryIndexStore.load(configuration: configuration) {
            mediaItems = cachedItems
            statusText = "已显示 \(cachedItems.count) 个缓存视频，正在连接 Samba 刷新…"
        }
    }

    func connectIfNeeded() {
        guard libraryClient == nil || mediaItems.isEmpty else { return }
        connectAndScan()
    }

    func connectAndScan() {
        replaceOperation { [weak self] in
            guard let self else { return }
            do {
                let configuration = SMBSpikeConfigurationStore.load()
                self.statusText = "正在连接光猫 U 盘…"
                let libraryClient = try SMBSpikeClient(configuration: configuration)
                try await libraryClient.connect()
                self.statusText = "已连接，正在读取媒体目录…"
                let items = try await libraryClient.listMedia()
                try Task.checkCancellation()
                try SMBSpikeConfigurationStore.save(configuration)
                try SMBSpikeLibraryIndexStore.save(items, configuration: configuration)
                let playbackClient = try SMBSpikeClient(configuration: configuration)
                let previousLibraryClient = self.libraryClient
                let previousPlaybackClient = self.playbackClient
                self.libraryClient = libraryClient
                self.playbackClient = playbackClient
                self.mediaItems = items
                self.statusText = "光猫 U 盘 · Samba · \(items.count) 个视频"
                self.prewarmCovers(for: items, client: libraryClient)
                #if DEBUG
                print("BABYPLAYER_SMB_HOME_RESULT ready count=\(items.count)")
                #endif
                await previousLibraryClient?.disconnect()
                await previousPlaybackClient?.disconnect()
            } catch is CancellationError {
                return
            } catch {
                let failure = Self.readableMessage(for: error)
                self.statusText = self.mediaItems.isEmpty
                    ? failure
                    : "当前显示 \(self.mediaItems.count) 个缓存视频 · \(failure)"
            }
        }
    }

    func play(
        _ items: [SMBSpikeMediaItem],
        startIndex: Int,
        behavior: BabyPlayerPlaybackBehavior,
        playbackTimerMinutes: Int,
        introSkipSeconds: Int,
        outroSkipSeconds: Int,
        lyricsMode: BabyPlayerLyricsMode,
        smartSkipEnabled: Bool,
        preferenceID: (SMBSpikeMediaItem) -> String,
        localMediaMigrationKey: (SMBSpikeMediaItem) -> String?,
        startPositionSeconds: Double?
    ) {
        guard let playbackClient, !items.isEmpty else {
            statusText = "媒体库尚未连接，请重试。"
            return
        }
        coverPrewarmTask?.cancel()
        playbackPreparationTask?.cancel()
        let prepared = items.map { item in
            let titleMetadata = LyricsTitleMetadata.parse(item.displayName)
            let identity = "smb:\(item.path)"
            return (
                item: item,
                identity: identity,
                preferenceID: preferenceID(item),
                lyricsMedia: LyricsMediaDescriptor(
                    id: identity,
                    title: item.displayName,
                    searchTitle: titleMetadata.searchTitle,
                    artistName: nil,
                    sourceHint: titleMetadata.sourceHint,
                    versionHint: titleMetadata.versionHint,
                    durationSeconds: nil,
                    songStartSeconds: introSkipSeconds > 0 ? Double(introSkipSeconds) : nil,
                    songEndSeconds: nil,
                    mediaSourceID: identity,
                    localMediaMigrationKey: localMediaMigrationKey(item)
                )
            )
        }
        playbackPreparationTask = Task { [weak self] in
            let configurations = await BabyLyricsRepository.shared.smartPlaybackConfigurations(
                for: prepared.map(\.lyricsMedia)
            )
            guard let self, !Task.isCancelled else { return }
            let queue = prepared.map { prepared -> BabyPlayerQueueItem in
                let stored = configurations[prepared.identity]
                let boundary = BabyPlayerSmartSkipBoundaryPolicy.validatedStoredBoundary(
                    stored?.boundary,
                    expectedMediaDuration: nil
                )
                let placeholderURL = URL(
                    string: "babyplayer-smb://media/\(prepared.identity.hashValue.magnitude)"
                )!
                return BabyPlayerQueueItem(
                    id: prepared.identity,
                    preferenceID: prepared.preferenceID,
                    title: prepared.item.displayName,
                    url: placeholderURL,
                    smbPlaybackResource: SMBPlaybackResource(
                        client: playbackClient,
                        item: prepared.item
                    ),
                    lyricsMedia: prepared.lyricsMedia,
                    localMediaPath: nil,
                    chapterIntroEndSeconds: nil,
                    chapterOutroStartSeconds: nil,
                    smartIntroEndSeconds: boundary?.introEndSeconds,
                    smartOutroStartSeconds: boundary?.outroStartSeconds
                )
            }
            let boundedStartIndex = min(max(0, startIndex), queue.count - 1)
            let repeatMode: BabyPlayerRepeatMode
            switch behavior {
            case .repeatOne:
                repeatMode = .repeatOne
            case .repeatAll:
                repeatMode = .repeatAll
            case .sequential, .shuffle:
                repeatMode = .stopAtEnd
            }
            self.activePlayback = SpikePlaybackSelection(
                items: queue,
                startIndex: boundedStartIndex,
                repeatMode: repeatMode,
                repeatCount: behavior == .repeatOne ? 0 : 1,
                initialBehavior: behavior,
                sessionDuration: playbackTimerMinutes == 0
                    ? nil
                    : TimeInterval(playbackTimerMinutes * 60),
                introSkipSeconds: Double(introSkipSeconds),
                outroSkipSeconds: Double(outroSkipSeconds),
                lyricsMode: lyricsMode,
                smartSkipEnabled: smartSkipEnabled,
                startPositionSeconds: startPositionSeconds
            )
            self.playbackPreparationTask = nil
        }
    }

    func endPlayback() {
        playbackPreparationTask?.cancel()
        playbackPreparationTask = nil
        activePlayback = nil
        if let libraryClient {
            prewarmCovers(for: mediaItems, client: libraryClient)
        }
    }

    func coverSource(for item: SMBSpikeMediaItem) -> BabyPlayerCoverSource {
        return BabyPlayerCoverSource(
            providerImageURL: nil,
            videoURL: nil,
            smbPlaybackResource: libraryClient.map { SMBPlaybackResource(client: $0, item: item) },
            duration: nil,
            cacheKey: Self.coverCacheKey(for: item)
        )
    }

    private func replaceOperation(_ operation: @escaping @MainActor () async -> Void) {
        operationTask?.cancel()
        coverPrewarmTask?.cancel()
        isWorking = true
        operationTask = Task { [weak self] in
            await operation()
            guard !Task.isCancelled else { return }
            self?.isWorking = false
        }
    }

    private func prewarmCovers(for items: [SMBSpikeMediaItem], client: SMBSpikeClient) {
        coverPrewarmTask?.cancel()
        let sources = items.map { item in
            return BabyPlayerCoverSource(
                providerImageURL: nil,
                videoURL: nil,
                smbPlaybackResource: SMBPlaybackResource(client: client, item: item),
                duration: nil,
                cacheKey: Self.coverCacheKey(for: item)
            )
        }
        coverPrewarmTask = Task.detached(priority: .utility) {
            var readyCount = 0
            for source in sources {
                guard !Task.isCancelled else { return }
                if await BabyPlayerCoverGenerator.generate(for: source) != nil {
                    readyCount += 1
                    #if DEBUG
                    if readyCount == 1 {
                        print("BABYPLAYER_SMB_COVER_RESULT first_ready=true")
                    }
                    #endif
                }
            }
            #if DEBUG
            print("BABYPLAYER_SMB_COVER_RESULT ready=\(readyCount) total=\(sources.count)")
            #endif
        }
    }

    private static func coverCacheKey(for item: SMBSpikeMediaItem) -> String {
        let modifiedStamp = item.modifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return "smb:v1:\(item.path)|\(item.fileSize)|\(modifiedStamp)"
    }

    private static func readableMessage(for error: Error) -> String {
        let cocoa = error as NSError
        if cocoa.domain == NSPOSIXErrorDomain, cocoa.code == 60 {
            return "无法连接光猫 U 盘，请确认 Apple TV 连着家里的 Wi-Fi。"
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return "Samba 连接失败：\(description)"
        }
        return "Samba 连接失败：\(cocoa.domain) \(cocoa.code)"
    }
}

final class SMBSpikePlaybackSession: Identifiable {
    let id = UUID()
    let item: SMBSpikeMediaItem
    let player: AVPlayer
    private let preparedAsset: SMBSpikePreparedAsset

    init(client: SMBSpikeClient, item: SMBSpikeMediaItem) {
        self.item = item
        let preparedAsset = SMBSpikePreparedAsset(client: client, item: item)
        self.preparedAsset = preparedAsset
        let playerItem = AVPlayerItem(asset: preparedAsset.asset)
        player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    deinit {
        stop()
    }
}

@MainActor
final class SMBSpikeViewModel: ObservableObject {
    @Published var host: String
    @Published var share: String
    @Published var rootPath: String
    @Published var username: String
    @Published var password: String
    @Published private(set) var mediaItems: [SMBSpikeMediaItem] = []
    @Published private(set) var statusText = "连接光猫后，将直接打开 U 盘视频库。"
    @Published private(set) var isWorking = false
    @Published var activePlayback: SMBSpikePlaybackSession?

    private var client: SMBSpikeClient?
    private var operationTask: Task<Void, Never>?

    init() {
        let configuration = SMBSpikeConfigurationStore.load()
        host = configuration.host
        share = configuration.share
        rootPath = configuration.rootPath
        username = configuration.username
        password = configuration.password
    }

    func connectAndScan() {
        replaceOperation { [weak self] in
            guard let self else { return }
            do {
                let configuration = try self.currentConfiguration()
                self.statusText = "正在连接 SMB2：\(configuration.host):445…"
                let client = try SMBSpikeClient(configuration: configuration)
                try await client.connect()
                self.statusText = "连接成功，正在递归扫描 \(configuration.share)\(configuration.rootPath)…"
                let items = try await client.listMedia()
                try Task.checkCancellation()
                self.statusText = "找到 \(items.count) 个视频，正在验证首/中/尾随机读取…"
                let report = try await client.verifyRandomReads(for: items[0])
                try SMBSpikeConfigurationStore.save(configuration)
                self.client = client
                self.mediaItems = items
                self.statusText = String(
                    format: "U 盘媒体库已打开：%d 个视频 · 随机读取 %d KiB · %.2f 秒",
                    items.count,
                    report.bytesRead / 1_024,
                    report.elapsedSeconds
                )
            } catch is CancellationError {
                return
            } catch {
                self.statusText = self.readableMessage(for: error)
            }
        }
    }

    func verifyRandomReads(for item: SMBSpikeMediaItem) {
        guard let client else {
            statusText = "请先连接并扫描媒体目录。"
            return
        }
        replaceOperation { [weak self] in
            guard let self else { return }
            do {
                self.statusText = "正在读取所选视频的首/中/尾字节…"
                let report = try await client.verifyRandomReads(for: item)
                self.statusText = String(
                    format: "随机读取通过：%d KiB · %.2f 秒 · %@/%@/%@",
                    report.bytesRead / 1_024,
                    report.elapsedSeconds,
                    String(report.headDigest.prefix(8)),
                    String(report.middleDigest.prefix(8)),
                    String(report.tailDigest.prefix(8))
                )
            } catch is CancellationError {
                return
            } catch {
                self.statusText = self.readableMessage(for: error)
            }
        }
    }

    func play(_ item: SMBSpikeMediaItem) {
        guard let client else {
            statusText = "请先连接并扫描媒体目录。"
            return
        }
        replaceOperation { [weak self] in
            guard let self else { return }
            do {
                self.statusText = "正在校验文件并通过 SMB byte-range 打开视频…"
                let latestStat = try await client.stat(path: item.path)
                let scannedStat = SMBSpikeFileStat(
                    path: item.path,
                    fileSize: item.fileSize,
                    modifiedAt: item.modifiedAt
                )
                guard SMBSpikeClient.isSameFile(latestStat, as: scannedStat) else {
                    throw SMBSpikeError.fileChanged
                }
                try Task.checkCancellation()
                self.activePlayback = SMBSpikePlaybackSession(client: client, item: item)
                self.statusText = "正在通过 SMB byte-range 播放…"
            } catch is CancellationError {
                return
            } catch {
                self.statusText = self.readableMessage(for: error)
            }
        }
    }

    func stopPlayback() {
        activePlayback?.stop()
        activePlayback = nil
        statusText = "已退出 SMB 播放，可继续选择其它视频。"
    }

    func disconnect() {
        operationTask?.cancel()
        stopPlayback()
        mediaItems = []
        let oldClient = client
        client = nil
        Task { await oldClient?.disconnect() }
        statusText = "SMB 会话已断开。"
    }

    private func currentConfiguration() throws -> SMBSpikeConfiguration {
        let configuration = SMBSpikeConfiguration(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: 445,
            share: share.trimmingCharacters(in: .whitespacesAndNewlines),
            rootPath: try SMBSpikePath.normalize(rootPath),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
        _ = try SMBSpikeClient(configuration: configuration)
        return configuration
    }

    private func replaceOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        operationTask?.cancel()
        isWorking = true
        operationTask = Task { [weak self] in
            await operation()
            guard !Task.isCancelled else { return }
            self?.isWorking = false
        }
    }

    private func readableMessage(for error: Error) -> String {
        let cocoa = error as NSError
        if cocoa.domain == NSPOSIXErrorDomain, cocoa.code == 60 {
            return "SMB 连接超时：Apple TV 当前网络无法到达路由器 U 盘。请让 Apple TV 和 SMB 服务器位于可互通的网段。"
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return "SMB 测试失败：\(description)"
        }
        return "SMB 测试失败：\(cocoa.domain) \(cocoa.code)"
    }
}

struct SMBSpikeView: View {
    let close: () -> Void
    @StateObject private var model = SMBSpikeViewModel()

    var body: some View {
        ZStack {
            OrchardBackground()
            VStack(alignment: .leading, spacing: 18) {
                header
                connectionFields
                actionBar
                status
                mediaList
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 18)
        }
        .foregroundStyle(BabyPlayerPalette.ink)
        .fullScreenCover(item: $model.activePlayback) { session in
            SMBSpikePlayerView(session: session, close: model.stopPlayback)
        }
        .onExitCommand {
            model.disconnect()
            close()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("路由器 U 盘")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                Text("Apple TV → 华为光猫 → USB 共享；不经过 Mac/Jellyfin")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(BabyPlayerPalette.muted)
            }
            Spacer()
            Button("返回") {
                model.disconnect()
                close()
            }
            .buttonStyle(.borderedProminent)
            .tint(BabyPlayerPalette.berry)
        }
    }

    private var connectionFields: some View {
        HStack(spacing: 14) {
            spikeField("服务器", text: $model.host, width: 260)
            spikeField("共享", text: $model.share, width: 220)
            spikeField("目录", text: $model.rootPath, width: 260)
            spikeField("用户名", text: $model.username, width: 200)
            SecureField("Samba 密码", text: $model.password)
                .textFieldStyle(.plain)
                .foregroundStyle(Color.black)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func spikeField(_ title: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .foregroundStyle(Color.black)
            .padding(.horizontal, 18)
            .frame(width: width, height: 62)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            Button("连接并打开媒体库", action: model.connectAndScan)
                .buttonStyle(.borderedProminent)
                .tint(BabyPlayerPalette.coral)
                .disabled(model.isWorking)
            Button("断开", action: model.disconnect)
                .buttonStyle(.bordered)
                .disabled(model.isWorking && model.mediaItems.isEmpty)
            if model.isWorking { ProgressView() }
            Spacer()
            Text("只读 · SMB2/3 · TCP 445")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(BabyPlayerPalette.muted)
        }
    }

    private var status: some View {
        Text(model.statusText)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(BabyPlayerPalette.ink)
            .lineLimit(2)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var mediaList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(model.mediaItems.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(BabyPlayerPalette.muted)
                            .frame(width: 48, alignment: .trailing)
                        Text(item.name)
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                            .foregroundStyle(BabyPlayerPalette.muted)
                        Button("随机读取") { model.verifyRandomReads(for: item) }
                        Button("播放") { model.play(item) }
                            .buttonStyle(.borderedProminent)
                            .tint(BabyPlayerPalette.leaf)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 66)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

private struct SMBSpikePlayerView: View {
    let session: SMBSpikePlaybackSession
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: session.player)
                .ignoresSafeArea()
            Button("退出 SMB 测试", action: close)
                .buttonStyle(.borderedProminent)
                .tint(BabyPlayerPalette.berry)
                .padding(36)
        }
        .onAppear { session.player.play() }
        .onDisappear { session.stop() }
        .onExitCommand(perform: close)
    }
}
