"""用途：隔离百度 OAuth 与网盘目录 API。主要功能：换令牌、续期及读取目录。最近修改：【MODIFIED】Phase 5 首次加入可替换的 HTTP 网关。"""

from dataclasses import dataclass
from urllib.parse import urlencode

import httpx


@dataclass(frozen=True)
class BaiduTokens:
    """【MODIFIED】职责：承载服务端令牌及到期秒数；输出仅供服务端存储。"""

    access: str
    refresh: str
    expires_in: int


class BaiduError(Exception):
    """【MODIFIED】职责：将百度 API 错误隔离于 HTTP 层；输入错误类别，输出可控异常。"""


class BaiduGateway:
    """【MODIFIED】职责：调用百度官方 OAuth 与文件列表 API；凭证绝不返回 TV。"""

    def __init__(self, client_id: str, client_secret: str, redirect_uri: str, client: httpx.Client | None = None):
        """【MODIFIED】职责：接收服务端应用凭证及可注入 HTTP 客户端；无持久化副作用。"""
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        self.client = client or httpx.Client(timeout=15, follow_redirects=False)

    def authorization_url(self, state: str) -> str:
        """【MODIFIED】职责：生成带 CSRF state 的百度授权 URL；输出网页跳转地址。"""
        query = urlencode({
            "response_type": "code", "client_id": self.client_id,
            "redirect_uri": self.redirect_uri, "scope": "basic,netdisk", "state": state,
        })
        return f"https://openapi.baidu.com/oauth/2.0/authorize?{query}"

    def exchange(self, code: str) -> BaiduTokens:
        """【MODIFIED】职责：服务端交换单次授权码；输出令牌，错误时抛出 BaiduError。"""
        return self._token({"grant_type": "authorization_code", "code": code, "redirect_uri": self.redirect_uri})

    def refresh(self, refresh_token: str) -> BaiduTokens:
        """【MODIFIED】职责：服务端续期令牌；输入旧 refresh token，输出新令牌。"""
        return self._token({"grant_type": "refresh_token", "refresh_token": refresh_token})

    def _token(self, params: dict[str, str]) -> BaiduTokens:
        """【MODIFIED】职责：统一调用 OAuth token 端点；不记录或输出 Secret。"""
        try:
            response = self.client.get("https://openapi.baidu.com/oauth/2.0/token", params={
                **params, "client_id": self.client_id, "client_secret": self.client_secret,
            })
            response.raise_for_status()
            data = response.json()
        except (httpx.HTTPError, ValueError) as error:
            raise BaiduError("oauth_unavailable") from error
        if "access_token" not in data or "refresh_token" not in data:
            raise BaiduError("authorization_expired")
        return BaiduTokens(data["access_token"], data["refresh_token"], int(data.get("expires_in", 0)))

    def list_folder(self, access_token: str, path: str) -> list[dict]:
        """【MODIFIED】职责：分页读取一个网盘目录；输入令牌与绝对路径，输出原始文件元数据。"""
        files: list[dict] = []
        for start in range(0, 100_000, 1000):
            try:
                response = self.client.get("https://pan.baidu.com/rest/2.0/xpan/file", params={
                    "method": "list", "access_token": access_token, "dir": path,
                    "start": start, "limit": 1000,
                })
                response.raise_for_status()
                data = response.json()
            except (httpx.HTTPError, ValueError) as error:
                raise BaiduError("drive_unavailable") from error
            if data.get("errno") != 0:
                raise BaiduError("authorization_expired" if data.get("errno") in (-6, 111) else "folder_unavailable")
            page = data.get("list", [])
            if not isinstance(page, list):
                raise BaiduError("invalid_file_list")
            files.extend(page)
            if len(page) < 1000:
                return files
        raise BaiduError("folder_too_large")
