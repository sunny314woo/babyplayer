//
// BabyPlayerLyricsRefiner.swift
// 兼容旧工程文件引用的歌词 Refiner 占位实现；冻结版本 B 下禁止任何 LLM 网络调用。
// 主要功能：
// 1. 保留 BabyPlayerLyricsRefinerClient 类型，避免为停用功能改动 Xcode 工程结构。
// 2. 所有 refine 调用立即返回 notConfigured，确保歌词匹配只走本地确定性算法。
// 最近修改：2026-08-23 【MODIFIED】停用 DeepSeek/LLM 歌词纠正，保留最小兼容壳。
//

import Foundation

/// 【MODIFIED】兼容旧调用点，但绝不读取额外 Secret、绝不发送歌词或 ASR 文本到 LLM。
struct BabyPlayerLyricsRefinerClient {
    /// 创建无网络能力的兼容客户端。
    /// - Parameter session: 仅保留旧初始化签名；不会保存或使用。
    /// - Side effects: 无网络请求、无全局状态修改。
    init(session: URLSession = .shared) throws {
        _ = session
    }

    /// 【MODIFIED】冻结版本 B 明确禁止 LLM；调用时立即交回本地确定性匹配链路。
    /// - Parameters:
    ///   - analysis: 腾讯 ASR 结果，仅为保持旧签名。
    ///   - candidates: 本地歌词候选，仅为保持旧签名。
    ///   - reference: 可选纯文本歌本，仅为保持旧签名。
    ///   - mediaFingerprint: 媒体指纹，仅为保持旧签名。
    /// - Returns: 不返回歌词候选。
    /// - Side effects: 无；固定抛出 `BabyPlayerASRError.notConfigured`。
    func refine(
        analysis: BabyPlayerASRAnalysis,
        candidates: [LyricsCandidate],
        reference: LyricsPlainTextReference?,
        mediaFingerprint: String
    ) async throws -> LyricsCandidate {
        _ = analysis
        _ = candidates
        _ = reference
        _ = mediaFingerprint
        throw BabyPlayerASRError.notConfigured
    }
}
