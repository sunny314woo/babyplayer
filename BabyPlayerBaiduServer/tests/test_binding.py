"""用途：验证百度设备绑定状态机。主要功能：覆盖授权恢复、Root 边界、失效与独立设备。最近修改：【MODIFIED】Phase 5 添加不需真实百度凭证的服务测试。"""

from datetime import timedelta
import os
import sys

from cryptography.fernet import Fernet
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from babyplayer_baidu.baidu import BaiduError, BaiduTokens  # noqa: E402
from babyplayer_baidu.main import create_app, utcnow  # noqa: E402
from babyplayer_baidu.store import token_hash  # noqa: E402


class MemoryStore:
    """【MODIFIED】职责：模拟 MySQL 业务行为；输入 API 调用，输出可断言的持久化状态。"""

    def __init__(self):
        """【MODIFIED】职责：初始化隔离的设备、配对及绑定表。"""
        self.devices = {}
        self.pairs = {}
        self.bindings = {}

    def device(self, token):
        """【MODIFIED】职责：按令牌摘要查设备；输出设备 ID。"""
        return self.devices.get(token_hash(token))

    def create_device(self, token):
        """【MODIFIED】职责：新增模拟设备；输出 ID。"""
        row = {"id": len(self.devices) + 1}
        self.devices[token_hash(token)] = row
        return row["id"]

    def create_pairing(self, device_id, pair, pair_cipher, expiry):
        """【MODIFIED】职责：新增配对及其加密回跳令牌。"""
        self.pairs[token_hash(pair)] = {"id": len(self.pairs) + 1, "device_id": device_id,
                                        "pair_cipher": pair_cipher, "expires_at": expiry,
                                        "completed_at": None, "oauth_state_hash": None,
                                        "access_cipher": None, "refresh_cipher": None}

    def pairing(self, pair):
        """【MODIFIED】职责：仅返回尚未过期配对。"""
        row = self.pairs.get(token_hash(pair))
        return row if row and row["expires_at"] > utcnow() else None

    def set_oauth_state(self, pair, state):
        """【MODIFIED】职责：记录本次授权 state 并清除旧临时令牌。"""
        row = self.pairing(pair)
        row.update(oauth_state_hash=token_hash(state), access_cipher=None, refresh_cipher=None)

    def pairing_for_state(self, state):
        """【MODIFIED】职责：按 state 摘要找未消费配对。"""
        return next((row for row in self.pairs.values() if row["oauth_state_hash"] == token_hash(state)
                     and row["expires_at"] > utcnow() and row["completed_at"] is None), None)

    def save_pair_tokens(self, pairing_id, state, access, refresh, expiry):
        """【MODIFIED】职责：单次消费 state 并存加密令牌；输出成功与否。"""
        row = self.pairing_for_state(state)
        if row is None or row["id"] != pairing_id:
            return False
        row.update(oauth_state_hash=None, access_cipher=access, refresh_cipher=refresh,
                   token_expires_at=expiry)
        return True

    def binding(self, device_id):
        """【MODIFIED】职责：按设备读取单一绑定。"""
        return self.bindings.get(device_id)

    def save_binding(self, pairing_id, device_id, path, fs_id):
        """【MODIFIED】职责：把配对临时授权和 Root Folder 原子转为设备绑定。"""
        row = next((value for value in self.pairs.values() if value["id"] == pairing_id), None)
        if not row or row["completed_at"] or not row["access_cipher"]:
            return False
        self.bindings[device_id] = {"access_cipher": row["access_cipher"],
                                    "refresh_cipher": row["refresh_cipher"],
                                    "token_expires_at": row["token_expires_at"],
                                    "root_path": path, "root_fs_id": fs_id}
        row.update(completed_at=utcnow(), access_cipher=None, refresh_cipher=None)
        return True

    def update_binding_tokens(self, device_id, access, refresh, expiry):
        """【MODIFIED】职责：保存续期后令牌。"""
        self.bindings[device_id].update(access_cipher=access, refresh_cipher=refresh,
                                        token_expires_at=expiry)


class FakeBaidu:
    """【MODIFIED】职责：模拟官方 OAuth 和目录 API；可切换断线/授权失效/目录删除。"""

    def __init__(self):
        """【MODIFIED】职责：建立两层目录及视频元数据。"""
        self.error = None
        self.folders = {
            "/": [{"fs_id": 12, "path": "/Kids", "server_filename": "Kids", "isdir": 1}],
            "/Kids": [{"fs_id": 13, "path": "/Kids/Shows", "server_filename": "Shows", "isdir": 1},
                      {"fs_id": 14, "path": "/Kids/a.mp4", "server_filename": "a.mp4", "isdir": 0}],
            "/Kids/Shows": [{"fs_id": 15, "path": "/Kids/Shows/b.mp4", "server_filename": "b.mp4", "isdir": 0}],
        }

    def authorization_url(self, state):
        """【MODIFIED】职责：返回可在测试里解析的模拟授权地址。"""
        return "https://example.test/authorize?state=" + state

    def exchange(self, code):
        """【MODIFIED】职责：模拟授权码换令牌。"""
        return BaiduTokens("access", "refresh", 3600)

    def refresh(self, token):
        """【MODIFIED】职责：模拟成功或失效的续期。"""
        if self.error == "authorization_expired":
            raise BaiduError(self.error)
        return BaiduTokens("new-access", "new-refresh", 3600)

    def list_folder(self, access, path):
        """【MODIFIED】职责：读取模拟目录，支持断线及目录删除。"""
        if self.error:
            raise BaiduError(self.error)
        if path not in self.folders:
            raise BaiduError("folder_unavailable")
        return self.folders[path]


def setup():
    """【MODIFIED】职责：装配隔离测试客户端；输出客户端、存储、网关和加密器。"""
    store, baidu, cipher = MemoryStore(), FakeBaidu(), Fernet(Fernet.generate_key())
    app = create_app(store, baidu, cipher, "https://api.example.test", "https://site.example.test")
    return TestClient(app), store, baidu, cipher


def bound_device(client):
    """【MODIFIED】职责：走真实 HTTP 路由完成设备、OAuth 与目录选择；输出设备令牌。"""
    created = client.post("/v1/pairings").json()
    pair = created["pairing_code"]
    pair_headers = {"Authorization": "Pairing " + pair}
    auth_url = client.post("/v1/oauth/start", headers=pair_headers).json()["authorization_url"]
    state = auth_url.split("state=")[1]
    callback = client.get("/v1/oauth/callback", params={"code": "code", "state": state}, follow_redirects=False)
    assert callback.status_code == 303
    assert callback.headers["location"].endswith("#pair=" + pair)
    assert client.get("/v1/pairings/me", headers=pair_headers).json()["status"] == "choose_root"
    assert client.post("/v1/pairings/root", headers=pair_headers,
                       json={"path": "/Kids", "fs_id": 12}).status_code == 200
    return created["device_token"]


def test_pairing_oauth_root_and_restore():
    """【MODIFIED】职责：验证授权回跳、Root 持久化及重新启动状态恢复。"""
    client, store, _, _ = setup()
    token = bound_device(client)
    headers = {"Authorization": "Bearer " + token}
    assert client.get("/v1/devices/me", headers=headers).json() == {
        "source": "baidu", "status": "online", "root_folder": {"id": "12", "path": "/Kids"}}
    assert client.get("/v1/devices/folders", headers=headers, params={"path": "/Kids/Shows"}).json()["items"][0]["name"] == "b.mp4"
    assert len(store.bindings) == 1


def test_root_boundary_and_invalid_root():
    """【MODIFIED】职责：阻止儿童越过 Root，并拒绝手机伪造目录。"""
    client, _, _, _ = setup()
    created = client.post("/v1/pairings").json()
    headers = {"Authorization": "Pairing " + created["pairing_code"]}
    assert client.post("/v1/pairings/root", headers=headers, json={"path": "/Kids", "fs_id": 12}).status_code == 409
    state = client.post("/v1/oauth/start", headers=headers).json()["authorization_url"].split("state=")[1]
    client.get("/v1/oauth/callback", params={"code": "x", "state": state})
    assert client.post("/v1/pairings/root", headers=headers, json={"path": "/Kids", "fs_id": 999}).status_code == 404
    assert client.post("/v1/pairings/root", headers=headers, json={"path": "/Kids", "fs_id": 12}).status_code == 200
    device_headers = {"Authorization": "Bearer " + created["device_token"]}
    assert client.get("/v1/devices/folders", headers=device_headers, params={"path": "/"}).status_code == 403
    assert client.get("/v1/devices/folders", headers=device_headers, params={"path": "/Kids/../"}).status_code == 400


def test_unconfigured_offline_expired_and_deleted_root():
    """【MODIFIED】职责：覆盖未配置、断网、续期失效及 Root 被删除。"""
    client, store, baidu, _ = setup()
    created = client.post("/v1/pairings").json()
    headers = {"Authorization": "Bearer " + created["device_token"]}
    assert client.get("/v1/devices/me", headers=headers).json()["status"] == "unconfigured"
    token = bound_device(client)
    headers = {"Authorization": "Bearer " + token}
    baidu.error = "drive_unavailable"
    assert client.get("/v1/devices/me", headers=headers).json()["status"] == "offline"
    baidu.error = None
    baidu.folders.pop("/Kids")
    assert client.get("/v1/devices/me", headers=headers).json()["reason"] == "folder_unavailable"
    baidu.error = "authorization_expired"
    device_id = store.device(token)["id"]
    store.bindings[device_id]["token_expires_at"] = utcnow() - timedelta(seconds=1)
    assert client.get("/v1/devices/me", headers=headers).json()["reason"] == "authorization_expired"


def test_pairing_expiry_and_device_isolation():
    """【MODIFIED】职责：验证短时链接过期和多设备之间不共享目录。"""
    client, store, _, _ = setup()
    first = bound_device(client)
    second = client.post("/v1/pairings").json()
    assert client.get("/v1/devices/me", headers={"Authorization": "Bearer " + second["device_token"]}).json()["status"] == "unconfigured"
    pair = second["pairing_code"]
    store.pairs[token_hash(pair)]["expires_at"] = utcnow() - timedelta(seconds=1)
    assert client.get("/v1/pairings/me", headers={"Authorization": "Pairing " + pair}).status_code == 401
    assert first != second["device_token"]


def test_oauth_state_is_single_use_and_tokens_stay_server_side():
    """【MODIFIED】职责：拒绝重放 OAuth 回调，确保设备状态响应不包含百度凭证。"""
    client, store, _, _ = setup()
    created = client.post("/v1/pairings").json()
    pair = created["pairing_code"]
    headers = {"Authorization": "Pairing " + pair}
    state = client.post("/v1/oauth/start", headers=headers).json()["authorization_url"].split("state=")[1]
    callback = {"code": "once", "state": state}
    assert client.get("/v1/oauth/callback", params=callback, follow_redirects=False).status_code == 303
    assert client.get("/v1/oauth/callback", params=callback, follow_redirects=False).status_code == 400
    assert store.pairing(pair)["access_cipher"] != b"access"
    result = client.get("/v1/devices/me", headers={"Authorization": "Bearer " + created["device_token"]})
    assert "access" not in result.text and "refresh" not in result.text
