//
// SMBSpikeTests.swift
// BabyPlayerTests
//
// SMB 直连 Spike 的纯逻辑回归测试：路径边界、媒体过滤和 AVPlayer Range 规划。
//

import AVFoundation
import XCTest
@testable import BabyPlayer

final class SMBSpikeTests: XCTestCase {
    private static let livePasswordDefaultsKey = "BabyPlayer.Tests.LiveSMBPassword"

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
