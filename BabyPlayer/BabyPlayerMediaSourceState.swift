//
// BabyPlayerMediaSourceState.swift
// 用途：定义三来源共有的配置、在线和优先级规则。
// 主要功能：保存家长优先级，选择启动时最高优先级的在线媒体源。
// 最近修改：【MODIFIED】Phase 3 新增与 tvOS 视图无关的来源状态逻辑。
//

import Foundation

/// 【MODIFIED】职责：区分未配置、已配置但不可用和在线；输出可供 tvOS 与后端协议复用的稳定值。
enum BabyPlayerMediaSourceAvailability: String, Codable, Equatable {
    case unconfigured
    case offline
    case online
}

/// 【MODIFIED】职责：标识自动选择发生的时机；播放中断线不能触发跨来源切换。
enum BabyPlayerMediaSourceSelectionEvent {
    case appLaunch
    case initialLibraryLoadFailure
    case playbackDisconnect
}

/// 【MODIFIED】职责：把已保存的配置与本次网络检测合并；输入配置/在线布尔值，输出明确状态。
enum BabyPlayerMediaSourceStatusPolicy {
    /// 【MODIFIED】职责：配置未完成时不发出在线状态；输入配置及探测结果，输出三态之一。
    static func resolve(isConfigured: Bool, isReachable: Bool) -> BabyPlayerMediaSourceAvailability {
        guard isConfigured else { return .unconfigured }
        return isReachable ? .online : .offline
    }
}

/// 【MODIFIED】职责：按家长优先级决定启动和初次加载失败后的来源；播放中不调用此规则。
enum BabyPlayerMediaSourceSelectionPolicy {
    static let defaultPriority: [BabyPlayerMediaSourceKind] = [.samba, .baidu, .jellyfin]

    /// 【MODIFIED】职责：限制自动切源时机；输入事件和播放状态，输出是否允许自动切换。
    static func mayAutoSwitch(
        for event: BabyPlayerMediaSourceSelectionEvent,
        isPlaybackActive: Bool
    ) -> Bool {
        guard !isPlaybackActive else { return false }
        switch event {
        case .appLaunch, .initialLibraryLoadFailure: return true
        case .playbackDisconnect: return false
        }
    }

    /// 【MODIFIED】职责：读取并补齐历史或损坏的优先级列表；输入原始值，输出每个来源恰好一次。
    static func normalizedPriority(_ stored: [String]?) -> [BabyPlayerMediaSourceKind] {
        var order: [BabyPlayerMediaSourceKind] = []
        for raw in stored ?? [] {
            guard let source = BabyPlayerMediaSourceKind(rawValue: raw), !order.contains(source) else { continue }
            order.append(source)
        }
        for source in defaultPriority where !order.contains(source) {
            order.append(source)
        }
        return order
    }

    /// 【MODIFIED】职责：只返回按优先级排在前面的在线来源；输入状态表及排除集合，输出下一来源。
    static func highestOnline(
        priority: [BabyPlayerMediaSourceKind],
        states: [BabyPlayerMediaSourceKind: BabyPlayerMediaSourceAvailability],
        excluding: Set<BabyPlayerMediaSourceKind> = []
    ) -> BabyPlayerMediaSourceKind? {
        normalizedPriority(priority.map(\.rawValue)).first {
            !excluding.contains($0) && states[$0] == .online
        }
    }
}

/// 【MODIFIED】职责：仅持久化来源优先级；旧 ActiveMediaSource 键留在设备中供历史兼容，不作为默认来源。
enum BabyPlayerMediaSourcePriorityStore {
    private static let priorityKey = "BabyPlayer.MediaSourcePriority.v1"

    /// 【MODIFIED】职责：从用户偏好读取完整优先级；输入 UserDefaults，输出三来源有序列表。
    static func load(defaults: UserDefaults = .standard) -> [BabyPlayerMediaSourceKind] {
        BabyPlayerMediaSourceSelectionPolicy.normalizedPriority(
            defaults.stringArray(forKey: priorityKey)
        )
    }

    /// 【MODIFIED】职责：保存家长排序并自动补齐来源；副作用仅写入用户偏好。
    static func save(_ priority: [BabyPlayerMediaSourceKind], defaults: UserDefaults = .standard) {
        let normalized = BabyPlayerMediaSourceSelectionPolicy.normalizedPriority(priority.map(\.rawValue))
        defaults.set(normalized.map(\.rawValue), forKey: priorityKey)
    }
}
