//
// SpikeViewModel.swift
// 用途：管理 tvOS 技术 Spike 的可观察状态。
// 主要功能：串联服务器探测、Quick Connect 轮询、首条视频读取和播放器展示。
// 最近修改：2026-07-29 创建端到端 Spike 状态机。
//

import Foundation

/// 可以交给系统播放器的内存态选择；URL 可能包含短期访问令牌，因此不持久化。
struct SpikePlaybackSelection: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
}

/// Spike 页面状态；所有发布属性只在主线程更新。
@MainActor
final class SpikeViewModel: ObservableObject {
    @Published var serverAddress = "http://192.168.3.33:8096"
    @Published private(set) var statusText = "先验证 Jellyfin 服务器，再生成配对码。"
    @Published private(set) var quickConnectCode: String?
    @Published private(set) var loadedVideoTitle: String?
    @Published private(set) var isWorking = false
    @Published var activePlayback: SpikePlaybackSelection?

    private var loadedPlayback: SpikePlaybackSelection?
    private var operationTask: Task<Void, Never>?

    /// 取消旧任务并检查公共服务器信息；副作用为更新页面状态。
    func checkServer() {
        replaceOperation { [weak self] in
            guard let self else { return }
            do {
                let client = try self.makeClient()
                let info = try await client.fetchPublicInfo()
                guard info.startupWizardCompleted else {
                    self.statusText = "Jellyfin 初始化尚未完成，请先完成 Mac 上的向导。"
                    return
                }
                let quickConnectEnabled = try await client.isQuickConnectEnabled()
                guard quickConnectEnabled else {
                    throw JellyfinSpikeError.quickConnectDisabled
                }
                self.statusText = "已连接 \(info.serverName) · Jellyfin \(info.version)，Quick Connect 可用。"
            } catch {
                self.statusText = self.readableMessage(for: error)
            }
        }
    }

    /// 【MODIFIED】发起配对并每两秒轮询；批准后自动获取第一条视频。
    func beginQuickConnect() {
        replaceOperation { [weak self] in
            guard let self else { return }
            do {
                let client = try self.makeClient()
                guard try await client.isQuickConnectEnabled() else {
                    throw JellyfinSpikeError.quickConnectDisabled
                }

                let request = try await client.initiateQuickConnect()
                self.quickConnectCode = request.code
                self.statusText = "请在 Mac 的 Jellyfin 中批准数字码 \(request.code)。"

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

                    let video = try await client.fetchFirstVideo(userID: userID, accessToken: accessToken)
                    let playbackURL = try client.directPlaybackURL(for: video, accessToken: accessToken)
                    let selection = SpikePlaybackSelection(title: video.name, url: playbackURL)
                    self.loadedPlayback = selection
                    self.loadedVideoTitle = video.name
                    self.quickConnectCode = nil
                    self.statusText = "配对成功，已取得测试视频：\(video.name)"
                    return
                }

                self.statusText = "配对等待超时，请重新生成数字码。"
            } catch is CancellationError {
                return
            } catch {
                self.statusText = self.readableMessage(for: error)
            }
        }
    }

    /// 展示已加载视频；输出为 `activePlayback`，触发 SwiftUI 全屏播放器。
    func playLoadedVideo() {
        guard let loadedPlayback else {
            statusText = "请先完成 Quick Connect 并取得测试视频。"
            return
        }
        activePlayback = loadedPlayback
    }

    /// 退出系统播放器；副作用为清除当前全屏展示并保留已加载视频。
    func endPlayback() {
        activePlayback = nil
        statusText = "已通过 Back 返回 Spike 首页；测试视频仍可再次播放。"
    }

    /// 记录首页 Back 已被拦截；用于验证不会误退出 App。
    func handleRootBack() {
        statusText = "Spike 首页已拦截 Back，没有退出 App。"
    }

    /// 替换当前异步操作；统一维护忙碌状态，避免多个配对轮询同时运行。
    private func replaceOperation(_ operation: @escaping @MainActor () async -> Void) {
        operationTask?.cancel()
        isWorking = true
        operationTask = Task { [weak self] in
            await operation()
            guard !Task.isCancelled else { return }
            self?.isWorking = false
        }
    }

    /// 创建绑定当前输入地址的 API 客户端；设备 ID 在本机安装生命周期内稳定。
    private func makeClient() throws -> JellyfinSpikeClient {
        try JellyfinSpikeClient(serverAddress: serverAddress, deviceID: Self.deviceID())
    }

    /// 获取或创建非敏感设备标识；副作用为首次运行时写入 UserDefaults。
    private static func deviceID() -> String {
        let defaultsKey = "BabyPlayer.Spike.DeviceID"
        if let existingID = UserDefaults.standard.string(forKey: defaultsKey) {
            return existingID
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: defaultsKey)
        return newID
    }

    /// 把内部错误转换为家长可读文本；不返回令牌、服务器响应正文或文件路径。
    private func readableMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "暂时无法连接 Jellyfin，请检查服务器后重试。"
    }
}
