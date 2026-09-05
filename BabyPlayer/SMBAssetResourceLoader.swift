//
// SMBAssetResourceLoader.swift
// BabyPlayer
//
// Phase A：把 AVFoundation 的 byte-range 请求桥接到 SMBSpikeClient.read。
// 当前实现刻意保持有界、串行和只读，作为真机 Go/No-Go 验证链路。
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// 播放队列中的轻量 Samba 引用；只在该曲目真正开始播放时创建 loader/AVAsset。
final class SMBPlaybackResource: @unchecked Sendable {
    private let client: SMBSpikeClient
    private let item: SMBSpikeMediaItem

    init(client: SMBSpikeClient, item: SMBSpikeMediaItem) {
        self.client = client
        self.item = item
    }

    func makePreparedAsset() -> SMBSpikePreparedAsset {
        SMBSpikePreparedAsset(client: client, item: item)
    }
}

final class SMBSpikePreparedAsset {
    let asset: AVURLAsset
    private let loader: SMBSpikeAssetResourceLoader

    init(client: SMBSpikeClient, item: SMBSpikeMediaItem) {
        let assetURL = URL(string: "babyplayer-smb://asset/\(UUID().uuidString)")!
        let asset = AVURLAsset(
            url: assetURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let loader = SMBSpikeAssetResourceLoader(client: client, item: item)
        asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
        self.asset = asset
        self.loader = loader
    }

    deinit {
        loader.cancelAll()
    }
}

final class SMBSpikeAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let delegateQueue = DispatchQueue(label: "com.wufengyu.BabyPlayer.smb-resource-loader")

    private let client: SMBSpikeClient
    private let item: SMBSpikeMediaItem
    private let maximumChunkSize = 524_288
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private var activeRequest: AVAssetResourceLoadingRequest?
    private var activeTask: Task<Void, Never>?

    init(client: SMBSpikeClient, item: SMBSpikeMediaItem) {
        self.client = client
        self.item = item
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        populateContentInformation(loadingRequest.contentInformationRequest)
        guard loadingRequest.dataRequest != nil else {
            loadingRequest.finishLoading()
            return true
        }
        pendingRequests.append(loadingRequest)
        startNextRequestIfNeeded()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        if activeRequest === loadingRequest {
            activeTask?.cancel()
            return
        }
        pendingRequests.removeAll { $0 === loadingRequest }
    }

    func cancelAll() {
        delegateQueue.async { [self] in
            activeTask?.cancel()
            pendingRequests.removeAll()
        }
    }

    private func populateContentInformation(
        _ request: AVAssetResourceLoadingContentInformationRequest?
    ) {
        guard let request else { return }
        let fileExtension = (item.name as NSString).pathExtension
        request.contentType = UTType(filenameExtension: fileExtension)?.identifier
            ?? UTType.mpeg4Movie.identifier
        request.contentLength = item.fileSize
        request.isByteRangeAccessSupported = true
    }

    private func startNextRequestIfNeeded() {
        guard activeRequest == nil, !pendingRequests.isEmpty else { return }
        let request = pendingRequests.removeFirst()
        activeRequest = request
        activeTask = Task { [weak self, weak request] in
            guard let self, let request else { return }
            do {
                try await serve(request)
                complete(request, error: nil)
            } catch is CancellationError {
                complete(request, error: SMBSpikeError.cancelled)
            } catch {
                complete(request, error: error)
            }
        }
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) async throws {
        guard let dataRequest = request.dataRequest else { return }
        let rangePlan = try SMBSpikeByteRangePlan.make(
            fileSize: item.fileSize,
            requestedOffset: dataRequest.requestedOffset,
            currentOffset: dataRequest.currentOffset,
            requestedLength: dataRequest.requestedLength,
            requestsAllDataToEnd: dataRequest.requestsAllDataToEndOfResource
        )
        var offset = rangePlan.startOffset
        let requestedEnd = rangePlan.endOffset

        if offset >= requestedEnd { return }
        while offset < requestedEnd {
            try Task.checkCancellation()
            let remaining = requestedEnd - offset
            let chunkLength = Int(min(UInt64(maximumChunkSize), remaining))
            let data = try await client.read(
                path: item.path,
                offset: offset,
                length: chunkLength,
                expectedStat: SMBSpikeFileStat(
                    path: item.path,
                    fileSize: item.fileSize,
                    modifiedAt: item.modifiedAt
                )
            )
            try Task.checkCancellation()
            guard !data.isEmpty else { throw SMBSpikeError.readInterrupted }
            dataRequest.respond(with: data)
            offset += UInt64(data.count)
        }
    }

    private func complete(_ request: AVAssetResourceLoadingRequest, error: Error?) {
        delegateQueue.async { [weak self, weak request] in
            guard let self, let request, activeRequest === request else { return }
            activeTask = nil
            activeRequest = nil
            if error == nil {
                request.finishLoading()
            } else if !(error is CancellationError) && error as? SMBSpikeError != .cancelled {
                request.finishLoading(with: error)
            }
            startNextRequestIfNeeded()
        }
    }
}
