"""用途：BabyPlayer 独立百度绑定 API。主要功能：设备配对、OAuth、Root Folder 选择与状态查询。最近修改：【MODIFIED】Phase 5 建立不依赖 tvOS 的版本化协议。"""

from datetime import datetime, timedelta, timezone
import os
import secrets
from urllib.parse import quote

from cryptography.fernet import Fernet, InvalidToken
from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from pydantic import BaseModel

from .baidu import BaiduError, BaiduGateway, BaiduTokens
from .store import MySQLStore


class RootChoice(BaseModel):
    """【MODIFIED】职责：校验手机端提交的单个 Root Folder；输出路径与百度 fs_id。"""

    path: str
    fs_id: int


def utcnow() -> datetime:
    """【MODIFIED】职责：返回无时区 UTC 时间，和 MySQL UTC_TIMESTAMP 比较。"""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def require_token(header: str | None, scheme: str) -> str:
    """【MODIFIED】职责：解析设备或配对认证头；输入指定 scheme，输出高熵令牌。"""
    prefix = f"{scheme} "
    if not header or not header.startswith(prefix) or len(header) <= len(prefix):
        raise HTTPException(401, "missing_token")
    return header[len(prefix):]


def normalized_path(raw: str) -> str:
    """【MODIFIED】职责：约束百度绝对目录路径；输入任意文本，输出规范路径或 400。"""
    if not raw.startswith("/") or "\x00" in raw or len(raw) > 2048:
        raise HTTPException(400, "invalid_path")
    parts = raw.split("/")
    if any(part in (".", "..") for part in parts) or "//" in raw:
        raise HTTPException(400, "invalid_path")
    return "/" if raw == "/" else raw.rstrip("/")


def within_root(path: str, root: str) -> bool:
    """【MODIFIED】职责：限制儿童端目录访问 Root Folder 以下；输入两条规范路径，输出边界判断。"""
    return root == "/" or path == root or path.startswith(root + "/")


def create_app(store, baidu: BaiduGateway, cipher: Fernet, api_origin: str, phone_origin: str) -> FastAPI:
    """【MODIFIED】职责：装配可注入的独立服务；输入存储/API/密钥，输出 FastAPI 应用。"""
    app = FastAPI(title="BabyPlayer Baidu Binding", version="1")
    app.add_middleware(CORSMiddleware, allow_origins=[phone_origin], allow_methods=["GET", "POST"],
                       allow_headers=["Authorization", "Content-Type"])

    def pair_record(authorization: str | None):
        """【MODIFIED】职责：验证短时配对令牌；输出有效配对记录。"""
        pair = store.pairing(require_token(authorization, "Pairing"))
        if pair is None or pair.get("completed_at") is not None:
            raise HTTPException(401, "pairing_expired")
        return pair

    def device_record(authorization: str | None):
        """【MODIFIED】职责：验证设备令牌；输出当前设备记录。"""
        device = store.device(require_token(authorization, "Bearer"))
        if device is None:
            raise HTTPException(401, "unknown_device")
        return device

    def access_for_binding(device_id: int, binding: dict) -> str:
        """【MODIFIED】职责：读取或刷新设备令牌；输出访问令牌，失效时抛 BaiduError。"""
        if binding["token_expires_at"] > utcnow() + timedelta(minutes=5):
            return cipher.decrypt(binding["access_cipher"]).decode()
        tokens = baidu.refresh(cipher.decrypt(binding["refresh_cipher"]).decode())
        expiry = utcnow() + timedelta(seconds=tokens.expires_in)
        store.update_binding_tokens(device_id, cipher.encrypt(tokens.access.encode()),
                                    cipher.encrypt(tokens.refresh.encode()), expiry)
        return tokens.access

    def folder_items(access: str, path: str) -> list[dict]:
        """【MODIFIED】职责：把百度原始目录转成跨平台文件夹模型；输出本目录的文件夹和视频。"""
        files = baidu.list_folder(access, path)
        return [{"id": str(item["fs_id"]), "name": item["server_filename"],
                 "path": item["path"], "kind": "folder" if item.get("isdir") == 1 else "video",
                 "size": item.get("size", 0)} for item in files
                if item.get("isdir") == 1 or str(item.get("server_filename", "")).lower().endswith(
                    (".mp4", ".m4v", ".mov", ".mkv", ".avi", ".ts", ".webm"))]

    @app.get("/health")
    def health():
        """【MODIFIED】职责：供现有 Hetzner 常驻服务健康探测；输出无凭证状态。"""
        return {"ok": True}

    @app.post("/v1/pairings")
    def create_pairing(authorization: str | None = Header(default=None)):
        """【MODIFIED】职责：给新或既有电视创建 15 分钟配对；仅首次返回设备令牌。"""
        device_token = None
        if authorization is None:
            device_token = secrets.token_urlsafe(32)
            device_id = store.create_device(device_token)
        else:
            device_id = device_record(authorization)["id"]
        pair = secrets.token_urlsafe(32)
        store.create_pairing(device_id, pair, cipher.encrypt(pair.encode()), utcnow() + timedelta(minutes=15))
        result = {"pairing_code": pair, "expires_in": 900,
                  "configuration_url": f"{phone_origin}/babyplayer/connect.html#pair={quote(pair)}"}
        if device_token is not None:
            result["device_token"] = device_token
        return result

    @app.get("/v1/pairings/me")
    def pairing_status(authorization: str | None = Header(default=None)):
        """【MODIFIED】职责：供手机确认 OAuth 进度；输出待授权/待选目录，不返回令牌。"""
        pair = pair_record(authorization)
        return {"status": "choose_root" if pair.get("access_cipher") else "awaiting_authorization"}

    @app.post("/v1/oauth/start")
    def oauth_start(authorization: str | None = Header(default=None)):
        """【MODIFIED】职责：为当前配对生成一次性 OAuth state；输出百度跳转 URL。"""
        pair_record(authorization)
        pair_token = require_token(authorization, "Pairing")
        state = secrets.token_urlsafe(32)
        store.set_oauth_state(pair_token, state)
        return {"authorization_url": baidu.authorization_url(state)}

    @app.get("/v1/oauth/callback")
    def oauth_callback(code: str = Query(min_length=1), state: str = Query(min_length=1)):
        """【MODIFIED】职责：校验 state、换令牌并存加密临时凭证；跳回私有手机页。"""
        pair = store.pairing_for_state(state)
        if pair is None:
            raise HTTPException(400, "invalid_oauth_state")
        try:
            tokens = baidu.exchange(code)
        except BaiduError as error:
            raise HTTPException(502, str(error)) from error
        expiry = utcnow() + timedelta(seconds=tokens.expires_in)
        saved = store.save_pair_tokens(pair["id"], state, cipher.encrypt(tokens.access.encode()),
                                       cipher.encrypt(tokens.refresh.encode()), expiry)
        if not saved:
            raise HTTPException(409, "oauth_state_used")
        pair_token = cipher.decrypt(pair["pair_cipher"]).decode()
        return RedirectResponse(f"{phone_origin}/babyplayer/connect.html#pair={quote(pair_token)}", status_code=303,
                                headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"})

    @app.get("/v1/pairings/folders")
    def pairing_folders(path: str = "/", authorization: str | None = Header(default=None)):
        """【MODIFIED】职责：授权后让手机逐层选目录；输出文件夹与视频，不暴露令牌。"""
        pair = pair_record(authorization)
        if not pair.get("access_cipher"):
            raise HTTPException(409, "authorization_required")
        path = normalized_path(path)
        try:
            return {"path": path, "items": folder_items(cipher.decrypt(pair["access_cipher"]).decode(), path)}
        except BaiduError as error:
            raise HTTPException(502, str(error)) from error

    @app.post("/v1/pairings/root")
    def choose_root(choice: RootChoice, authorization: str | None = Header(default=None)):
        """【MODIFIED】职责：验证选中项是网盘真目录，再原子保存单 Root Folder。"""
        pair = pair_record(authorization)
        if not pair.get("access_cipher"):
            raise HTTPException(409, "authorization_required")
        path = normalized_path(choice.path)
        if path == "/":
            valid = choice.fs_id == 0
        else:
            parent = path.rsplit("/", 1)[0] or "/"
            try:
                entries = baidu.list_folder(cipher.decrypt(pair["access_cipher"]).decode(), parent)
            except BaiduError as error:
                raise HTTPException(502, str(error)) from error
            valid = any(item.get("path") == path and item.get("isdir") == 1
                        and item.get("fs_id") == choice.fs_id for item in entries)
        if not valid:
            raise HTTPException(404, "root_folder_missing")
        if not store.save_binding(pair["id"], pair["device_id"], path, choice.fs_id):
            raise HTTPException(409, "pairing_completed")
        return {"status": "online", "root_folder": {"id": str(choice.fs_id), "path": path}}

    @app.get("/v1/devices/me")
    def device_status(authorization: str | None = Header(default=None)):
        """【MODIFIED】职责：供电视启动探测及恢复配置；输出三态与 Root Folder，不输出百度令牌。"""
        device_id = device_record(authorization)["id"]
        binding = store.binding(device_id)
        if binding is None:
            return {"source": "baidu", "status": "unconfigured", "root_folder": None}
        root = {"id": str(binding["root_fs_id"]), "path": binding["root_path"]}
        try:
            access = access_for_binding(device_id, binding)
            baidu.list_folder(access, binding["root_path"])
            return {"source": "baidu", "status": "online", "root_folder": root}
        except (BaiduError, InvalidToken) as error:
            reason = str(error) if isinstance(error, BaiduError) else "authorization_expired"
            return {"source": "baidu", "status": "offline", "reason": reason, "root_folder": root}

    @app.get("/v1/devices/folders")
    def device_folders(path: str, authorization: str | None = Header(default=None)):
        """【MODIFIED】职责：按设备 Root Folder 边界浏览；输出跨平台目录模型。"""
        device_id = device_record(authorization)["id"]
        binding = store.binding(device_id)
        if binding is None:
            raise HTTPException(409, "not_configured")
        path = normalized_path(path)
        if not within_root(path, binding["root_path"]):
            raise HTTPException(403, "outside_root_folder")
        try:
            return {"path": path, "items": folder_items(access_for_binding(device_id, binding), path)}
        except BaiduError as error:
            raise HTTPException(502, str(error)) from error

    return app


def production_app() -> FastAPI:
    """【MODIFIED】职责：从服务器环境装配 MySQL 与百度凭证；输出可由 Uvicorn 常驻运行的应用。"""
    required = ["BABYPLAYER_DB_USER", "BABYPLAYER_DB_PASSWORD", "BABYPLAYER_DB_NAME",
                "BABYPLAYER_BAIDU_CLIENT_ID", "BABYPLAYER_BAIDU_CLIENT_SECRET",
                "BABYPLAYER_BAIDU_REDIRECT_URI", "BABYPLAYER_PUBLIC_API_ORIGIN",
                "BABYPLAYER_PHONE_ORIGIN", "BABYPLAYER_TOKEN_FERNET_KEY"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise RuntimeError("Missing BabyPlayer environment: " + ", ".join(missing))
    store = MySQLStore(host=os.environ.get("BABYPLAYER_DB_HOST", "127.0.0.1"),
                       port=int(os.environ.get("BABYPLAYER_DB_PORT", "3306")),
                       user=os.environ["BABYPLAYER_DB_USER"], password=os.environ["BABYPLAYER_DB_PASSWORD"],
                       database=os.environ["BABYPLAYER_DB_NAME"], autocommit=False, charset="utf8mb4")
    baidu = BaiduGateway(os.environ["BABYPLAYER_BAIDU_CLIENT_ID"],
                         os.environ["BABYPLAYER_BAIDU_CLIENT_SECRET"],
                         os.environ["BABYPLAYER_BAIDU_REDIRECT_URI"])
    return create_app(store, baidu, Fernet(os.environ["BABYPLAYER_TOKEN_FERNET_KEY"].encode()),
                      os.environ["BABYPLAYER_PUBLIC_API_ORIGIN"].rstrip("/"),
                      os.environ["BABYPLAYER_PHONE_ORIGIN"].rstrip("/"))


# 【MODIFIED】职责：供 `uvicorn babyplayer_baidu.main:app` 启动；副作用仅初始化服务对象。
app = production_app() if os.environ.get("BABYPLAYER_DB_USER") else None
