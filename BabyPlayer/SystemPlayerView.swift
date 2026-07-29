//
// SystemPlayerView.swift
// 用途：把 tvOS 系统 AVPlayerViewController 接入 SwiftUI。
// 主要功能：播放 Jellyfin URL，并把遥控器 Menu/Back 转换为返回 Spike 首页。
// 最近修改：2026-07-29 创建系统播放器与 Back 行为验证桥接。
//

import AVKit
import SwiftUI

/// SwiftUI 到系统播放器的桥接；输入为播放 URL、标题与退出回调。
struct SystemPlayerView: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let onExit: () -> Void

    /// 创建系统播放器；副作用为建立 AVPlayer 并立即开始播放。
    func makeUIViewController(context: Context) -> SpikePlayerViewController {
        let controller = SpikePlayerViewController()
        let playerItem = AVPlayerItem(url: url)
        playerItem.externalMetadata = [titleMetadataItem()]

        controller.player = AVPlayer(playerItem: playerItem)
        controller.showsPlaybackControls = true
        controller.onExit = onExit
        controller.player?.play()
        return controller
    }

    /// SwiftUI 更新时保持退出回调最新；不会重建或跳转播放进度。
    func updateUIViewController(_ controller: SpikePlayerViewController, context: Context) {
        controller.onExit = onExit
    }

    /// 视图销毁时停止网络与解码工作；副作用为暂停并释放播放器引用。
    static func dismantleUIViewController(_ controller: SpikePlayerViewController, coordinator: Void) {
        controller.player?.pause()
        controller.player = nil
    }

    /// 生成系统播放器可显示的视频标题元数据；不读取共享状态。
    private func titleMetadataItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        item.extendedLanguageTag = "zh-Hans"
        return item.copy() as? AVMetadataItem ?? item
    }
}

/// 系统播放器的最小子类，仅补充产品要求的遥控器 Back 退出语义。
final class SpikePlayerViewController: AVPlayerViewController {
    var onExit: (() -> Void)?

    /// 【MODIFIED】Menu/Back 立即退出播放；其他遥控器按键全部交回系统播放器处理。
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onExit?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
