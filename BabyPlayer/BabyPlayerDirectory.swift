//
// BabyPlayerDirectory.swift
// 用途：为各媒体源提供相同的目录展示与导航数据。
// 主要功能：保存来源内的根目录、逐级路径和共用文件夹入口。
// 最近修改：【MODIFIED】Phase 2 新增独立目录导航，不改变现有播放链路。
//

import Foundation
import SwiftUI

/// 【MODIFIED】职责：表示一个来源内的文件夹；输入为来源原生 ID 和名称，输出用于导航与展示。
struct BabyPlayerFolderNode: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// 【MODIFIED】职责：承载当前目录的直接子项；输入由各来源客户端提供，输出给共用目录 UI。
struct BabyPlayerDirectoryListing<Video> {
    let folders: [BabyPlayerFolderNode]
    let videos: [Video]
}

/// 【MODIFIED】职责：逐级导航并把上次目录按来源及根目录隔离；输入是已列出的子文件夹，副作用是保存路径。
struct BabyPlayerDirectoryNavigation {
    let sourceKey: String
    let rootID: String
    private(set) var stack: [BabyPlayerFolderNode] = []

    var currentID: String { stack.last?.id ?? rootID }
    var currentName: String { stack.last?.name ?? "音乐视频" }
    var canGoBack: Bool { !stack.isEmpty }

    /// 【MODIFIED】职责：读取当前来源的历史路径；输入为根目录 ID，输出为待逐级验证的路径。
    init(sourceKey: String, rootID: String, defaults: UserDefaults = .standard) {
        self.sourceKey = sourceKey
        self.rootID = rootID
        let key = Self.storageKey(sourceKey: sourceKey, rootID: rootID)
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([BabyPlayerFolderNode].self, from: data) {
            stack = saved
        }
    }

    /// 【MODIFIED】职责：仅允许进入当前目录真实返回的子目录；输入为候选文件夹和目录列表，输出为是否进入。
    @discardableResult
    mutating func open(
        _ folder: BabyPlayerFolderNode,
        visibleFolders: [BabyPlayerFolderNode],
        defaults: UserDefaults = .standard
    ) -> Bool {
        // 【MODIFIED】以服务器当次返回的 ID 验证边界；目录改名后仍能恢复，并更新展示名称。
        guard let currentFolder = visibleFolders.first(where: { $0.id == folder.id }) else { return false }
        stack.append(currentFolder)
        persist(defaults: defaults)
        return true
    }

    /// 【MODIFIED】职责：按层级返回且不越过 Root Folder；输出为是否发生返回，副作用是保存路径。
    @discardableResult
    mutating func goBack(defaults: UserDefaults = .standard) -> Bool {
        guard !stack.isEmpty else { return false }
        stack.removeLast()
        persist(defaults: defaults)
        return true
    }

    /// 【MODIFIED】职责：发现历史路径已失效时退回根目录；副作用是清除该来源的历史路径。
    mutating func returnToRoot(defaults: UserDefaults = .standard) {
        stack.removeAll()
        persist(defaults: defaults)
    }

    /// 【MODIFIED】职责：提供恢复路径中的逐级节点；输出只供来源客户端验证，不直接信任持久化 ID。
    var savedPath: [BabyPlayerFolderNode] { stack }

    /// 【MODIFIED】职责：持久化当前来源的导航路径；副作用仅写入 UserDefaults。
    private func persist(defaults: UserDefaults) {
        let key = Self.storageKey(sourceKey: sourceKey, rootID: rootID)
        defaults.set(try? JSONEncoder().encode(stack), forKey: key)
    }

    /// 【MODIFIED】职责：将来源与根目录绑定为独立存储键；输出不包含访问凭证。
    private static func storageKey(sourceKey: String, rootID: String) -> String {
        "BabyPlayer.LastDirectory.v1.\(sourceKey).\(Data(rootID.utf8).base64EncodedString())"
    }
}

/// 【MODIFIED】职责：三个来源复用同一套文件夹入口与返回按钮；输入为当前层文件夹和动作，输出为导航事件。
struct BabyPlayerFolderSection: View {
    let name: String
    let folders: [BabyPlayerFolderNode]
    let canGoBack: Bool
    let goBack: () -> Void
    let open: (BabyPlayerFolderNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if canGoBack {
                    Button("返回上层", action: goBack)
                        .buttonStyle(.bordered)
                }
                Text(name)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Spacer()
            }
            if !folders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(folders) { folder in
                            Button { open(folder) } label: {
                                Label(folder.name, systemImage: "folder.fill")
                                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                    .frame(minWidth: 230, minHeight: 62)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }
}
