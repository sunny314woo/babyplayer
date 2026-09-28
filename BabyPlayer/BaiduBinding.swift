// 用途：Apple TV 与独立 BabyPlayer 百度绑定 API 通信。
// 主要功能：设备令牌安全保存、扫码配对、授权状态恢复和二维码展示。
// 最近修改：【MODIFIED】绑定完成后自动返回原页面，避免电视停留在扫码页。

import CoreImage.CIFilterBuiltins
import Foundation
import Security
import SwiftUI

/// 【MODIFIED】职责：承载跨平台设备状态协议；输入 API JSON，输出授权与 Root Folder 状态。
struct BaiduDeviceStatus: Decodable, Equatable {
    /// 【MODIFIED】职责：保存服务端 Root Folder；输入稳定 id/path，输出儿童目录边界标识。
    struct RootFolder: Decodable, Equatable {
        let id: String
        let path: String
    }

    let source: String
    let status: String
    let reason: String?
    let rootFolder: RootFolder?

    enum CodingKeys: String, CodingKey {
        case source, status, reason
        case rootFolder = "root_folder"
    }
}

/// 【MODIFIED】职责：承载 15 分钟配对结果；输入 API JSON，输出二维码链接和首次设备令牌。
struct BaiduPairing: Decodable, Equatable {
    let pairingCode: String
    let configurationURL: URL
    let expiresIn: Int
    let deviceToken: String?

    enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case configurationURL = "configuration_url"
        case expiresIn = "expires_in"
        case deviceToken = "device_token"
    }
}

/// 【MODIFIED】职责：隔离 HTTP 与 Keychain；不会在电视保存百度 App Secret 或 refresh token。
enum BaiduBindingClient {
    static let apiBase = URL(string: "https://babyplayer-api.wisteriasoftware.uk")!
    private static let service = "com.wufengyu.BabyPlayer.baidu-device"
    private static let account = "primary"

    /// 【MODIFIED】职责：查询已保存的设备令牌；输出令牌或 nil，不写日志。
    static func savedDeviceToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 【MODIFIED】职责：首次绑定后在当前设备 Keychain 保存高熵令牌；副作用仅限专属条目。
    static func saveDeviceToken(_ token: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(token.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(added))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// 【MODIFIED】职责：向独立服务发送带设备令牌的请求；输入路径/方法，输出可解码响应。
    private static func request<T: Decodable>(_ path: String, method: String = "GET", token: String?) async throws -> T {
        var urlRequest = URLRequest(url: apiBase.appendingPathComponent(path))
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 【MODIFIED】职责：探测已绑定百度账号及 Root Folder；输入 Keychain 令牌，输出三态或 nil。
    static func deviceStatus() async throws -> BaiduDeviceStatus? {
        guard let token = savedDeviceToken() else { return nil }
        return try await request("v1/devices/me", token: token)
    }

    /// 【MODIFIED】职责：为当前电视创建一次配对；首次令牌写入 Keychain，输出限时手机链接。
    static func createPairing() async throws -> BaiduPairing {
        let pairing: BaiduPairing = try await request("v1/pairings", method: "POST", token: savedDeviceToken())
        if let token = pairing.deviceToken {
            try saveDeviceToken(token)
        }
        return pairing
    }
}

/// 【MODIFIED】职责：维护家长页的百度绑定进度；输入用户扫码操作，输出界面状态。
@MainActor
final class BaiduBindingViewModel: ObservableObject {
    @Published private(set) var deviceStatus: BaiduDeviceStatus?
    @Published private(set) var pairing: BaiduPairing?
    @Published private(set) var statusText = "正在检查百度连接…"
    @Published private(set) var isWorking = false
    // 【MODIFIED】职责：只标记本次扫码完成，不把启动时恢复的既有在线状态当作新绑定。
    @Published private(set) var bindingCompleted = false

    /// 【MODIFIED】职责：恢复已有绑定；网络错误保持可重试，不清除设备令牌。
    func refreshStatus() async {
        do {
            deviceStatus = try await BaiduBindingClient.deviceStatus()
            if let deviceStatus {
                switch deviceStatus.status {
                case "online": statusText = "已连接 · 根目录 \(deviceStatus.rootFolder?.path ?? "/")"
                case "offline": statusText = "已配置但暂时不可用 · \(deviceStatus.reason ?? "请重试")"
                default: statusText = "尚未连接百度网盘"
                }
            } else {
                statusText = "尚未连接百度网盘"
            }
        } catch {
            statusText = "授权服务暂时不可用，请稍后重试"
        }
    }

    /// 【MODIFIED】职责：生成当前电视专属的短时二维码；副作用为创建服务端配对。
    func beginPairing() async {
        guard !isWorking else { return }
        bindingCompleted = false
        isWorking = true
        defer { isWorking = false }
        do {
            pairing = try await BaiduBindingClient.createPairing()
            statusText = "请用手机扫码授权并选择根目录。二维码 15 分钟内有效。"
        } catch {
            statusText = "无法生成二维码，请检查网络后重试"
        }
    }

    /// 【MODIFIED】职责：扫码后定时确认手机是否完成授权；输出最新状态，无跨来源切换副作用。
    func pollUntilBound() async {
        while !Task.isCancelled, pairing != nil {
            await refreshStatus()
            if deviceStatus?.status == "online" {
                // 【MODIFIED】通知当前扫码页面自动返回；已有绑定的状态刷新不会触发。
                bindingCompleted = true
                pairing = nil
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// 【MODIFIED】职责：把服务器生成的手机配置链接显示为二维码；只展示当前配对，不处理百度令牌。
struct BaiduConnectionView: View {
    @ObservedObject var model: BaiduBindingViewModel
    let close: () -> Void
    private let qrContext = CIContext()

    var body: some View {
        ZStack {
            OrchardBackground()
            VStack(spacing: 24) {
                HStack {
                    Text("连接百度网盘")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                    Spacer()
                    Button("返回", action: close)
                        .buttonStyle(.borderedProminent)
                        .tint(BabyPlayerPalette.berry)
                }
                Text(model.statusText)
                    .font(.system(size: 25))
                    .foregroundStyle(BabyPlayerPalette.muted)
                if let pairing = model.pairing, let image = qrImage(for: pairing.configurationURL) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 350, height: 350)
                        .padding(20)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20))
                    Text("手机浏览器扫码后，授权百度账号并选择儿童根目录")
                        .font(.system(size: 22))
                    Button("重新生成二维码") { Task { await model.beginPairing() } }
                        .buttonStyle(.borderedProminent)
                        .tint(BabyPlayerPalette.coral)
                } else {
                    Button(model.deviceStatus?.status == "online" ? "更换目录或重新授权" : "生成扫码二维码") {
                        Task { await model.beginPairing() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BabyPlayerPalette.leaf)
                    .disabled(model.isWorking)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .task { await model.refreshStatus() }
        .task(id: model.pairing?.pairingCode) {
            if model.pairing != nil { await model.pollUntilBound() }
        }
        // 【MODIFIED】手机保存 Root Folder 后关闭扫码页，交还来源选择或家长设置。
        .onChange(of: model.bindingCompleted) { _, completed in
            if completed { close() }
        }
    }

    /// 【MODIFIED】职责：在设备本地把短时 HTTPS 配置链接编码为二维码；输出 UIImage，不调用网络。
    private func qrImage(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = qrContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
