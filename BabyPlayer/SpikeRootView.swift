//
// SpikeRootView.swift
// 用途：提供技术 Spike 的最小 tvOS 验证界面。
// 主要功能：输入服务器、展示 Quick Connect 数字码、启动系统播放器并显示测试结果。
// 最近修改：2026-07-29 创建非正式 UI 的端到端验证页。
//

import SwiftUI

/// Spike 根视图；仅验证技术链路，不代表冻结的最终首页 UI。
struct SpikeRootView: View {
    @StateObject private var model = SpikeViewModel()
    @FocusState private var focusedControl: FocusControl?

    /// Spike 默认焦点目标；仅用于验证 tvOS 遥控器顺序。
    private enum FocusControl: Hashable {
        case serverAddress
        case checkServer
        case quickConnect
        case playVideo
    }

    var body: some View {
        ZStack {
            Color(red: 0.98, green: 0.93, blue: 0.87)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                header
                serverField
                actionButtons
                resultPanel
            }
            .frame(maxWidth: 1180, alignment: .leading)
            .padding(.horizontal, 92)
            .padding(.vertical, 66)
        }
        .defaultFocus($focusedControl, .checkServer)
        // 【MODIFIED】首页 Back 被显式拦截；播放器 Back 由系统播放器桥接层返回此页。
        .onExitCommand(perform: model.handleRootBack)
        .fullScreenCover(item: $model.activePlayback) { selection in
            SystemPlayerView(
                url: selection.url,
                title: selection.title,
                onExit: model.endPlayback
            )
            .ignoresSafeArea()
        }
    }

    /// 页面说明；输出为只读标题区域，无副作用。
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BabyPlayer · 技术 Spike")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.32, green: 0.23, blue: 0.20))
            Text("只验证 Jellyfin → Quick Connect → 一条视频 → AVPlayerViewController → Back")
                .font(.title3)
                .foregroundStyle(Color(red: 0.48, green: 0.36, blue: 0.31))
        }
    }

    /// 服务器地址输入；使用系统 tvOS 键盘，编辑时更新 ViewModel 地址。
    private var serverField: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jellyfin 服务器")
                .font(.headline)
                .foregroundStyle(Color(red: 0.37, green: 0.27, blue: 0.23))
            TextField("例如 http://192.168.3.33:8096", text: $model.serverAddress)
                .textFieldStyle(.plain)
                .font(.title3.monospaced())
                .focused($focusedControl, equals: .serverAddress)
                .padding(.horizontal, 24)
                .frame(height: 68)
                .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    /// 三个顺序验证按钮；副作用分别为网络检查、配对轮询和播放器展示。
    private var actionButtons: some View {
        HStack(spacing: 22) {
            Button("1  测试服务器", action: model.checkServer)
                .focused($focusedControl, equals: .checkServer)
            Button("2  生成配对码", action: model.beginQuickConnect)
                .focused($focusedControl, equals: .quickConnect)
            Button("3  播放测试视频", action: model.playLoadedVideo)
                .disabled(model.loadedVideoTitle == nil)
                .focused($focusedControl, equals: .playVideo)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 0.91, green: 0.42, blue: 0.31))
        .disabled(model.isWorking && model.quickConnectCode == nil)
    }

    /// 当前步骤和结果面板；只显示安全的状态文本与配对数字码。
    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                if model.isWorking {
                    ProgressView()
                }
                Text(model.statusText)
                    .font(.title3)
            }

            if let code = model.quickConnectCode {
                Text(code)
                    .font(.system(size: 76, weight: .heavy, design: .rounded).monospacedDigit())
                    .tracking(12)
                    .foregroundStyle(Color(red: 0.45, green: 0.25, blue: 0.58))
                    .accessibilityLabel("Quick Connect 配对码 \(code)")
            }

            if let videoTitle = model.loadedVideoTitle {
                Label("已取得：\(videoTitle)", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.30, green: 0.55, blue: 0.28))
            }
        }
        .foregroundStyle(Color(red: 0.32, green: 0.23, blue: 0.20))
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 26))
    }
}
