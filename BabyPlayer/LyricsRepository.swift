//
// LyricsRepository.swift
// BabyPlayer 歌词候选、本地绑定和时间偏移。
//

import Foundation

struct LyricsMediaDescriptor: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let searchTitle: String
    let artistName: String?
    let sourceHint: String?
    let versionHint: String?
    let durationSeconds: Double?
    let songStartSeconds: Double?
    let songEndSeconds: Double?
    let mediaSourceID: String?

    /// 有 Jellyfin 章节或家长设置时，用真正的歌曲段时长代替整段 MP4 时长。
    var expectedSongDurationSeconds: Double? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let start = min(durationSeconds, max(0, songStartSeconds ?? 0))
        let end = min(durationSeconds, max(start, songEndSeconds ?? durationSeconds))
        let result = end - start
        return result > 0 ? result : nil
    }

    var hasSongBoundaryHint: Bool {
        songStartSeconds != nil || songEndSeconds != nil
    }
}

/// 只从文件名/Jellyfin 标题提取候选线索，不把文件名当成最终识别结果。
struct LyricsTitleMetadata: Equatable, Sendable {
    let searchTitle: String
    let sourceHint: String?
    let versionHint: String?

    static func parse(_ rawTitle: String) -> LyricsTitleMetadata {
        let folded = rawTitle.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let compact = folded.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()

        let sourceHint: String?
        if compact.contains("supersimplesongs") || compact.contains("supersimple")
            || containsStandaloneTag("sss", in: folded) {
            sourceHint = "Super Simple Songs"
        } else if compact.contains("babybus") || folded.contains("宝宝巴士") {
            sourceHint = "BabyBus"
        } else {
            sourceHint = nil
        }

        let versionRules: [(String, String)] = [
            (#"(?i)\bkaraoke\b"#, "Karaoke"),
            (#"(?i)\bsing[\s_-]*along\b"#, "Sing Along"),
            (#"(?i)\blive\b"#, "Live"),
            (#"(?i)\bremix\b"#, "Remix"),
            (#"(?i)\bofficial(?:\s+(?:music\s+)?video)?\b"#, "Official")
        ]
        let versionHint = versionRules.first(where: { matches($0.0, in: rawTitle) })?.1

        var title = replacing(#"^\s*\d+[\s._-]*"#, in: rawTitle, with: "")
        // 只删除包含已知来源/版本/清晰度的括号，保留真正属于歌名的括号。
        title = replacing(
            #"(?i)\s*[\[\(\uff08\u3010][^\]\)\uff09\u3011]*(?:super\s*simple(?:\s*songs)?|\bsss\b|baby\s*bus|\u5b9d\u5b9d\u5df4\u58eb|official|karaoke|sing[\s_-]*along|lyrics?|music\s*video|\bmv\b|\b(?:4k|8k|\d{3,4}p)\b)[^\]\)\uff09\u3011]*[\]\)\uff09\u3011]\s*"#,
            in: title,
            with: " "
        )
        title = replacing(#"(?i)\bsuper\s*simple(?:\s*songs)?\b"#, in: title, with: " ")
        title = replacing(#"(?i)\bbaby\s*bus\b|宝宝巴士"#, in: title, with: " ")
        title = replacing(#"(?i)(?:\s+[-\u2013\u2014|]\s+)(?:official(?:\s+(?:music\s+)?video)?|karaoke|sing[\s_-]*along|lyrics?|kids?|\bmv\b).*$"#, in: title, with: "")
        title = replacing(#"(?i)\b(?:4k|8k|\d{3,4}p)\b"#, in: title, with: " ")
        title = replacing(#"(?i)\.(?:mp4|m4v|mkv|mov|webm)$"#, in: title, with: "")
        title = replacing(#"[_]+"#, in: title, with: " ")
        title = replacing(#"\s{2,}"#, in: title, with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-|–—")))

        return LyricsTitleMetadata(
            searchTitle: title.isEmpty ? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines) : title,
            sourceHint: sourceHint,
            versionHint: versionHint
        )
    }

    private static func containsStandaloneTag(_ tag: String, in text: String) -> Bool {
        matches("(?i)(?:^|[^a-z0-9])\(tag)(?:$|[^a-z0-9])", in: text)
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}

struct TimedLyricLine: Codable, Sendable {
    let time: Double
    let text: String
}

struct LyricsCandidate: Codable, Identifiable, Sendable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double
    let lines: [TimedLyricLine]
    let matchScore: Double
    let providerName: String?

    var previewText: String {
        lines.prefix(2).map(\.text).joined(separator: "  ·  ")
    }

    var matchPercentage: Int {
        Int(max(0, min(100, 100 - matchScore)).rounded())
    }
}

struct LyricsBinding: Codable, Identifiable, Sendable {
    var id: String { mediaID }

    let mediaID: String
    let mediaFingerprint: String
    let mediaSourceID: String?
    let mediaTitle: String
    let sourceCandidateID: Int
    let sourceTrackName: String
    let sourceArtistName: String
    let sourceDuration: Double
    let lines: [TimedLyricLine]
    var offsetSeconds: Double
    let confirmedAt: Date
    var updatedAt: Date
}

struct LyricsPlayback: Sendable {
    static let maximumOffsetSeconds: Double = 600

    let candidateID: Int
    let trackName: String
    let artistName: String
    let sourceDuration: Double
    let lines: [TimedLyricLine]
    var offsetSeconds: Double
    var isConfirmed: Bool
}

enum BabyLyricsError: LocalizedError {
    case noSyncedLyrics
    case invalidServerResponse

    var errorDescription: String? {
        switch self {
        case .noSyncedLyrics:
            return "没有找到带时间轴的歌词"
        case .invalidServerResponse:
            return "在线歌词服务暂时不可用"
        }
    }
}

private struct LRCLibTrack: Decodable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double
    let instrumental: Bool
    let syncedLyrics: String?
}

private struct BundledLyricsCatalog: Decodable {
    let tracks: [BundledLyricsTrack]
}

/// 可由家长在构建 App 前填充的已授权本地曲目；不依赖 AI 或运行时抓取。
private struct BundledLyricsTrack: Decodable {
    let id: Int
    let trackID: String
    let title: String
    let aliases: [String]
    let artist: String
    let source: String?
    let version: String?
    let duration: Double?
    let syncedLyrics: String?
}

/// 未确认候选位于 Caches；家长确认的绑定位于 Application Support。
actor BabyLyricsRepository {
    static let shared = BabyLyricsRepository()

    private let fileManager = FileManager.default
    private var candidateMemoryCache: [String: [LyricsCandidate]] = [:]
    private var bindingMemoryCache: [String: LyricsBinding?] = [:]
    private var bundledCatalogCache: [BundledLyricsTrack]?

    func resolvedLyrics(for media: LyricsMediaDescriptor) async throws -> LyricsPlayback? {
        if let binding = binding(for: media) {
            return playback(from: binding)
        }

        let candidates = try await searchCandidates(for: media)
        return resolvedLyrics(for: media, candidates: candidates)
    }

    func storedLyrics(for media: LyricsMediaDescriptor) -> LyricsPlayback? {
        binding(for: media).map(playback(from:))
    }

    func resolvedLyrics(
        for media: LyricsMediaDescriptor,
        candidates: [LyricsCandidate]
    ) -> LyricsPlayback? {
        if let binding = binding(for: media) {
            return playback(from: binding)
        }

        // 候选已按确定性匹配分和 ID 排序；首次直接绑定第 1 个。
        // 之后家长选择第 2/3 个时会覆盖这份绑定。
        guard let candidate = candidates.first else { return nil }
        let playback = LyricsPlayback(
            candidateID: candidate.id,
            trackName: candidate.trackName,
            artistName: candidate.artistName,
            sourceDuration: candidate.duration,
            lines: candidate.lines,
            offsetSeconds: media.songStartSeconds ?? 0,
            isConfirmed: true
        )
        _ = try? confirm(playback, for: media)
        return playback
    }

    func searchCandidates(
        for media: LyricsMediaDescriptor,
        forceRefresh: Bool = false
    ) async throws -> [LyricsCandidate] {
        let key = mediaFingerprint(for: media)
        if !forceRefresh {
            if let cached = candidateMemoryCache[key] { return cached }
            if let cached = try? loadCandidatesFromDisk(key: key) {
                candidateMemoryCache[key] = cached
                return cached
            }
        }

        let catalogTracks = bundledCatalogMatches(for: media)
        let artist = media.artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceHint = media.sourceHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let simplifiedTitle = simplifiedSearchTitle(media.searchTitle)
        var queries: [(title: String, artist: String?)] = [(media.searchTitle, artist)]
        if let sourceHint, !sourceHint.isEmpty,
           normalized(sourceHint) != normalized(artist ?? "") {
            queries.append((media.searchTitle, sourceHint))
        }
        if artist?.isEmpty == false {
            // Jellyfin 的演唱者信息有时来自专辑或文件标签；再搜一次歌名可避免错误标签漏掉结果。
            queries.append((media.searchTitle, nil))
        }
        if normalized(simplifiedTitle) != normalized(media.searchTitle) {
            queries.append((simplifiedTitle, nil))
        }
        queries.append(contentsOf: catalogTracks.map { ($0.title, $0.artist) })
        queries = uniqueQueries(queries)

        var tracks: [LRCLibTrack] = []
        var lastError: Error?
        var receivedValidResponse = false
        for query in queries {
            do {
                tracks.append(contentsOf: try await fetchTracks(
                    title: query.title,
                    artist: query.artist
                ))
                receivedValidResponse = true
            } catch {
                lastError = error
            }
        }
        let wantedTitle = normalized(media.searchTitle)
        let bundledCandidates = catalogTracks.compactMap { track -> LyricsCandidate? in
            guard track.id < 0,
                  let syncedLyrics = track.syncedLyrics,
                  !syncedLyrics.isEmpty else { return nil }
            let lines = parseSyncedLyrics(syncedLyrics)
            guard !lines.isEmpty else { return nil }
            let duration = track.duration ?? lines.last?.time ?? 0
            guard duration > 0 else { return nil }
            return LyricsCandidate(
                id: track.id,
                trackName: track.title,
                artistName: track.artist,
                albumName: track.source,
                duration: duration,
                lines: lines,
                matchScore: score(
                    trackName: track.title,
                    artistName: track.artist,
                    albumName: track.source,
                    duration: duration,
                    wantedTitle: wantedTitle,
                    media: media
                ),
                providerName: "内置曲目库"
            )
        }
        if tracks.isEmpty, bundledCandidates.isEmpty,
           !receivedValidResponse, let lastError { throw lastError }

        let onlineCandidates = tracks.compactMap { track -> LyricsCandidate? in
            guard !track.instrumental,
                  let syncedLyrics = track.syncedLyrics,
                  !syncedLyrics.isEmpty else { return nil }
            let lines = parseSyncedLyrics(syncedLyrics)
            guard !lines.isEmpty else { return nil }
            return LyricsCandidate(
                id: track.id,
                trackName: track.trackName,
                artistName: track.artistName,
                albumName: track.albumName,
                duration: track.duration,
                lines: lines,
                matchScore: score(track, wantedTitle: wantedTitle, media: media),
                providerName: "LRCLIB"
            )
        }

        let candidates = (bundledCandidates + onlineCandidates)
        .sorted {
            if $0.matchScore == $1.matchScore { return $0.id < $1.id }
            return $0.matchScore < $1.matchScore
        }

        let uniqueCandidates = Array(
            Dictionary(grouping: candidates, by: \.id)
                .compactMap { $0.value.first }
                .sorted {
                    if $0.matchScore == $1.matchScore { return $0.id < $1.id }
                    return $0.matchScore < $1.matchScore
                }
                .prefix(12)
        )
        guard !uniqueCandidates.isEmpty else { throw BabyLyricsError.noSyncedLyrics }
        candidateMemoryCache[key] = uniqueCandidates
        try? saveCandidatesToDisk(uniqueCandidates, key: key)
        return uniqueCandidates
    }

    private func fetchTracks(title: String, artist: String?) async throws -> [LRCLibTrack] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        var queryItems = [URLQueryItem(name: "track_name", value: title)]
        if let artist, !artist.isEmpty {
            queryItems.append(URLQueryItem(name: "artist_name", value: artist))
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw BabyLyricsError.invalidServerResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("BabyPlayer/0.4 (tvOS; LRCLIB lyrics selection)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BabyLyricsError.invalidServerResponse
        }
        return try JSONDecoder().decode([LRCLibTrack].self, from: data)
    }

    func binding(for media: LyricsMediaDescriptor) -> LyricsBinding? {
        if let cached = bindingMemoryCache[media.id] { return cached }
        if let exact = try? loadBindingFromDisk(mediaID: media.id) {
            bindingMemoryCache[media.id] = exact
            return exact
        }

        // Jellyfin 重建条目时 ID 可能变化；标题、演唱者和时长均一致时恢复原绑定。
        if let fallback = try? loadAllBindings().first(where: { stored in
            let sourceMatches = media.mediaSourceID.map { $0 == stored.mediaSourceID } ?? false
            return sourceMatches
                || stored.mediaFingerprint == mediaFingerprint(for: media)
                || stored.mediaFingerprint == legacyMediaFingerprint(for: media)
        }) {
            let migrated = LyricsBinding(
                mediaID: media.id,
                mediaFingerprint: fallback.mediaFingerprint,
                mediaSourceID: media.mediaSourceID,
                mediaTitle: media.title,
                sourceCandidateID: fallback.sourceCandidateID,
                sourceTrackName: fallback.sourceTrackName,
                sourceArtistName: fallback.sourceArtistName,
                sourceDuration: fallback.sourceDuration,
                lines: fallback.lines,
                offsetSeconds: fallback.offsetSeconds,
                confirmedAt: fallback.confirmedAt,
                updatedAt: Date()
            )
            try? saveBindingToDisk(migrated)
            bindingMemoryCache[media.id] = migrated
            return migrated
        }

        bindingMemoryCache[media.id] = nil
        return nil
    }

    func bindings(for mediaItems: [LyricsMediaDescriptor]) -> [String: LyricsBinding] {
        Dictionary(uniqueKeysWithValues: mediaItems.compactMap { media in
            binding(for: media).map { (media.id, $0) }
        })
    }

    @discardableResult
    func confirm(_ candidate: LyricsCandidate, for media: LyricsMediaDescriptor) throws -> LyricsBinding {
        let binding = LyricsBinding(
            mediaID: media.id,
            mediaFingerprint: mediaFingerprint(for: media),
            mediaSourceID: media.mediaSourceID,
            mediaTitle: media.title,
            sourceCandidateID: candidate.id,
            sourceTrackName: candidate.trackName,
            sourceArtistName: candidate.artistName,
            sourceDuration: candidate.duration,
            lines: candidate.lines,
            offsetSeconds: 0,
            confirmedAt: Date(),
            updatedAt: Date()
        )
        try saveBindingToDisk(binding)
        bindingMemoryCache[media.id] = binding
        return binding
    }

    @discardableResult
    func confirm(_ playback: LyricsPlayback, for media: LyricsMediaDescriptor) throws -> LyricsBinding {
        let existing = binding(for: media)
        let binding = LyricsBinding(
            mediaID: media.id,
            mediaFingerprint: mediaFingerprint(for: media),
            mediaSourceID: media.mediaSourceID,
            mediaTitle: media.title,
            sourceCandidateID: playback.candidateID,
            sourceTrackName: playback.trackName,
            sourceArtistName: playback.artistName,
            sourceDuration: playback.sourceDuration,
            lines: playback.lines,
            offsetSeconds: playback.offsetSeconds,
            confirmedAt: existing?.confirmedAt ?? Date(),
            updatedAt: Date()
        )
        try saveBindingToDisk(binding)
        bindingMemoryCache[media.id] = binding
        return binding
    }

    @discardableResult
    func updateOffset(
        for media: LyricsMediaDescriptor,
        offsetSeconds: Double
    ) throws -> LyricsBinding? {
        guard var binding = binding(for: media) else { return nil }
        binding.offsetSeconds = min(
            LyricsPlayback.maximumOffsetSeconds,
            max(-LyricsPlayback.maximumOffsetSeconds, offsetSeconds)
        )
        binding.updatedAt = Date()
        try saveBindingToDisk(binding)
        bindingMemoryCache[media.id] = binding
        return binding
    }

    func removeBinding(for media: LyricsMediaDescriptor) throws {
        let root = try bindingsRoot(createDirectory: false)
        if fileManager.fileExists(atPath: root.path) {
            let fingerprint = mediaFingerprint(for: media)
            let legacyFingerprint = legacyMediaFingerprint(for: media)
            let urls = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for url in urls where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let stored = try? JSONDecoder().decode(LyricsBinding.self, from: data) else { continue }
                let sourceMatches = media.mediaSourceID.map { $0 == stored.mediaSourceID } ?? false
                guard stored.mediaID == media.id
                        || sourceMatches
                        || stored.mediaFingerprint == fingerprint
                        || stored.mediaFingerprint == legacyFingerprint else { continue }
                try fileManager.removeItem(at: url)
                bindingMemoryCache[stored.mediaID] = nil
            }
        }
        bindingMemoryCache[media.id] = nil
    }

    private func playback(from binding: LyricsBinding) -> LyricsPlayback {
        LyricsPlayback(
            candidateID: binding.sourceCandidateID,
            trackName: binding.sourceTrackName,
            artistName: binding.sourceArtistName,
            sourceDuration: binding.sourceDuration,
            lines: binding.lines,
            offsetSeconds: binding.offsetSeconds,
            isConfirmed: true
        )
    }

    private func score(
        _ track: LRCLibTrack,
        wantedTitle: String,
        media: LyricsMediaDescriptor
    ) -> Double {
        score(
            trackName: track.trackName,
            artistName: track.artistName,
            albumName: track.albumName,
            duration: track.duration,
            wantedTitle: wantedTitle,
            media: media
        )
    }

    private func score(
        trackName: String,
        artistName: String,
        albumName: String?,
        duration: Double,
        wantedTitle: String,
        media: LyricsMediaDescriptor
    ) -> Double {
        let candidateTitle = normalized(trackName)
        let titlePenalty: Double
        if candidateTitle == wantedTitle {
            titlePenalty = 0
        } else if candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) {
            titlePenalty = 30
        } else {
            titlePenalty = 150
        }

        // 文件名中明确的 [SSS]/[宝宝巴士] 比 Jellyfin 可能误填的专辑艺人更可信。
        let wantedArtist = (media.sourceHint ?? media.artistName).map(normalized) ?? ""
        let candidateArtist = normalized(artistName)
        let artistPenalty: Double
        if wantedArtist.isEmpty {
            artistPenalty = 0
        } else if candidateArtist == wantedArtist {
            artistPenalty = 0
        } else if candidateArtist.contains(wantedArtist) || wantedArtist.contains(candidateArtist) {
            artistPenalty = 12
        } else {
            artistPenalty = 45
        }

        let versionPenalty: Double
        if let version = media.versionHint, version != "Official" {
            let candidateVersionText = normalized("\(trackName) \(albumName ?? "")")
            versionPenalty = candidateVersionText.contains(normalized(version)) ? 0 : 35
        } else {
            versionPenalty = 0
        }

        let durationPenalty: Double
        if let expectedDuration = media.expectedSongDurationSeconds {
            let difference = duration - expectedDuration
            // 未标记边界时，MP4 比歌曲长很可能只是多了片头片尾，因此降低这一方向的惩罚。
            let multiplier = !media.hasSongBoundaryHint && difference < 0 ? 0.45 : 1.6
            durationPenalty = min(90, abs(difference) * multiplier)
        } else {
            durationPenalty = 0
        }
        return titlePenalty + artistPenalty + versionPenalty + durationPenalty
    }

    private func bundledCatalogMatches(for media: LyricsMediaDescriptor) -> [BundledLyricsTrack] {
        let wantedTitle = normalized(media.searchTitle)
        return bundledCatalog().filter { track in
            let titles = [track.title] + track.aliases
            let titleMatches = titles.map(normalized).contains { candidate in
                candidate == wantedTitle
                    || candidate.contains(wantedTitle)
                    || wantedTitle.contains(candidate)
            }
            guard titleMatches else { return false }

            if let sourceHint = media.sourceHint {
                let wantedSource = normalized(sourceHint)
                let availableSource = normalized(track.source ?? track.artist)
                guard availableSource == wantedSource
                        || availableSource.contains(wantedSource)
                        || wantedSource.contains(availableSource) else { return false }
            }
            if let versionHint = media.versionHint,
               versionHint != "Official",
               normalized(track.version ?? "") != normalized(versionHint) {
                return false
            }
            return true
        }
    }

    private func bundledCatalog() -> [BundledLyricsTrack] {
        if let bundledCatalogCache { return bundledCatalogCache }
        guard let url = Bundle.main.url(forResource: "BabyLyricsCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(BundledLyricsCatalog.self, from: data) else {
            bundledCatalogCache = []
            return []
        }
        bundledCatalogCache = catalog.tracks
        return catalog.tracks
    }

    private func uniqueQueries(
        _ queries: [(title: String, artist: String?)]
    ) -> [(title: String, artist: String?)] {
        var seen = Set<String>()
        return queries.filter { query in
            let key = "\(normalized(query.title))|\(normalized(query.artist ?? ""))"
            return seen.insert(key).inserted
        }
    }

    private func parseSyncedLyrics(_ lyrics: String) -> [TimedLyricLine] {
        let pattern = #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return lyrics.components(separatedBy: .newlines).compactMap { row in
            let fullRange = NSRange(row.startIndex..<row.endIndex, in: row)
            guard let match = regex.firstMatch(in: row, range: fullRange),
                  let minuteRange = Range(match.range(at: 1), in: row),
                  let secondRange = Range(match.range(at: 2), in: row),
                  let textRange = Range(match.range(at: 3), in: row),
                  let minutes = Double(row[minuteRange]),
                  let seconds = Double(row[secondRange]) else { return nil }
            let text = row[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimedLyricLine(time: minutes * 60 + seconds, text: text)
        }
        .sorted { $0.time < $1.time }
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    private func simplifiedSearchTitle(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*[\(\[（【].*?[\)\]）】]\s*"#,
            with: " ",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\s+[-–—]\s+(official|lyrics?|karaoke|sing[ -]?along|kids?).*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mediaFingerprint(for media: LyricsMediaDescriptor) -> String {
        let duration = Int((media.durationSeconds ?? 0).rounded())
        let source = normalized(media.sourceHint ?? "")
        let version = normalized(media.versionHint ?? "")
        return "\(normalized(media.searchTitle))|\(normalized(media.artistName ?? ""))|\(source)|\(version)|\(duration)"
    }

    /// 兼容 0.4 及更早版本保存的三段式指纹。
    private func legacyMediaFingerprint(for media: LyricsMediaDescriptor) -> String {
        let duration = Int((media.durationSeconds ?? 0).rounded())
        let legacyTitle = media.title.replacingOccurrences(
            of: #"^\s*\d+[\s._-]*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(normalized(legacyTitle))|\(normalized(media.artistName ?? ""))|\(duration)"
    }

    private func safeFileName(_ raw: String) -> String {
        Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func candidatesRoot() throws -> URL {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BabyPlayerLyrics", isDirectory: true)
            .appendingPathComponent("Candidates-v2", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func bindingsRoot(createDirectory: Bool = true) throws -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BabyPlayerLyrics", isDirectory: true)
            .appendingPathComponent("Bindings", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func candidateURL(key: String) throws -> URL {
        try candidatesRoot().appendingPathComponent(safeFileName(key)).appendingPathExtension("json")
    }

    private func bindingURL(mediaID: String, createDirectory: Bool = true) throws -> URL {
        try bindingsRoot(createDirectory: createDirectory)
            .appendingPathComponent(safeFileName(mediaID))
            .appendingPathExtension("json")
    }

    private func loadCandidatesFromDisk(key: String) throws -> [LyricsCandidate] {
        let data = try Data(contentsOf: candidateURL(key: key))
        return try JSONDecoder().decode([LyricsCandidate].self, from: data)
    }

    private func saveCandidatesToDisk(_ candidates: [LyricsCandidate], key: String) throws {
        let data = try JSONEncoder().encode(candidates)
        try data.write(to: candidateURL(key: key), options: .atomic)
    }

    private func loadBindingFromDisk(mediaID: String) throws -> LyricsBinding {
        let data = try Data(contentsOf: bindingURL(mediaID: mediaID, createDirectory: false))
        return try JSONDecoder().decode(LyricsBinding.self, from: data)
    }

    private func loadAllBindings() throws -> [LyricsBinding] {
        let root = try bindingsRoot(createDirectory: false)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(LyricsBinding.self, from: data)
        }
    }

    private func saveBindingToDisk(_ binding: LyricsBinding) throws {
        let data = try JSONEncoder().encode(binding)
        try data.write(to: bindingURL(mediaID: binding.mediaID), options: .atomic)
    }
}
