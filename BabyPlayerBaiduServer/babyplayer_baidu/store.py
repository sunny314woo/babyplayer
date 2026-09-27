"""用途：持久化独立设备绑定数据。主要功能：用 pymysql 原生 SQL 管理设备、短时配对和单 Root Folder。最近修改：【MODIFIED】Phase 5 建立独立 MySQL 存储。"""

from contextlib import contextmanager
from datetime import datetime
import hashlib

import pymysql


def token_hash(token: str) -> str:
    """【MODIFIED】职责：只保存高熵设备及配对令牌的 SHA-256 摘要；输出十六进制摘要。"""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class MySQLStore:
    """【MODIFIED】职责：执行参数化原生 SQL；每个方法独立提交，避免 ORM 与跨产品数据库耦合。"""

    def __init__(self, **connection_settings):
        """【MODIFIED】职责：接收独立 BabyPlayer 数据库连接参数；不立即连接。"""
        self.connection_settings = connection_settings

    @contextmanager
    def _cursor(self):
        """【MODIFIED】职责：提供字典游标和事务边界；输出游标并提交或回滚。"""
        connection = pymysql.connect(**self.connection_settings, cursorclass=pymysql.cursors.DictCursor)
        try:
            with connection.cursor() as cursor:
                yield cursor
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def device(self, token: str):
        """【MODIFIED】职责：按摘要读取设备；输入原始高熵令牌，输出设备 ID 或 None。"""
        with self._cursor() as cursor:
            cursor.execute("SELECT id FROM bp_devices WHERE token_hash=%s", (token_hash(token),))
            return cursor.fetchone()

    def create_device(self, token: str) -> int:
        """【MODIFIED】职责：保存新设备摘要；输出新设备 ID。"""
        with self._cursor() as cursor:
            cursor.execute("INSERT INTO bp_devices (token_hash) VALUES (%s)", (token_hash(token),))
            return cursor.lastrowid

    def create_pairing(self, device_id: int, pair: str, pair_cipher: bytes, expiry: datetime) -> None:
        """【MODIFIED】职责：创建有时限的独立配对；副作用为新增配对行。"""
        with self._cursor() as cursor:
            cursor.execute("INSERT INTO bp_pairings (device_id,pair_hash,pair_cipher,expires_at) VALUES (%s,%s,%s,%s)",
                           (device_id, token_hash(pair), pair_cipher, expiry.replace(tzinfo=None)))

    def pairing(self, pair: str):
        """【MODIFIED】职责：只读取尚未过期配对；输出数据库记录或 None。"""
        with self._cursor() as cursor:
            cursor.execute("SELECT * FROM bp_pairings WHERE pair_hash=%s AND expires_at>UTC_TIMESTAMP(6)", (token_hash(pair),))
            return cursor.fetchone()

    def set_oauth_state(self, pair: str, state: str) -> None:
        """【MODIFIED】职责：把一次性 OAuth state 摘要绑定配对；副作用为清除旧授权临时令牌。"""
        with self._cursor() as cursor:
            cursor.execute("UPDATE bp_pairings SET oauth_state_hash=%s,access_cipher=NULL,refresh_cipher=NULL,token_expires_at=NULL WHERE pair_hash=%s AND expires_at>UTC_TIMESTAMP(6) AND completed_at IS NULL",
                           (token_hash(state), token_hash(pair)))

    def pairing_for_state(self, state: str):
        """【MODIFIED】职责：按 OAuth state 摘要查有效配对；输出记录或 None。"""
        with self._cursor() as cursor:
            cursor.execute("SELECT * FROM bp_pairings WHERE oauth_state_hash=%s AND expires_at>UTC_TIMESTAMP(6) AND completed_at IS NULL", (token_hash(state),))
            return cursor.fetchone()

    def save_pair_tokens(self, pairing_id: int, state: str, access: bytes, refresh: bytes, expiry: datetime) -> bool:
        """【MODIFIED】职责：单次消费 OAuth state 并加密保存临时令牌；输出是否成功。"""
        with self._cursor() as cursor:
            cursor.execute("UPDATE bp_pairings SET oauth_state_hash=NULL,access_cipher=%s,refresh_cipher=%s,token_expires_at=%s WHERE id=%s AND oauth_state_hash=%s AND completed_at IS NULL",
                           (access, refresh, expiry.replace(tzinfo=None), pairing_id, token_hash(state)))
            return cursor.rowcount == 1

    def binding(self, device_id: int):
        """【MODIFIED】职责：读取单设备的单账号及 Root Folder；输出加密凭证记录或 None。"""
        with self._cursor() as cursor:
            cursor.execute("SELECT * FROM bp_bindings WHERE device_id=%s", (device_id,))
            return cursor.fetchone()

    def save_binding(self, pairing_id: int, device_id: int, path: str, fs_id: int) -> bool:
        """【MODIFIED】职责：一次性完成目录选择并把临时凭证转为设备绑定；输出是否保存。"""
        with self._cursor() as cursor:
            cursor.execute("SELECT * FROM bp_pairings WHERE id=%s AND device_id=%s AND expires_at>UTC_TIMESTAMP(6) AND completed_at IS NULL AND access_cipher IS NOT NULL FOR UPDATE", (pairing_id, device_id))
            pair = cursor.fetchone()
            if pair is None:
                return False
            cursor.execute("INSERT INTO bp_bindings (device_id,access_cipher,refresh_cipher,token_expires_at,root_path,root_fs_id) VALUES (%s,%s,%s,%s,%s,%s) ON DUPLICATE KEY UPDATE access_cipher=VALUES(access_cipher),refresh_cipher=VALUES(refresh_cipher),token_expires_at=VALUES(token_expires_at),root_path=VALUES(root_path),root_fs_id=VALUES(root_fs_id)",
                           (device_id, pair["access_cipher"], pair["refresh_cipher"], pair["token_expires_at"], path, fs_id))
            cursor.execute("UPDATE bp_pairings SET completed_at=UTC_TIMESTAMP(6),pair_cipher='',access_cipher=NULL,refresh_cipher=NULL WHERE id=%s", (pairing_id,))
            return True

    def update_binding_tokens(self, device_id: int, access: bytes, refresh: bytes, expiry: datetime) -> None:
        """【MODIFIED】职责：保存刷新后的加密令牌；仅更新同一设备。"""
        with self._cursor() as cursor:
            cursor.execute("UPDATE bp_bindings SET access_cipher=%s,refresh_cipher=%s,token_expires_at=%s WHERE device_id=%s",
                           (access, refresh, expiry.replace(tzinfo=None), device_id))
