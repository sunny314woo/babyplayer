//
// MediaCoverLoader.swift
// 用途：提供与媒体来源无关的视频封面加载和生成能力。
// 主要功能：来源封面优先；没有来源封面时从视频内部抽取 5 帧并选择较合适的一帧，结果缓存在本地。
// 最近修改：2026-08-22 增加跨媒体源的封面兜底和扫描后的后台预热。
//

import AVFoundation
import CryptoKit
import SwiftUI
import UIKit

/// 媒体源交给封面层的最小输入；来源可以是 Jellyfin、U 盘或 NAS。
struct BabyPlayerCoverSource: @unchecked Sendable {
    let providerImageURL: URL?
    let videoURL: URL?
    let smbPlaybackResource: SMBPlaybackResource?
    let duration: TimeInterval?
    let cacheKey: String
    /// 旧版本按来源保存的单张封面键；命中后会迁移并删除旧缓存文件。
    let legacyCacheKeys: [String]

    init(
        providerImageURL: URL?,
        videoURL: URL?,
        smbPlaybackResource: SMBPlaybackResource?,
        duration: TimeInterval?,
        cacheKey: String,
        legacyCacheKeys: [String] = []
    ) {
        self.providerImageURL = providerImageURL
        self.videoURL = videoURL
        self.smbPlaybackResource = smbPlaybackResource
        self.duration = duration
        self.cacheKey = cacheKey
        self.legacyCacheKeys = legacyCacheKeys
    }

    var viewIdentity: String {
        "\(cacheKey)|\(providerImageURL != nil)|\(videoURL != nil)|\(smbPlaybackResource != nil)"
    }
}

enum BabyPlayerCoverCacheIdentity {
    static func shared(contentID: String) -> String {
        "content:v2:\(contentID)"
    }

    static func jellyfinLegacy(itemID: String) -> String {
        "jellyfin:\(itemID)"
    }

    static func smbLegacy(
        path: String,
        fileSize: Int64,
        modifiedAt: Date?
    ) -> String {
        let modifiedStamp = modifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return "smb:v1:\(path)|\(fileSize)|\(modifiedStamp)"
    }
}

/// 封面是可重建数据；tvOS 真机已验证 App 私有 Caches 可写且覆盖安装保留。
enum BabyPlayerCoverStoragePolicy {
    static func writableStorageBase(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
}

/// 所有本地抽帧共用一条串行队列，并按 cache key 合并重复请求。
/// 这避免首页同时出现 12 张卡片时创建 12 个解码器或挤占 SMB 播放读取。
private actor BabyPlayerCoverGenerationCoordinator {
    private struct Entry {
        let id: UUID
        let task: Task<UIImage?, Never>
    }

    static let shared = BabyPlayerCoverGenerationCoordinator()
    private var inFlight: [String: Entry] = [:]
    private var tail: Task<Void, Never>?

    func generate(for source: BabyPlayerCoverSource) async -> UIImage? {
        if let existing = inFlight[source.cacheKey] {
            return await existing.task.value
        }
        let predecessor = tail
        let id = UUID()
        let task: Task<UIImage?, Never> = Task(priority: .utility) {
            if let predecessor { await predecessor.value }
            guard !Task.isCancelled else { return nil }
            return await BabyPlayerCoverGenerator.generateUncached(for: source)
        }
        inFlight[source.cacheKey] = Entry(id: id, task: task)
        tail = Task { _ = await task.value }
        let result = await task.value
        if inFlight[source.cacheKey]?.id == id {
            inFlight[source.cacheKey] = nil
        }
        return result
    }
}

/// 生成并缓存本地视频封面；不会读取或写入媒体源的业务状态。
enum BabyPlayerCoverGenerator {
    private static let cacheDirectoryURL: URL = {
        let baseURL = BabyPlayerCoverStoragePolicy.writableStorageBase()
        return baseURL.appendingPathComponent("BabyPlayer/Covers", isDirectory: true)
    }()

    /// 2026-09-06 以前的版本尝试写入此目录；部分 tvOS 环境未创建它。
    /// 只作兼容读取，新封面始终写入已验证的 Caches。
    private static let legacyApplicationSupportDirectoryURL: URL? = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("BabyPlayer/Covers", isDirectory: true)
    }()

    /// 【MODIFIED】为无来源封面的媒体生成本地封面；扫描后可后台调用，卡片首次显示时也可调用。
    static func generate(for source: BabyPlayerCoverSource) async -> UIImage? {
        if let cachedImage = loadCachedImage(for: source) {
            return cachedImage
        }
        return await BabyPlayerCoverGenerationCoordinator.shared.generate(for: source)
    }

    fileprivate static func generateUncached(for source: BabyPlayerCoverSource) async -> UIImage? {
        if let cachedImage = loadCachedImage(for: source) {
            return cachedImage
        }
        let preparedSMBAsset = source.smbPlaybackResource?.makePreparedAsset()
        let asset: AVAsset
        if let preparedSMBAsset {
            asset = preparedSMBAsset.asset
        } else if let videoURL = source.videoURL {
            asset = AVURLAsset(url: videoURL)
        } else {
            return nil
        }
        // AVAssetResourceLoader 的 delegate 是弱引用；抽帧结束前必须保留 SMB prepared asset。
        defer { withExtendedLifetime(preparedSMBAsset) {} }
        let duration: TimeInterval
        if let knownDuration = source.duration {
            duration = knownDuration
        } else if let loadedDuration = try? await asset.load(.duration) {
            duration = loadedDuration.seconds
        } else {
            return nil
        }
        guard duration.isFinite, duration > 0.4 else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        let ratios = shuffledSampleRatios(seed: source.cacheKey)
        var bestCandidate: UIImage?
        var bestScore = -Double.infinity
        for ratio in ratios {
            guard !Task.isCancelled else { return nil }
            let seconds = min(max(duration * ratio, 0.15), duration - 0.15)
            guard seconds > 0 else { continue }
            do {
                let generated = try await generator.image(
                    at: CMTime(seconds: seconds, preferredTimescale: 600)
                )
                let candidateScore = score(generated.image)
                if candidateScore > bestScore {
                    bestScore = candidateScore
                    bestCandidate = UIImage(cgImage: generated.image)
                }
            } catch {
                continue
            }
        }

        guard let bestCandidate else {
            return nil
        }
        let optimized = optimizedCover(bestCandidate)
        _ = saveCachedImage(optimized, for: source.cacheKey)
        return optimized
    }

    /// 【MODIFIED】扫描完成后预热所有缺少来源封面的项目；逐个处理，避免同时占满 Apple TV 解码资源。
    @discardableResult
    static func prewarm(sources: [BabyPlayerCoverSource]) async -> Int {
        var readyCount = 0
        for source in sources where source.providerImageURL == nil {
            guard !Task.isCancelled else { return readyCount }
            if await generate(for: source) != nil {
                readyCount += 1
            }
        }
        return readyCount
    }

    /// 生成稳定的伪随机顺序，让同一视频每次都从同一组 5 个内部位置取样。
    private static func shuffledSampleRatios(seed: String) -> [Double] {
        var values = [0.12, 0.30, 0.50, 0.70, 0.88]
        var state: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            state ^= UInt64(byte)
            state &*= 1_099_511_628_211
        }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            let swapIndex = Int(state % UInt64(index + 1))
            values.swapAt(index, swapIndex)
        }
        return values
    }

    /// 用曝光、亮度变化和色彩信息给候选帧打分，尽量避开纯黑片头和过曝画面。
    private static func score(_ image: CGImage) -> Double {
        let width = 32
        let height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var luminances: [Double] = []
        var saturationTotal = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255.0
            let green = Double(pixels[index + 1]) / 255.0
            let blue = Double(pixels[index + 2]) / 255.0
            luminances.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
            saturationTotal += max(red, green, blue) - min(red, green, blue)
        }

        let average = luminances.reduce(0, +) / Double(luminances.count)
        let variance = luminances.reduce(0) { $0 + pow($1 - average, 2) } / Double(luminances.count)
        let exposureScore = max(0, 1 - abs(average - 0.48) / 0.48)
        let contrastScore = min(sqrt(variance) * 4.0, 1)
        let saturationScore = min((saturationTotal / Double(luminances.count)) * 2.0, 1)
        return exposureScore * 0.55 + contrastScore * 0.25 + saturationScore * 0.20
    }

    /// 从稳定内容 key 得到 SHA-256 文件名，避免来源路径直接出现在文件系统中。
    private static func filename(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined() + ".jpg"
    }

    /// 兼容 2026-08 版本的 FNV 文件名，只用于一次性读取迁移。
    private static func legacyFilename(for key: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx.jpg", hash)
    }

    private static func loadCachedImage(for source: BabyPlayerCoverSource) -> UIImage? {
        let currentURL = cacheDirectoryURL.appendingPathComponent(filename(for: source.cacheKey))
        if let image = UIImage(contentsOfFile: currentURL.path) {
            return image
        }

        var migrationURLs: [URL] = []
        if let legacyApplicationSupportDirectoryURL {
            migrationURLs.append(
                legacyApplicationSupportDirectoryURL.appendingPathComponent(
                    filename(for: source.cacheKey)
                )
            )
        }
        for legacyKey in source.legacyCacheKeys {
            migrationURLs.append(
                cacheDirectoryURL.appendingPathComponent(legacyFilename(for: legacyKey))
            )
            if let legacyApplicationSupportDirectoryURL {
                migrationURLs.append(
                    legacyApplicationSupportDirectoryURL.appendingPathComponent(
                        legacyFilename(for: legacyKey)
                    )
                )
            }
        }

        for legacyURL in migrationURLs {
            guard let legacyImage = UIImage(contentsOfFile: legacyURL.path) else { continue }
            let optimized = optimizedCover(legacyImage)
            if saveCachedImage(optimized, for: source.cacheKey) {
                try? FileManager.default.removeItem(at: legacyURL)
            }
            return optimized
        }
        return nil
    }

    /// 只在原子写入成功后返回 true，迁移时据此决定能否删除旧文件。
    @discardableResult
    private static func saveCachedImage(_ image: UIImage, for key: String) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.70) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectoryURL,
                withIntermediateDirectories: true
            )
            let url = cacheDirectoryURL.appendingPathComponent(filename(for: key))
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 卡片最终只保存一张 16:9 小图；五张候选不会写盘，也不会在评分后继续占内存。
    private static func optimizedCover(_ image: UIImage) -> UIImage {
        let target = CGSize(width: 640, height: 360)
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }
        let scale = max(target.width / sourceSize.width, target.height / sourceSize.height)
        let drawnSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(
            x: (target.width - drawnSize.width) / 2,
            y: (target.height - drawnSize.height) / 2
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: origin, size: drawnSize))
        }
    }

    #if DEBUG
    /// 真机验收只汇总数量、像素和字节，不打印媒体标题、来源路径或缓存文件名。
    static func debugCacheSummary() -> String {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "jpg" } ?? []
        var totalBytes = 0
        var dimensions = Set<String>()
        var sha256Names = 0
        for url in urls {
            totalBytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let image = UIImage(contentsOfFile: url.path) {
                dimensions.insert("\(Int(image.size.width))x\(Int(image.size.height))")
            }
            let stem = url.deletingPathExtension().lastPathComponent
            if stem.count == 64, stem.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
                sha256Names += 1
            }
        }
        return "count=\(urls.count) sha256=\(sha256Names) bytes=\(totalBytes) dimensions=\(dimensions.sorted().joined(separator: ","))"
    }
    #endif
}

/// 单张媒体卡片的封面状态；来源封面失败时自动切换到本地抽帧结果。
@MainActor
final class BabyPlayerCoverLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    private let source: BabyPlayerCoverSource?
    private var task: Task<Void, Never>?

    init(source: BabyPlayerCoverSource?) {
        self.source = source
    }

    /// 触发一次本地封面加载；重复调用不会重复启动抽帧任务。
    func load() {
        guard image == nil, !isLoading, let source else { return }
        isLoading = true
        task = Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                await BabyPlayerCoverGenerator.generate(for: source)
            }.value
            guard !Task.isCancelled else { return }
            self?.image = image
            self?.isLoading = false
        }
    }
}

/// 负责展示来源封面、抽帧封面或稳定占位图，不关心媒体来源类型。
struct MediaCoverView: View {
    let source: BabyPlayerCoverSource?
    let tint: Color
    @State private var providerFailed = false
    @StateObject private var loader: BabyPlayerCoverLoader

    init(source: BabyPlayerCoverSource?, tint: Color) {
        self.source = source
        self.tint = tint
        _loader = StateObject(wrappedValue: BabyPlayerCoverLoader(source: source))
    }

    var body: some View {
        Group {
            if let providerImageURL = source?.providerImageURL, !providerFailed {
                AsyncImage(url: providerImageURL) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        fallbackCover
                            .onAppear {
                                providerFailed = true
                                loader.load()
                            }
                    case .empty:
                        fallbackCover
                            .overlay { ProgressView().tint(.white) }
                    @unknown default:
                        fallbackCover
                    }
                }
            } else if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackCover
                    .overlay {
                        if loader.isLoading { ProgressView().tint(.white) }
                    }
                    .onAppear { loader.load() }
            }
        }
        .clipped()
    }

    private var fallbackCover: some View {
        ZStack {
            LinearGradient(
                colors: [tint.opacity(0.88), BabyPlayerPalette.berry.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(BabyPlayerPalette.sun.opacity(0.55))
                .frame(width: 78, height: 78)
                .offset(x: 82, y: -42)
            Image(systemName: "sparkles.tv.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
        }
    }
}
