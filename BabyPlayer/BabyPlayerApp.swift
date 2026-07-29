//
// BabyPlayerApp.swift
// 用途：定义 BabyPlayer tvOS 应用入口。
// 主要功能：启动当前最小技术 Spike 根视图。
// 最近修改：2026-07-29 创建可构建的 tvOS SwiftUI Spike。
//

import SwiftUI

/// 应用唯一入口；创建根场景，不读取或修改共享数据。
@main
struct BabyPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            // 【MODIFIED】技术 Spike 暂时直接进入链路验证页；完整 V1 UI 在 Spike 通过后实现。
            SpikeRootView()
        }
    }
}
