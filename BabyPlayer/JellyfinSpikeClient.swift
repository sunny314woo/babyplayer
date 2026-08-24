//
// JellyfinSpikeClient.swift
// 用途：封装技术 Spike 所需的最小 Jellyfin HTTP API。
// 主要功能：服务器探测、Quick Connect、读取视频库和生成直放 URL。
// 最近修改：2026-08-24 接收 Jellyfin 本机 Path，供 Mac 本地歌词分析读取原视频。
//

import Foundation

// MARK: - Jellyfin wire models

/// Jellyfin 公共服务器信息；输入来自 `/System/Info/Public`，无共享状态副作用。
struct JellyfinPublicInfo: Decodable {
    let serverName: String
    let version: String
    let startupWizardCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case startupWizardCompleted = "StartupWizardCompleted"
    }
}

/// Quick Connect 请求状态；`secret` 仅保存在内存中，`code` 可显示给家长。
struct JellyfinQuickConnectResult: Decodable {
    let authenticated: Bool
    let secret: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case authenticated = "Authenticated"
        case secret = "Secret"
        case code = "Code"
    }
}

/// Quick Connect 换取访问令牌的请求体。
private struct JellyfinQuickConnectRequest: Encodable {
    let secret: String

    enum CodingKeys: String, CodingKey {
        case secret = "Secret"
    }
}

/// 已认证用户的最小字段集合。
struct JellyfinUser: Decodable {
    let id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

/// Quick Connect 认证结果；访问令牌不会被持久化或输出到日志。
struct JellyfinAuthenticationResult: Decodable {
    let user: JellyfinUser?
    let accessToken: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
    }
}

/// 视频媒体源的直放所需字段。
struct JellyfinMediaSource: Decodable {
    let id: String?
    let container: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case container = "Container"
    }
}

/// Jellyfin 章节标记；可在服务器已标注时识别片头和片尾。
struct JellyfinChapter: Decodable {
    let startPositionTicks: Int64
    let name: String

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
    }
}

/// 首页查询返回的最小视频模型。
struct JellyfinMediaItem: Decodable, Identifiable {
    let id: String
    let name: String
    let path: String?
    let collectionType: String?
    let artists: [String]?
    let runTimeTicks: Int64?
    let mediaSources: [JellyfinMediaSource]?
    let imageTags: [String: String]?
    let chapters: [JellyfinChapter]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case collectionType = "CollectionType"
        case artists = "Artists"
        case runTimeTicks = "RunTimeTicks"
        case mediaSources = "MediaSources"
        case imageTags = "ImageTags"
        case chapters = "Chapters"
    }
}

/// Jellyfin 列表查询响应。
private struct JellyfinItemsResponse: Decodable {
    let items: [JellyfinMediaItem]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

/// Jellyfin 后台任务状态，用于等待媒体库扫描结束。
private struct JellyfinScheduledTask: Decodable {
    let key: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case key = "Key"
        case state = "State"
    }
}

/// Spike 可显示的普通错误；不会泄漏服务器响应正文或访问令牌。
enum JellyfinSpikeError: LocalizedError {
    case invalidServerAddress
    case unsupportedServerScheme
    case invalidResponse
    case httpStatus(Int)
    case quickConnectDisabled
    case incompleteAuthentication
    case musicVideoLibraryNotFound
    case noVideo
    case unsupportedMedia

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            return "服务器地址不正确"
        case .unsupportedServerScheme:
            return "服务器地址只支持 http 或 https"
        case .invalidResponse:
            return "Jellyfin 返回了无法识别的数据"
        case let .httpStatus(status):
            return "Jellyfin 请求失败（HTTP \(status)）"
        case .quickConnectDisabled:
            return "服务器未开启 Quick Connect"
        case .incompleteAuthentication:
            return "配对已批准，但没有取得完整授权"
        case .musicVideoLibraryNotFound:
            return "Jellyfin 中没有找到“音乐视频”媒体库"
        case .noVideo:
            return "媒体库中还没有可用视频"
        case .unsupportedMedia:
            return "第一条视频暂时无法直放"
        }
    }
}

// MARK: - Minimal API client

/// Spike 专用 Jellyfin 客户端；实例绑定一个服务器与设备标识，不持久化用户令牌。
struct JellyfinSpikeClient {
    private let serverURL: URL
    private let deviceID: String
    private let session: URLSession

    /// 建立客户端；`serverAddress` 可省略协议，输出为经过校验的局域网服务器 URL。
    init(serverAddress: String, deviceID: String, session: URLSession = .shared) throws {
        let trimmedAddress = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressWithScheme = trimmedAddress.contains("://") ? trimmedAddress : "http://\(trimmedAddress)"

        guard var components = URLComponents(string: addressWithScheme), components.host != nil else {
            throw JellyfinSpikeError.invalidServerAddress
        }
        guard components.scheme == "http" || components.scheme == "https" else {
            throw JellyfinSpikeError.unsupportedServerScheme
        }

        components.query = nil
        components.fragment = nil
        guard let normalizedURL = components.url else {
            throw JellyfinSpikeError.invalidServerAddress
        }

        self.serverURL = normalizedURL
        self.deviceID = deviceID
        self.session = session
    }

    /// 读取服务器公开信息；无认证要求，失败时抛出可展示错误。
    func fetchPublicInfo() async throws -> JellyfinPublicInfo {
        try await send(path: "System/Info/Public")
    }

    /// 检查 Quick Connect 开关；输出 `true` 表示可以发起配对。
    func isQuickConnectEnabled() async throws -> Bool {
        try await send(path: "QuickConnect/Enabled")
    }

    /// 【MODIFIED】发起真实 Quick Connect；输出包含家长可批准的数字码和内存 secret。
    func initiateQuickConnect() async throws -> JellyfinQuickConnectResult {
        try await send(path: "QuickConnect/Initiate", method: "POST")
    }

    /// 轮询指定 Quick Connect secret；只读取授权状态，不改变本地共享状态。
    func fetchQuickConnectState(secret: String) async throws -> JellyfinQuickConnectResult {
        try await send(
            path: "QuickConnect/Connect",
            queryItems: [URLQueryItem(name: "secret", value: secret)]
        )
    }

    /// 使用已批准的 secret 换取用户与访问令牌；令牌仅由调用方在内存持有。
    func authenticateWithQuickConnect(secret: String) async throws -> JellyfinAuthenticationResult {
        let body = try JSONEncoder().encode(JellyfinQuickConnectRequest(secret: secret))
        return try await send(
            path: "Users/AuthenticateWithQuickConnect",
            method: "POST",
            body: body
        )
    }

    /// 查询“音乐视频”媒体库；其它 Jellyfin 媒体库不会混入 BabyPlayer。
    func fetchVideos(userID: String, accessToken: String) async throws -> [JellyfinMediaItem] {
        let views: JellyfinItemsResponse = try await send(
            path: "UserViews",
            queryItems: [URLQueryItem(name: "userId", value: userID)],
            accessToken: accessToken
        )
        guard let musicVideoLibrary = views.items.first(where: {
            $0.collectionType?.caseInsensitiveCompare("musicvideos") == .orderedSame
        }) ?? views.items.first(where: {
            $0.name.caseInsensitiveCompare("音乐视频") == .orderedSame
        }) else {
            throw JellyfinSpikeError.musicVideoLibraryNotFound
        }

        let response: JellyfinItemsResponse = try await send(
            path: "Items",
            queryItems: [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "parentId", value: musicVideoLibrary.id),
                URLQueryItem(name: "recursive", value: "true"),
                URLQueryItem(name: "includeItemTypes", value: "Video,MusicVideo"),
                URLQueryItem(name: "mediaTypes", value: "Video"),
                // 【MODIFIED】同时请求 ImageTags，避免服务器已有封面因字段缺失被误判为无封面。
                URLQueryItem(name: "fields", value: "MediaSources,Path,Chapters,Artists,ImageTags"),
                URLQueryItem(name: "sortBy", value: "SortName"),
                URLQueryItem(name: "sortOrder", value: "Ascending"),
                URLQueryItem(name: "limit", value: "200")
            ],
            accessToken: accessToken
        )

        guard !response.items.isEmpty else {
            throw JellyfinSpikeError.noVideo
        }
        return response.items
    }

    /// 保留 Spike 的单视频调用语义，供首条视频快捷播放使用。
    func fetchFirstVideo(userID: String, accessToken: String) async throws -> JellyfinMediaItem {
        try await fetchVideos(userID: userID, accessToken: accessToken).first ?? {
            throw JellyfinSpikeError.noVideo
        }()
    }

    /// 【MODIFIED】生成 AVPlayer 可直接请求的 Jellyfin 静态视频 URL；访问令牌只存在 URL 内存值中。
    func directPlaybackURL(for item: JellyfinMediaItem, accessToken: String) throws -> URL {
        guard let source = item.mediaSources?.first, let sourceID = source.id else {
            throw JellyfinSpikeError.unsupportedMedia
        }

        let allowedContainerCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let rawContainer = source.container?.lowercased() ?? "mp4"
        let sanitizedContainer = rawContainer.unicodeScalars.allSatisfy(allowedContainerCharacters.contains)
            ? rawContainer
            : "mp4"

        return try endpointURL(
            path: "Videos/\(item.id)/stream.\(sanitizedContainer)",
            queryItems: [
                URLQueryItem(name: "static", value: "true"),
                URLQueryItem(name: "mediaSourceId", value: sourceID),
                URLQueryItem(name: "api_key", value: accessToken)
            ]
        )
    }

    /// 生成带认证的 Jellyfin 横版封面 URL；无封面时返回 nil，由 UI 显示占位图。
    func primaryImageURL(for item: JellyfinMediaItem, accessToken: String, maxWidth: Int = 620) -> URL? {
        guard let tag = item.imageTags?["Primary"] else { return nil }
        return try? endpointURL(
            path: "Items/\(item.id)/Images/Primary",
            queryItems: [
                URLQueryItem(name: "maxWidth", value: String(maxWidth)),
                URLQueryItem(name: "quality", value: "88"),
                URLQueryItem(name: "tag", value: tag),
                URLQueryItem(name: "api_key", value: accessToken)
            ]
        )
    }

    /// 触发 Jellyfin 完整媒体库扫描，会检测新增、移动和已删除的文件。
    func startLibraryScan(accessToken: String) async throws {
        try await sendWithoutResponse(
            path: "Library/Refresh",
            method: "POST",
            accessToken: accessToken
        )
    }

    /// 读取后台任务；返回 true 表示媒体库扫描仍在运行。
    func isLibraryScanRunning(accessToken: String) async throws -> Bool {
        let tasks: [JellyfinScheduledTask] = try await send(
            path: "ScheduledTasks",
            accessToken: accessToken
        )
        return tasks.contains {
            $0.key.caseInsensitiveCompare("RefreshLibrary") == .orderedSame
                && $0.state.caseInsensitiveCompare("Running") == .orderedSame
        }
    }

    /// 执行并解码一个 Jellyfin 请求；副作用仅为网络访问，不记录请求正文或令牌。
    private func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        accessToken: String? = nil
    ) async throws -> Response {
        let url = try endpointURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(accessToken: accessToken), forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinSpikeError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw JellyfinSpikeError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw JellyfinSpikeError.invalidResponse
        }
    }

    /// 执行不返回 JSON 正文的 Jellyfin 操作（例如开始扫描）。
    private func sendWithoutResponse(
        path: String,
        method: String,
        accessToken: String
    ) async throws {
        let url = try endpointURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader(accessToken: accessToken), forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinSpikeError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw JellyfinSpikeError.httpStatus(httpResponse.statusCode)
        }
    }

    /// 拼接服务器路径与查询参数；不访问网络，也不修改服务器 URL。
    private func endpointURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let endpoint = serverURL.appendingPathComponent(path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw JellyfinSpikeError.invalidServerAddress
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw JellyfinSpikeError.invalidServerAddress
        }
        return url
    }

    /// 生成 Jellyfin 客户端身份头；有令牌时仅用于当前请求，不写入磁盘或日志。
    private func authorizationHeader(accessToken: String?) -> String {
        var fields = [
            "Client=\"BabyPlayer\"",
            "Device=\"Apple TV\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"0.1.0-spike\""
        ]
        if let accessToken {
            fields.append("Token=\"\(accessToken)\"")
        }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }
}
