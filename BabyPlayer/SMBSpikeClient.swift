//
// SMBSpikeClient.swift
// BabyPlayer
//
// Phase A：用 AMSMB2 连接真实路由器共享，提供严格只读的目录、stat 和 range read。
//

import AMSMB2
import CryptoKit
import Foundation
import Security

struct SMBSpikeRangeProbeReport: Equatable, Sendable {
    let bytesRead: Int
    let elapsedSeconds: TimeInterval
    let headDigest: String
    let middleDigest: String
    let tailDigest: String
}

actor SMBSpikeClient {
    private let configuration: SMBSpikeConfiguration
    private var manager: SMB2Manager
    private var connected = false

    init(configuration: SMBSpikeConfiguration) throws {
        let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let share = configuration.share.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty,
              !host.contains("://"),
              !host.contains("/"),
              URL(string: "smb://\(host)")?.host != nil else {
            throw SMBSpikeError.invalidHost
        }
        guard configuration.port == 445 else { throw SMBSpikeError.invalidPort }
        guard !share.isEmpty, !share.contains("/"), !share.contains("\\") else {
            throw SMBSpikeError.invalidShare
        }
        guard !username.isEmpty else { throw SMBSpikeError.missingUsername }
        guard !configuration.password.isEmpty else { throw SMBSpikeError.missingPassword }

        var normalizedConfiguration = configuration
        normalizedConfiguration.host = host
        normalizedConfiguration.share = share
        normalizedConfiguration.rootPath = try SMBSpikePath.normalize(configuration.rootPath)
        normalizedConfiguration.username = username
        self.configuration = normalizedConfiguration
        self.manager = try Self.makeManager(configuration: normalizedConfiguration)
    }

    func connect() async throws {
        if connected { return }
        try Task.checkCancellation()
        try await manager.connectShare(name: configuration.share)
        connected = true
    }

    func disconnect() async {
        guard connected else { return }
        try? await manager.disconnectShare(gracefully: false)
        connected = false
    }

    func listMedia(
        maximumDepth: Int = 5,
        maximumEntries: Int = 10_000,
        maximumMediaItems: Int = 2_000
    ) async throws -> [SMBSpikeMediaItem] {
        try await connect()
        let rootPath = try SMBSpikePath.normalize(configuration.rootPath)
        var pendingDirectories: [(path: String, depth: Int)] = [(rootPath, 0)]
        var mediaItems: [SMBSpikeMediaItem] = []
        var visitedEntryCount = 0

        while !pendingDirectories.isEmpty,
              visitedEntryCount < maximumEntries,
              mediaItems.count < maximumMediaItems {
            try Task.checkCancellation()
            let current = pendingDirectories.removeFirst()
            let entries = try await manager.contentsOfDirectory(atPath: current.path)

            for entry in entries {
                try Task.checkCancellation()
                visitedEntryCount += 1
                if visitedEntryCount > maximumEntries { break }

                guard let rawName = entry.name, !rawName.isEmpty else { continue }
                let isDirectory = entry.isDirectory
                if SMBSpikePath.shouldIgnore(name: rawName, isDirectory: isDirectory) { continue }
                if entry.isSymbolicLink { continue }

                let path = try SMBSpikePath.child(named: rawName, in: current.path)
                if isDirectory {
                    if current.depth < maximumDepth {
                        pendingDirectories.append((path, current.depth + 1))
                    }
                    continue
                }

                guard SMBSpikePath.isSupportedVideo(name: rawName),
                      let fileSize = entry.fileSize,
                      fileSize > 0 else { continue }
                mediaItems.append(
                    SMBSpikeMediaItem(
                        path: path,
                        name: rawName,
                        fileSize: fileSize,
                        modifiedAt: entry.contentModificationDate
                    )
                )
                if mediaItems.count >= maximumMediaItems { break }
            }
        }

        guard !mediaItems.isEmpty else { throw SMBSpikeError.noSupportedMedia }
        return mediaItems.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func stat(path: String) async throws -> SMBSpikeFileStat {
        try await connect()
        let normalizedPath = try SMBSpikePath.normalize(path)
        let attributes = try await manager.attributesOfItem(atPath: normalizedPath)
        guard let fileSize = attributes.fileSize, fileSize >= 0 else {
            throw SMBSpikeError.invalidFileSize
        }
        return SMBSpikeFileStat(
            path: normalizedPath,
            fileSize: fileSize,
            modifiedAt: attributes.contentModificationDate
        )
    }

    func read(
        path: String,
        offset: UInt64,
        length: Int,
        expectedStat: SMBSpikeFileStat? = nil
    ) async throws -> Data {
        guard length > 0, length <= 1_048_576 else { throw SMBSpikeError.invalidReadRange }
        guard offset <= UInt64.max - UInt64(length) else { throw SMBSpikeError.invalidReadRange }
        try Task.checkCancellation()
        try await connect()
        let normalizedPath = try SMBSpikePath.normalize(path)

        do {
            let data = try await manager.contents(
                atPath: normalizedPath,
                range: offset..<(offset + UInt64(length))
            )
            try Task.checkCancellation()
            return data
        } catch is CancellationError {
            throw SMBSpikeError.cancelled
        } catch {
            connected = false
            let staleManager = manager
            try? await staleManager.disconnectShare(gracefully: false)
            try Task.checkCancellation()
            manager = try Self.makeManager(configuration: configuration)
            try await connect()
            if let expectedStat {
                let actualStat = try await stat(path: normalizedPath)
                guard Self.isSameFile(actualStat, as: expectedStat) else {
                    throw SMBSpikeError.fileChanged
                }
            }
            let data = try await manager.contents(
                atPath: normalizedPath,
                range: offset..<(offset + UInt64(length))
            )
            try Task.checkCancellation()
            return data
        }
    }

    func verifyRandomReads(for item: SMBSpikeMediaItem) async throws -> SMBSpikeRangeProbeReport {
        let statBefore = try await stat(path: item.path)
        guard statBefore.fileSize > 0 else { throw SMBSpikeError.invalidFileSize }
        let sampleLength = min(65_536, Int(statBefore.fileSize))
        let maximumOffset = UInt64(max(0, statBefore.fileSize - Int64(sampleLength)))
        let offsets: [UInt64] = [0, maximumOffset / 2, maximumOffset]
        let startedAt = Date()
        var samples: [Data] = []

        for offset in offsets {
            let data = try await read(
                path: item.path,
                offset: offset,
                length: sampleLength,
                expectedStat: statBefore
            )
            guard !data.isEmpty else { throw SMBSpikeError.readInterrupted }
            samples.append(data)
        }

        let statAfter = try await stat(path: item.path)
        guard statBefore.fileSize == statAfter.fileSize,
              statBefore.modifiedAt == statAfter.modifiedAt else {
            throw SMBSpikeError.fileChanged
        }

        return SMBSpikeRangeProbeReport(
            bytesRead: samples.reduce(0) { $0 + $1.count },
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            headDigest: Self.digest(samples[0]),
            middleDigest: Self.digest(samples[1]),
            tailDigest: Self.digest(samples[2])
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSameFile(_ actual: SMBSpikeFileStat, as expected: SMBSpikeFileStat) -> Bool {
        guard actual.path == expected.path,
              actual.fileSize == expected.fileSize else { return false }
        guard let expectedDate = expected.modifiedAt else { return true }
        return actual.modifiedAt == expectedDate
    }

    private static func makeManager(configuration: SMBSpikeConfiguration) throws -> SMB2Manager {
        // AMSMB2/libsmb2 defaults to TCP 445. Field testing against the original
        // ZTE router showed that embedding the default port can stall negotiation,
        // so keep 445 as an application invariant but do not append it to the URL.
        var components = URLComponents()
        components.scheme = "smb"
        components.host = configuration.host
        guard let serverURL = components.url else { throw SMBSpikeError.invalidHost }
        let credential = URLCredential(
            user: configuration.username,
            password: configuration.password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: serverURL, credential: credential) else {
            throw SMBSpikeError.cannotCreateClient
        }
        manager.timeout = 5
        return manager
    }
}

private struct SMBSpikeSavedSettings: Codable {
    var host: String
    var port: Int
    var share: String
    var rootPath: String
    var username: String

    init(configuration: SMBSpikeConfiguration) {
        host = configuration.host
        port = configuration.port
        share = configuration.share
        rootPath = configuration.rootPath
        username = configuration.username
    }

    func configuration(password: String) -> SMBSpikeConfiguration {
        SMBSpikeConfiguration(
            host: host,
            port: port,
            share: share,
            rootPath: rootPath,
            username: username,
            password: password
        )
    }
}

enum SMBSpikeConfigurationStore {
    // v2 switches the active household defaults from the old ZTE 192.168.5.1
    // share to the Huawei gateway share on the Apple TV's 192.168.1.x LAN.
    private static let settingsKey = "BabyPlayer.SMBSpike.Settings.v2"
    private static let keychainService = "com.wufengyu.BabyPlayer.smb-spike"
    private static let keychainAccount = "home-gateway-primary"

    static var hasSavedConfiguration: Bool {
        UserDefaults.standard.data(forKey: settingsKey) != nil
    }

    static func load() -> SMBSpikeConfiguration {
        let savedPassword = loadPassword()
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(SMBSpikeSavedSettings.self, from: data)
        else {
            var defaults = SMBSpikeConfiguration.homeGatewayDefaults
            defaults.password = savedPassword ?? defaults.password
            return defaults
        }
        return settings.configuration(
            password: savedPassword ?? SMBSpikeConfiguration.homeGatewayDefaults.password
        )
    }

    static func save(_ configuration: SMBSpikeConfiguration) throws {
        let passwordData = Data(configuration.password.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [kSecValueData as String: passwordData]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecValueData as String] = passwordData
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else if updateStatus != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }

        let settings = SMBSpikeSavedSettings(configuration: configuration)
        let settingsData = try JSONEncoder().encode(settings)
        UserDefaults.standard.set(settingsData, forKey: settingsKey)
    }

    private static func loadPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
