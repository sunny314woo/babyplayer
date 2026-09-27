//
// SMBSpikeTests.swift
// BabyPlayerTests
//
// SMB 直连 Spike 的纯逻辑回归测试：路径边界、媒体过滤和 AVPlayer Range 规划。
// 最近修改：【MODIFIED】Phase 3 覆盖三源状态、优先级、启动选择和播放中禁用回退。
//

import AVFoundation
import Foundation
import XCTest
@testable import BabyPlayer

final class SMBSpikeTests: XCTestCase {
    private static let livePasswordDefaultsKey = "BabyPlayer.Tests.LiveSMBPassword"

    func testCountedRepeatPolicyUsesThreeMeaningfulPresets() {
        XCTAssertEqual(BabyPlayerCountedRepeatPolicy.availableCounts, [5, 15, 30])
        XCTAssertEqual(BabyPlayerCountedRepeatPolicy.defaultCount, 5)
        XCTAssertEqual(BabyPlayerCountedRepeatPolicy.normalized(20), 15)
        XCTAssertEqual(BabyPlayerCountedRepeatPolicy.normalized(60), 30)
    }

    func testCountedRepeatPolicyCountsTheFirstPlay() {
        XCTAssertTrue(BabyPlayerCountedRepeatPolicy.shouldRepeat(
            currentPlayNumber: 1,
            totalPlays: 5
        ))
        XCTAssertTrue(BabyPlayerCountedRepeatPolicy.shouldRepeat(
            currentPlayNumber: 4,
            totalPlays: 5
        ))
        XCTAssertFalse(BabyPlayerCountedRepeatPolicy.shouldRepeat(
            currentPlayNumber: 5,
            totalPlays: 5
        ))
        XCTAssertTrue(BabyPlayerCountedRepeatPolicy.shouldRepeat(
            currentPlayNumber: 14,
            totalPlays: 15
        ))
        XCTAssertFalse(BabyPlayerCountedRepeatPolicy.shouldRepeat(
            currentPlayNumber: 15,
            totalPlays: 15
        ))
        XCTAssertFalse(BabyPlayerCountedRepeatPolicy.shouldRepeat(
            currentPlayNumber: 30,
            totalPlays: 30
        ))
    }

    func testPathNormalizationAndChildJoining() throws {
        XCTAssertEqual(try SMBSpikePath.normalize("//sss73///cartoons/"), "/sss73/cartoons")
        XCTAssertEqual(
            try SMBSpikePath.child(named: "小熊.mp4", in: "/sss73/cartoons"),
            "/sss73/cartoons/小熊.mp4"
        )
    }

    func testPathTraversalAndEmbeddedSeparatorsAreRejected() {
        XCTAssertThrowsError(try SMBSpikePath.normalize("/sss73/../secret"))
        XCTAssertThrowsError(try SMBSpikePath.child(named: "other/file.mp4", in: "/sss73"))
        XCTAssertThrowsError(try SMBSpikePath.child(named: "..", in: "/sss73"))
    }

    func testMediaFilterIgnoresSystemEntriesAndAcceptsExpectedContainers() {
        XCTAssertTrue(SMBSpikePath.shouldIgnore(name: ".hidden", isDirectory: false))
        XCTAssertTrue(SMBSpikePath.shouldIgnore(name: "._episode.mp4", isDirectory: false))
        XCTAssertTrue(SMBSpikePath.shouldIgnore(name: "System Volume Information", isDirectory: true))
        XCTAssertTrue(SMBSpikePath.isSupportedVideo(name: "episode.MP4"))
        XCTAssertTrue(SMBSpikePath.isSupportedVideo(name: "episode.m4v"))
        XCTAssertFalse(SMBSpikePath.isSupportedVideo(name: "episode.mkv"))
    }

    func testPersistedMediaSourceWinsAndLegacySMBConfigurationMigrates() {
        XCTAssertEqual(
            BabyPlayerMediaSourcePreference.resolvedSource(
                storedRawValue: BabyPlayerMediaSourceKind.samba.rawValue,
                hasSavedSMBConfiguration: false
            ),
            .samba
        )
        XCTAssertEqual(
            BabyPlayerMediaSourcePreference.resolvedSource(
                storedRawValue: BabyPlayerMediaSourceKind.jellyfin.rawValue,
                hasSavedSMBConfiguration: true
            ),
            .jellyfin
        )
        XCTAssertEqual(
            BabyPlayerMediaSourcePreference.resolvedSource(
                storedRawValue: nil,
                hasSavedSMBConfiguration: true
            ),
            .samba
        )
    }

    /// 【MODIFIED】职责：验证三个来源均有独立的未配置、离线与在线状态。
    func testAllMediaSourceConfigurationAndOnlineStates() {
        XCTAssertEqual(Set(BabyPlayerMediaSourceKind.allCases), [.samba, .baidu, .jellyfin])
        for _ in BabyPlayerMediaSourceKind.allCases {
            XCTAssertEqual(BabyPlayerMediaSourceStatusPolicy.resolve(
                isConfigured: false, isReachable: false
            ), .unconfigured)
            XCTAssertEqual(BabyPlayerMediaSourceStatusPolicy.resolve(
                isConfigured: false, isReachable: true
            ), .unconfigured)
            XCTAssertEqual(BabyPlayerMediaSourceStatusPolicy.resolve(
                isConfigured: true, isReachable: false
            ), .offline)
            XCTAssertEqual(BabyPlayerMediaSourceStatusPolicy.resolve(
                isConfigured: true, isReachable: true
            ), .online)
        }
    }

    /// 【MODIFIED】职责：默认 NAS 优先，家长排序跨重启保存且旧默认来源不能覆盖新规则。
    func testMediaSourcePriorityPersistsAndIgnoresLegacyActiveSource() {
        let suite = "BabyPlayerTests.SourcePriority.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(BabyPlayerMediaSourceKind.jellyfin.rawValue, forKey: "BabyPlayer.ActiveMediaSource.v1")
        XCTAssertEqual(BabyPlayerMediaSourcePriorityStore.load(defaults: defaults),
                       [.samba, .baidu, .jellyfin])
        BabyPlayerMediaSourcePriorityStore.save([.jellyfin, .samba, .baidu], defaults: defaults)
        XCTAssertEqual(BabyPlayerMediaSourcePriorityStore.load(defaults: defaults),
                       [.jellyfin, .samba, .baidu])
        defaults.set(["unknown", "baidu", "baidu"], forKey: "BabyPlayer.MediaSourcePriority.v1")
        XCTAssertEqual(BabyPlayerMediaSourcePriorityStore.load(defaults: defaults),
                       [.baidu, .samba, .jellyfin])
    }

    /// 【MODIFIED】职责：验证启动选择最高在线源、单源离线回退及全部离线返回配置态。
    func testStartupSourceSelectionAndInitialFallback() {
        let priority = BabyPlayerMediaSourceSelectionPolicy.defaultPriority
        XCTAssertEqual(priority.first, .samba)
        let allOnline: [BabyPlayerMediaSourceKind: BabyPlayerMediaSourceAvailability] = [
            .samba: .online, .baidu: .online, .jellyfin: .online
        ]
        XCTAssertEqual(BabyPlayerMediaSourceSelectionPolicy.highestOnline(
            priority: priority, states: allOnline
        ), .samba)
        XCTAssertEqual(BabyPlayerMediaSourceSelectionPolicy.highestOnline(
            priority: priority, states: allOnline, excluding: [.samba]
        ), .baidu)
        XCTAssertEqual(BabyPlayerMediaSourceSelectionPolicy.highestOnline(
            priority: [.jellyfin, .samba, .baidu], states: allOnline
        ), .jellyfin)
        XCTAssertEqual(BabyPlayerMediaSourceSelectionPolicy.highestOnline(
            priority: priority,
            states: [.samba: .offline, .baidu: .unconfigured, .jellyfin: .online]
        ), .jellyfin)
        XCTAssertNil(BabyPlayerMediaSourceSelectionPolicy.highestOnline(
            priority: priority,
            states: [.samba: .offline, .baidu: .unconfigured, .jellyfin: .offline]
        ))
    }

    /// 【MODIFIED】职责：播放中断线时永不允许跨源自动切换。
    func testAutomaticSwitchIsLimitedToLaunchAndInitialLoad() {
        XCTAssertTrue(BabyPlayerMediaSourceSelectionPolicy.mayAutoSwitch(
            for: .appLaunch, isPlaybackActive: false
        ))
        XCTAssertTrue(BabyPlayerMediaSourceSelectionPolicy.mayAutoSwitch(
            for: .initialLibraryLoadFailure, isPlaybackActive: false
        ))
        XCTAssertFalse(BabyPlayerMediaSourceSelectionPolicy.mayAutoSwitch(
            for: .playbackDisconnect, isPlaybackActive: false
        ))
        XCTAssertFalse(BabyPlayerMediaSourceSelectionPolicy.mayAutoSwitch(
            for: .initialLibraryLoadFailure, isPlaybackActive: true
        ))
    }

    /// 【MODIFIED】职责：验证历史内容 ID 不丢失，新视频停止按同名跨来源建立关联。
    func testExistingContentAliasesSurviveWhileNewSourcesStayIndependent() {
        let old = "filename-sha256:historical"
        let aliases = ["jellyfin-old": old, "smb:/root/old.mp4": old]
        XCTAssertEqual(BabyPlayerContentIdentityResolver.resolvedContentID(
            for: "jellyfin-old", existingAliases: aliases
        ), old)
        XCTAssertEqual(BabyPlayerContentIdentityResolver.resolvedContentID(
            for: "smb:/root/old.mp4", existingAliases: aliases
        ), old)
        XCTAssertEqual(BabyPlayerContentIdentityResolver.resolvedContentID(
            for: "jellyfin-new", existingAliases: aliases
        ), "source-v1:jellyfin:jellyfin-new")
        XCTAssertEqual(BabyPlayerContentIdentityResolver.resolvedContentID(
            for: "smb:/root/new.mp4", existingAliases: aliases
        ), "source-v1:smb:/root/new.mp4")
        XCTAssertNotEqual(
            BabyPlayerContentIdentityResolver.sourceScopedID(for: "same-name"),
            BabyPlayerContentIdentityResolver.sourceScopedID(for: "smb:/root/same-name")
        )
        let jellyfin = LyricsMediaDescriptor(
            id: "same-name", title: "Same Name", searchTitle: "Same Name",
            artistName: nil, sourceHint: nil, versionHint: nil,
            durationSeconds: nil, songStartSeconds: nil, songEndSeconds: nil,
            mediaSourceID: "same-name",
            localMediaMigrationKey: BabyPlayerContentIdentityResolver.sourceScopedID(for: "same-name")
        )
        let samba = LyricsMediaDescriptor(
            id: "smb:/root/same-name", title: "Same Name", searchTitle: "Same Name",
            artistName: nil, sourceHint: nil, versionHint: nil,
            durationSeconds: nil, songStartSeconds: nil, songEndSeconds: nil,
            mediaSourceID: "smb:/root/same-name",
            localMediaMigrationKey: BabyPlayerContentIdentityResolver.sourceScopedID(for: "smb:/root/same-name")
        )
        XCTAssertNotEqual(jellyfin.sharedContentID, samba.sharedContentID)
        XCTAssertNotEqual(jellyfin.asrFingerprint, samba.asrFingerprint)
    }

    /// 【MODIFIED】职责：验证 Root Folder 边界、逐级返回与每个来源的历史目录持久化。
    func testDirectoryNavigationStaysWithinRootAndRestoresLastFolder() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let root = BabyPlayerFolderNode(id: "/root/one", name: "one")
        let child = BabyPlayerFolderNode(id: "/root/one/two", name: "two")
        var navigation = BabyPlayerDirectoryNavigation(
            sourceKey: "samba", rootID: "/root", defaults: defaults
        )
        XCTAssertFalse(navigation.open(child, visibleFolders: [root], defaults: defaults))
        XCTAssertTrue(navigation.open(root, visibleFolders: [root], defaults: defaults))
        XCTAssertTrue(navigation.open(child, visibleFolders: [child], defaults: defaults))
        XCTAssertEqual(navigation.currentID, child.id)

        var restored = BabyPlayerDirectoryNavigation(
            sourceKey: "samba", rootID: "/root", defaults: defaults
        )
        XCTAssertEqual(restored.savedPath, [root, child])
        XCTAssertTrue(restored.goBack(defaults: defaults))
        XCTAssertEqual(restored.currentID, root.id)
        XCTAssertTrue(restored.goBack(defaults: defaults))
        XCTAssertFalse(restored.goBack(defaults: defaults))
        XCTAssertEqual(restored.currentID, "/root")
        XCTAssertTrue(BabyPlayerDirectoryNavigation(
            sourceKey: "jellyfin", rootID: "/root", defaults: defaults
        ).savedPath.isEmpty)
        let renamed = BabyPlayerFolderNode(id: root.id, name: "renamed")
        XCTAssertTrue(restored.open(root, visibleFolders: [renamed], defaults: defaults))
        XCTAssertEqual(restored.currentName, "renamed")
    }

    /// 【MODIFIED】职责：验证旧 Samba 平面索引仍可展示根目录、子目录和视频。
    func testCachedSambaIndexRecoversFoldersWithoutLeakingOutsideRoot() {
        let items = [
            SMBSpikeMediaItem(path: "/root/a.mp4", name: "a.mp4", fileSize: 10, modifiedAt: nil),
            SMBSpikeMediaItem(path: "/root/one/b.mp4", name: "b.mp4", fileSize: 10, modifiedAt: nil),
            SMBSpikeMediaItem(path: "/root/one/two/c.mp4", name: "c.mp4", fileSize: 10, modifiedAt: nil),
            SMBSpikeMediaItem(path: "/outside/d.mp4", name: "d.mp4", fileSize: 10, modifiedAt: nil)
        ]
        let root = SMBSpikeLibraryIndexStore.directoryFromCachedItems(
            items, rootPath: "/root", directoryPath: "/root"
        )
        XCTAssertEqual(root.videos.map(\.name), ["a.mp4"])
        XCTAssertEqual(root.folders.map(\.name), ["one"])
        let child = SMBSpikeLibraryIndexStore.directoryFromCachedItems(
            items, rootPath: "/root", directoryPath: "/root/one"
        )
        XCTAssertEqual(child.videos.map(\.name), ["b.mp4"])
        XCTAssertEqual(child.folders.map(\.name), ["two"])
        XCTAssertTrue(SMBSpikeLibraryIndexStore.directoryFromCachedItems(
            items, rootPath: "/root", directoryPath: "/outside"
        ).videos.isEmpty)
    }

    /// 【MODIFIED】职责：验证 Samba 目录 API 在联网前拒绝越过 Root Folder 的路径。
    func testSambaDirectoryRejectsPathOutsideRootBeforeConnecting() async throws {
        var configuration = SMBSpikeConfiguration.homeGatewayDefaults
        configuration.rootPath = "/root"
        configuration.password = "unit-test-placeholder"
        let client = try SMBSpikeClient(configuration: configuration)
        do {
            _ = try await client.listDirectory(at: "/outside")
            XCTFail("Expected Root Folder boundary error")
        } catch SMBSpikeError.invalidPath {
            // Expected without touching the network.
        }
    }

    /// 【MODIFIED】职责：用模拟 Jellyfin API 验证三层目录和文件夹递归队列不丢视频。
    func testJellyfinDirectoryTraversesNestedFoldersAndVideos() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BabyPlayerDirectoryFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = try JellyfinSpikeClient(
            serverAddress: "http://babyplayer.invalid:8096",
            deviceID: "directory-test",
            session: session
        )
        let root = try await client.fetchMusicVideoRoot(userID: "user", accessToken: "token")
        XCTAssertEqual(root.id, "root")
        let first = try await client.fetchDirectory(
            userID: "user", accessToken: "token", parentID: root.id
        )
        XCTAssertEqual(first.folders.map(\.id), ["one"])
        XCTAssertEqual(first.videos.map(\.id), ["root-video"])
        let recursive = try await client.fetchFolderVideos(
            userID: "user", accessToken: "token", folderID: root.id
        )
        XCTAssertEqual(recursive.map(\.id), ["root-video", "one-video", "two-video"])
        let paged = try await client.fetchDirectory(
            userID: "user", accessToken: "token", parentID: "many"
        )
        XCTAssertEqual(paged.videos.count, 201)
        XCTAssertEqual(paged.videos.first?.id, "page-0")
        XCTAssertEqual(paged.videos.last?.id, "page-200")
    }

    func testRangePlanUsesOriginalRequestEndAfterPartialResponse() throws {
        let plan = try SMBSpikeByteRangePlan.make(
            fileSize: 10_000,
            requestedOffset: 1_000,
            currentOffset: 1_400,
            requestedLength: 1_000,
            requestsAllDataToEnd: false
        )
        XCTAssertEqual(plan, SMBSpikeByteRangePlan(startOffset: 1_400, endOffset: 2_000))
    }

    func testRangePlanClampsToEOFAndSupportsReadToEnd() throws {
        XCTAssertEqual(
            try SMBSpikeByteRangePlan.make(
                fileSize: 2_000,
                requestedOffset: 1_800,
                currentOffset: 1_800,
                requestedLength: 500,
                requestsAllDataToEnd: false
            ),
            SMBSpikeByteRangePlan(startOffset: 1_800, endOffset: 2_000)
        )
        XCTAssertEqual(
            try SMBSpikeByteRangePlan.make(
                fileSize: 2_000,
                requestedOffset: 500,
                currentOffset: 750,
                requestedLength: 1,
                requestsAllDataToEnd: true
            ),
            SMBSpikeByteRangePlan(startOffset: 750, endOffset: 2_000)
        )
    }

    func testRangePlanRejectsNegativeAndInconsistentRequests() {
        XCTAssertThrowsError(
            try SMBSpikeByteRangePlan.make(
                fileSize: 2_000,
                requestedOffset: -1,
                currentOffset: 0,
                requestedLength: 1,
                requestsAllDataToEnd: false
            )
        )
        XCTAssertThrowsError(
            try SMBSpikeByteRangePlan.make(
                fileSize: 2_000,
                requestedOffset: 100,
                currentOffset: 500,
                requestedLength: 100,
                requestsAllDataToEnd: false
            )
        )
    }

    func testLibraryIndexRoundTripsWithoutPersistingPasswordAndRejectsAnotherSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BabyPlayer-SMBIndex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = SMBSpikeConfiguration.homeGatewayDefaults
        configuration.password = "must-not-be-written"
        let items = [
            SMBSpikeMediaItem(
                path: "/sss73/52. After A While Crocodile.mp4",
                name: "52. After A While Crocodile.mp4",
                fileSize: 42_000,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ]

        try SMBSpikeLibraryIndexStore.save(
            items,
            configuration: configuration,
            cacheDirectory: root
        )
        XCTAssertEqual(
            SMBSpikeLibraryIndexStore.load(
                configuration: configuration,
                cacheDirectory: root
            ),
            items
        )
        let rawIndex = try String(
            contentsOf: root
                .appendingPathComponent("BabyPlayer", isDirectory: true)
                .appendingPathComponent("SMBMediaIndex-v1.json"),
            encoding: .utf8
        )
        XCTAssertFalse(rawIndex.contains(configuration.password))

        var otherSource = configuration
        otherSource.rootPath = "/another-folder"
        XCTAssertNil(SMBSpikeLibraryIndexStore.load(
            configuration: otherSource,
            cacheDirectory: root
        ))
    }

    func testLibraryIndexRejectsCorruptAndUnsafeItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BabyPlayer-SMBIndexInvalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = SMBSpikeConfiguration.homeGatewayDefaults
        let unsafeItems = [
            SMBSpikeMediaItem(
                path: "/sss73/../secret.mp4",
                name: "secret.mp4",
                fileSize: 10,
                modifiedAt: nil
            )
        ]
        XCTAssertThrowsError(try SMBSpikeLibraryIndexStore.save(
            unsafeItems,
            configuration: configuration,
            cacheDirectory: root
        ))

        let folder = root.appendingPathComponent("BabyPlayer", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: folder.appendingPathComponent("SMBMediaIndex-v1.json")
        )
        XCTAssertNil(SMBSpikeLibraryIndexStore.load(
            configuration: configuration,
            cacheDirectory: root
        ))
    }

    func testLiveHomeGatewayListsOnlyRealVideosAndReadsRanges() async throws {
        guard let password = UserDefaults.standard.string(
            forKey: Self.livePasswordDefaultsKey
        ), !password.isEmpty else {
            throw XCTSkip("Live SMB password was not injected into this test simulator.")
        }

        var configuration = SMBSpikeConfiguration.homeGatewayDefaults
        configuration.password = password
        let client = try SMBSpikeClient(configuration: configuration)
        do {
            let items = try await client.listMedia()
            XCTAssertEqual(items.count, 78, "The home gateway /sss73 manifest should contain 78 real videos.")
            XCTAssertFalse(items.contains { $0.name.hasPrefix(".") })
            XCTAssertTrue(items.allSatisfy { SMBSpikePath.isSupportedVideo(name: $0.name) })

            let report = try await client.verifyRandomReads(for: try XCTUnwrap(items.first))
            XCTAssertGreaterThan(report.bytesRead, 0)
            XCTAssertFalse(report.headDigest.isEmpty)
            XCTAssertFalse(report.middleDigest.isEmpty)
            XCTAssertFalse(report.tailDigest.isEmpty)

            let preparedAsset = SMBSpikePreparedAsset(
                client: client,
                item: try XCTUnwrap(items.first)
            )
            let isPlayable = try await preparedAsset.asset.load(.isPlayable)
            let duration = try await preparedAsset.asset.load(.duration)
            XCTAssertTrue(isPlayable)
            XCTAssertTrue(duration.isNumeric)
            XCTAssertGreaterThan(duration.seconds, 0)
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }
}

/// 【MODIFIED】职责：仅为 Jellyfin 目录单测返回固定三层响应；输入为请求 URL，输出为 JSON HTTP 响应。
private final class BabyPlayerDirectoryFixtureProtocol: URLProtocol {
    /// 【MODIFIED】职责：拦截本测试会话的请求；输出是否接管该请求。
    override class func canInit(with request: URLRequest) -> Bool { true }

    /// 【MODIFIED】职责：保持请求原样，避免 URLProtocol 重复改写。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 【MODIFIED】职责：按 parentId 返回当前层文件夹和视频；副作用是完成 URLSession 请求。
    override func startLoading() {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: String
        if url.lastPathComponent == "UserViews" {
            body = #"{"Items":[{"Id":"root","Name":"音乐视频","CollectionType":"musicvideos"}]}"#
        } else {
            let parent = components.queryItems?.first(where: { $0.name == "parentId" })?.value
            switch parent {
            case "root":
                body = #"{"Items":[{"Id":"one","Name":"第一层","Type":"Folder"},{"Id":"root-video","Name":"根视频","Type":"Video"}]}"#
            case "one":
                body = #"{"Items":[{"Id":"two","Name":"第二层","Type":"Folder"},{"Id":"one-video","Name":"第一层视频","Type":"MusicVideo"}]}"#
            case "two":
                body = #"{"Items":[{"Id":"two-video","Name":"第二层视频","Type":"Video"}]}"#
            case "many":
                let start = Int(components.queryItems?.first(where: { $0.name == "startIndex" })?.value ?? "0") ?? 0
                let end = min(start + 200, 201)
                let videos = (start..<end).map { index in
                    "{\"Id\":\"page-\(index)\",\"Name\":\"Video \(index)\",\"Type\":\"Video\"}"
                }
                body = "{\"Items\":[\(videos.joined(separator: ","))]}"
            default:
                body = #"{"Items":[]}"#
            }
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// 【MODIFIED】职责：结束测试请求；无额外副作用。
    override func stopLoading() { }
}
