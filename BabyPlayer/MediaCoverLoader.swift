//
// MediaCoverLoader.swift
// 用途：提供与媒体来源无关的视频封面加载和生成能力。
// 主要功能：来源封面优先；没有来源封面时从视频内部抽取 5 帧并选择较合适的一帧，结果缓存在本地。
// 最近修改：2026-08-22 增加跨媒体源的封面兜底和扫描后的后台预热。
//

import AVFoundation
import SwiftUI
import UIKit

/// 媒体源交给封面层的最小输入；来源可以是 Jellyfin、U 盘或 NAS。
struct BabyPlayerCoverSource: @unchecked Sendable {
    let providerImageURL: URL?
    let videoURL: URL?
    let smbPlaybackResource: SMBPlaybackResource?
    let duration: TimeInterval?
    let cacheKey: String

    var viewIdentity: String {
        "\(cacheKey)|\(providerImageURL != nil)|\(videoURL != nil)|\(smbPlaybackResource != nil)"
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
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent("BabyPlayer/Covers", isDirectory: true)
    }()

    /// 【MODIFIED】为无来源封面的媒体生成本地封面；扫描后可后台调用，卡片首次显示时也可调用。
    static func generate(for source: BabyPlayerCoverSource) async -> UIImage? {
        if let cachedImage = loadCachedImage(for: source.cacheKey) {
            return cachedImage
        }
        return await BabyPlayerCoverGenerationCoordinator.shared.generate(for: source)
    }

    fileprivate static func generateUncached(for source: BabyPlayerCoverSource) async -> UIImage? {
        if let cachedImage = loadCachedImage(for: source.cacheKey) {
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
        generator.maximumSize = CGSize(width: 800, height: 450)

        let ratios = shuffledSampleRatios(seed: source.cacheKey)
        var candidates: [(UIImage, Double)] = []
        for ratio in ratios {
            guard !Task.isCancelled else { return nil }
            let seconds = min(max(duration * ratio, 0.15), duration - 0.15)
            guard seconds > 0 else { continue }
            do {
                let generated = try await generator.image(
                    at: CMTime(seconds: seconds, preferredTimescale: 600)
                )
                candidates.append((UIImage(cgImage: generated.image), score(generated.image)))
            } catch {
                continue
            }
        }

        guard let bestCandidate = candidates.max(by: { $0.1 < $1.1 })?.0 else {
            return nil
        }
        saveCachedImage(bestCandidate, for: source.cacheKey)
        return bestCandidate
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

    /// 从稳定 key 得到文件名，避免媒体源 ID 直接出现在文件系统路径中。
    private static func filename(for key: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx.jpg", hash)
    }

    private static func loadCachedImage(for key: String) -> UIImage? {
        let url = cacheDirectoryURL.appendingPathComponent(filename(for: key))
        return UIImage(contentsOfFile: url.path)
    }

    private static func saveCachedImage(_ image: UIImage, for key: String) {
        guard let data = image.jpegData(compressionQuality: 0.86) else { return }
        try? FileManager.default.createDirectory(
            at: cacheDirectoryURL,
            withIntermediateDirectories: true
        )
        let url = cacheDirectoryURL.appendingPathComponent(filename(for: key))
        try? data.write(to: url, options: .atomic)
    }
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
