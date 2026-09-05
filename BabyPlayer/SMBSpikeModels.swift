//
// SMBSpikeModels.swift
// BabyPlayer
//
// Phase A：SMB 真机播放 Spike 的配置、路径规则和只读媒体模型。
// 这些类型与现有 Jellyfin 主链隔离，Spike 通过后再提升为正式媒体源模型。
//

import CryptoKit
import Foundation

enum BabyPlayerFeatureFlags {
    static let smbDirectPlaybackKey = "BabyPlayer.Features.SMBDirectPlayback.v1"

    static var isSMBDirectPlaybackSpikeEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: smbDirectPlaybackKey) as? Bool {
            return stored
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

/// 家长最后一次选定的媒体轨道。选择立即持久化，下次启动不再默认跳回 Jellyfin。
enum BabyPlayerMediaSourceKind: String, Equatable {
    case jellyfin
    case samba
}

enum BabyPlayerMediaSourcePreference {
    private static let activeSourceKey = "BabyPlayer.ActiveMediaSource.v1"

    static func load() -> BabyPlayerMediaSourceKind {
        let storedRawValue = UserDefaults.standard.string(forKey: activeSourceKey)
        let source = resolvedSource(
            storedRawValue: storedRawValue,
            hasSavedSMBConfiguration: SMBSpikeConfigurationStore.hasSavedConfiguration
        )
        if storedRawValue == nil, source == .samba {
            save(.samba)
        }
        return source
    }

    static func save(_ source: BabyPlayerMediaSourceKind) {
        UserDefaults.standard.set(source.rawValue, forKey: activeSourceKey)
    }

    static func resolvedSource(
        storedRawValue: String?,
        hasSavedSMBConfiguration: Bool
    ) -> BabyPlayerMediaSourceKind {
        if let storedRawValue,
           let source = BabyPlayerMediaSourceKind(rawValue: storedRawValue) {
            return source
        }
        // 旧版 Spike 已成功保存 Samba 配置时，将它迁移为当前源。
        return hasSavedSMBConfiguration ? .samba : .jellyfin
    }
}

struct SMBSpikeConfiguration: Equatable, Sendable {
    var host: String
    var port: Int
    var share: String
    var rootPath: String
    var username: String
    var password: String

    static let homeGatewayDefaults = SMBSpikeConfiguration(
        host: "192.168.1.1",
        port: 445,
        share: "usb-0781-060116_1",
        rootPath: "/sss73",
        username: "admin",
        password: ""
    )
}

struct SMBSpikeMediaItem: Codable, Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let fileSize: Int64
    let modifiedAt: Date?

    var id: String { path }

    var displayName: String {
        let title = (name as NSString).deletingPathExtension
        return title.isEmpty ? name : title
    }
}

struct SMBSpikeFileStat: Equatable, Sendable {
    let path: String
    let fileSize: Int64
    let modifiedAt: Date?
}

private struct SMBSpikeLibrarySnapshot: Codable {
    let schemaVersion: Int
    let sourceIdentity: String
    let savedAt: Date
    let items: [SMBSpikeMediaItem]
}

/// 可重建的 SMB 首页索引。密码从不进入缓存，来源不一致或内容损坏时直接忽略并重扫。
enum SMBSpikeLibraryIndexStore {
    private static let schemaVersion = 1

    static func load(
        configuration: SMBSpikeConfiguration,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [SMBSpikeMediaItem]? {
        let url = indexURL(cacheDirectory: cacheDirectory, fileManager: fileManager)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(SMBSpikeLibrarySnapshot.self, from: data),
              snapshot.schemaVersion == schemaVersion,
              snapshot.sourceIdentity == sourceIdentity(for: configuration),
              !snapshot.items.isEmpty,
              snapshot.items.allSatisfy(isValidCachedItem) else { return nil }
        return snapshot.items
    }

    static func save(
        _ items: [SMBSpikeMediaItem],
        configuration: SMBSpikeConfiguration,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard !items.isEmpty, items.allSatisfy(isValidCachedItem) else {
            throw SMBSpikeError.noSupportedMedia
        }
        let snapshot = SMBSpikeLibrarySnapshot(
            schemaVersion: schemaVersion,
            sourceIdentity: sourceIdentity(for: configuration),
            savedAt: Date(),
            items: items
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        // 写入前回读编码结果，避免把不可解码的索引提交到首页缓存。
        _ = try JSONDecoder().decode(SMBSpikeLibrarySnapshot.self, from: data)
        let url = indexURL(cacheDirectory: cacheDirectory, fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func indexURL(
        cacheDirectory: URL?,
        fileManager: FileManager
    ) -> URL {
        let base = cacheDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("BabyPlayer", isDirectory: true)
            .appendingPathComponent("SMBMediaIndex-v1.json")
    }

    private static func sourceIdentity(for configuration: SMBSpikeConfiguration) -> String {
        let normalizedRoot = (try? SMBSpikePath.normalize(configuration.rootPath))
            ?? configuration.rootPath
        let raw = [
            "BabyPlayer.SMBSource.v1",
            configuration.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            String(configuration.port),
            configuration.share.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedRoot,
            configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\0")
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isValidCachedItem(_ item: SMBSpikeMediaItem) -> Bool {
        guard item.fileSize > 0,
              SMBSpikePath.isSupportedVideo(name: item.name),
              !SMBSpikePath.shouldIgnore(name: item.name, isDirectory: false),
              let normalized = try? SMBSpikePath.normalize(item.path),
              normalized == item.path else { return false }
        return true
    }
}

struct SMBSpikeByteRangePlan: Equatable, Sendable {
    let startOffset: UInt64
    let endOffset: UInt64

    static func make(
        fileSize: Int64,
        requestedOffset: Int64,
        currentOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEnd: Bool
    ) throws -> SMBSpikeByteRangePlan {
        guard fileSize >= 0,
              requestedOffset >= 0,
              currentOffset >= 0,
              requestedLength >= 0 else {
            throw SMBSpikeError.invalidReadRange
        }

        let fileEnd = UInt64(fileSize)
        let requestStart = UInt64(requestedOffset)
        let logicalStart = max(requestStart, UInt64(currentOffset))
        let logicalEnd: UInt64
        if requestsAllDataToEnd {
            logicalEnd = fileEnd
        } else {
            let length = UInt64(requestedLength)
            guard requestStart <= UInt64.max - length else {
                throw SMBSpikeError.invalidReadRange
            }
            logicalEnd = requestStart + length
            guard logicalStart <= logicalEnd else {
                throw SMBSpikeError.invalidReadRange
            }
        }

        let start = min(fileEnd, logicalStart)
        let end = min(fileEnd, logicalEnd)
        return SMBSpikeByteRangePlan(startOffset: start, endOffset: max(start, end))
    }
}

enum SMBSpikeError: LocalizedError, Equatable {
    case invalidHost
    case invalidPort
    case invalidShare
    case invalidPath
    case missingUsername
    case missingPassword
    case cannotCreateClient
    case noSupportedMedia
    case invalidFileSize
    case invalidReadRange
    case readInterrupted
    case fileChanged
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "服务器地址不正确"
        case .invalidPort:
            return "SMB 端口不正确"
        case .invalidShare:
            return "共享名称不能为空"
        case .invalidPath:
            return "媒体目录不正确"
        case .missingUsername:
            return "请输入 Samba 用户名"
        case .missingPassword:
            return "请输入 Samba 密码"
        case .cannotCreateClient:
            return "无法创建 SMB2 客户端"
        case .noSupportedMedia:
            return "目录中没有找到 MP4、M4V 或 MOV 视频"
        case .invalidFileSize:
            return "服务器返回了无效的文件大小"
        case .invalidReadRange:
            return "播放器请求了无效的文件范围"
        case .readInterrupted:
            return "SMB 读取中断"
        case .fileChanged:
            return "播放期间文件已发生变化"
        case .cancelled:
            return "操作已取消"
        }
    }
}

enum SMBSpikePath {
    private static let ignoredDirectoryNames: Set<String> = [
        "$RECYCLE.BIN",
        "System Volume Information",
        "@eaDir"
    ]
    private static let supportedExtensions: Set<String> = ["mp4", "m4v", "mov"]

    static func normalize(_ rawPath: String) throws -> String {
        guard !rawPath.contains("\0") else { throw SMBSpikeError.invalidPath }
        let slashPath = rawPath.replacingOccurrences(of: "\\", with: "/")
        let components = slashPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw SMBSpikeError.invalidPath
        }
        if components.isEmpty { return "/" }
        return "/" + components
            .map { String($0).precomposedStringWithCanonicalMapping }
            .joined(separator: "/")
    }

    static func child(named rawName: String, in directory: String) throws -> String {
        guard !rawName.isEmpty,
              !rawName.contains("/"),
              !rawName.contains("\\"),
              rawName != ".",
              rawName != ".." else {
            throw SMBSpikeError.invalidPath
        }
        let normalizedDirectory = try normalize(directory)
        let separator = normalizedDirectory == "/" ? "" : normalizedDirectory
        return try normalize(separator + "/" + rawName)
    }

    static func shouldIgnore(name: String, isDirectory: Bool) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("._") { return true }
        if isDirectory && ignoredDirectoryNames.contains(name) { return true }
        return false
    }

    static func isSupportedVideo(name: String) -> Bool {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(fileExtension)
    }
}
