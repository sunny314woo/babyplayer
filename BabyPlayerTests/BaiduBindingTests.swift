// 用途：验证 Apple TV 与 BabyPlayer 百度绑定服务之间的 JSON 协议。
// 主要功能：保护设备三态、Root Folder 和配对二维码字段的跨平台兼容性。
// 最近修改：【MODIFIED】Phase 5 增加真实 API 响应结构的解码回归测试。

import Foundation
import XCTest
@testable import BabyPlayer

/// 【MODIFIED】职责：验证版本化百度绑定协议的稳定字段；输入模拟 API JSON，输出解码断言。
final class BaiduBindingTests: XCTestCase {
    /// 【MODIFIED】职责：覆盖未配置、离线、在线三态及 Root Folder 恢复。
    func testDeviceStatusStatesAndRootFolder() throws {
        let decoder = JSONDecoder()
        let unconfigured = try decoder.decode(BaiduDeviceStatus.self, from: Data(#"{"source":"baidu","status":"unconfigured","root_folder":null}"#.utf8))
        XCTAssertEqual(unconfigured.status, "unconfigured")
        XCTAssertNil(unconfigured.rootFolder)

        let offline = try decoder.decode(BaiduDeviceStatus.self, from: Data(#"{"source":"baidu","status":"offline","reason":"authorization_expired","root_folder":{"id":"42","path":"/Kids"}}"#.utf8))
        XCTAssertEqual(offline.reason, "authorization_expired")
        XCTAssertEqual(offline.rootFolder?.path, "/Kids")

        let online = try decoder.decode(BaiduDeviceStatus.self, from: Data(#"{"source":"baidu","status":"online","root_folder":{"id":"42","path":"/Kids"}}"#.utf8))
        XCTAssertEqual(online.rootFolder?.id, "42")
    }

    /// 【MODIFIED】职责：验证首次配对令牌与限时 HTTPS 配置链接可解码。
    func testPairingContract() throws {
        let data = Data(#"{"pairing_code":"short-lived","configuration_url":"https://wisteriasoftware.uk/babyplayer/connect.html#pair=short-lived","expires_in":900,"device_token":"device-only"}"#.utf8)
        let pairing = try JSONDecoder().decode(BaiduPairing.self, from: data)
        XCTAssertEqual(pairing.expiresIn, 900)
        XCTAssertEqual(pairing.configurationURL.scheme, "https")
        XCTAssertEqual(pairing.deviceToken, "device-only")
    }
}
