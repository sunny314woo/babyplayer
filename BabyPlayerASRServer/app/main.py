"""
BabyPlayerASRServer/app/main.py

用途：提供 BabyPlayer 独立的腾讯 ASR HTTP API。
主要功能：
1. 健康检查与月度额度查询。
2. 按媒体指纹查询 ASR 缓存。
3. 接收临时 M4A/AAC/MP3 上传并调用腾讯 ASR。
4. 统一处理鉴权、额度、限流、临时文件关闭和错误响应。
最近修改：2026-08-23 【MODIFIED】按冻结版本 B 移除 /v1/refine 与全部 LLM 运行时依赖。
"""

import hashlib
import hmac
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile, status

from app.config import Settings, settings
from app.database import (
    AsrRepository,
    MonthlyLimitReachedError,
    OperationAlreadyUsedError,
    RateLimitReachedError,
    next_reset_at,
)
from app.models import AsrAnalysisResponse, UsageResponse
from app.service import AsrService, AudioValidationError, ServerBusyError
from app.tencent_asr import TencentAsrError, TencentFlashAsrClient


# 【MODIFIED】应用工厂仅装配 BabyPlayer 独立 ASR；不再创建或暴露任何歌词 LLM 服务。
def create_app(
    config: Settings = settings,
    repository: AsrRepository | None = None,
    provider_client=None,
) -> FastAPI:
    """创建独立 FastAPI 应用；输入为配置/可选测试替身，输出为 ASR-only 应用实例。"""
    database = repository or AsrRepository(config.database_path)
    database.initialize()
    provider = provider_client or TencentFlashAsrClient(
        app_id=config.app_id,
        secret_id=config.secret_id,
        secret_key=config.secret_key,
        endpoint=config.endpoint,
        engine_type=config.engine_type,
        timeout_seconds=config.timeout_seconds,
    )
    service = AsrService(database, provider, config)
    application = FastAPI(
        title="BabyPlayer ASR Service",
        version="1.1.0",
        docs_url="/docs" if config.product_env != "production" else None,
        redoc_url=None,
    )

    # 【MODIFIED】只验证 BabyPlayer 自己的 Bearer Token，绝不复用 account-server 鉴权。
    def require_babyplayer_token(authorization: str | None = Header(default=None)) -> str:
        """验证独立 Bearer Token，并返回不可逆 subject hash；失败直接返回 HTTP 错误。"""
        if not config.auth_enabled:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail={"code": "BABYPLAYER_AUTH_NOT_CONFIGURED"},
            )
        scheme, _, candidate = (authorization or "").partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(candidate, config.api_token):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail={"code": "INVALID_BABYPLAYER_TOKEN"},
                headers={"WWW-Authenticate": "Bearer"},
            )
        return hashlib.sha256(candidate.encode("utf-8")).hexdigest()

    @application.get("/health")
    def health() -> dict:
        """返回无 Secret 的服务健康状态和固定月度上限。"""
        return {
            "status": "ok",
            "provider_configured": config.provider_enabled,
            "monthly_limit_seconds": config.monthly_limit_seconds,
        }

    @application.get("/v1/usage", response_model=UsageResponse)
    def usage(subject_hash: str = Depends(require_babyplayer_token)) -> dict:
        """返回当前北京时间自然月的已用、预留、剩余秒数和下次重置时间。"""
        del subject_hash
        now = datetime.now(timezone.utc)
        current = database.usage(config.monthly_limit_seconds, now)
        return {
            "month": current.month,
            "used_seconds": current.used_seconds,
            "reserved_seconds": current.reserved_seconds,
            "remaining_seconds": current.remaining_seconds,
            "limit_seconds": current.limit_seconds,
            "next_reset_at": next_reset_at(now),
        }

    @application.get("/v1/cache", response_model=AsrAnalysisResponse)
    def cache_lookup(
        media_fingerprint: str,
        subject_hash: str = Depends(require_babyplayer_token),
    ) -> dict:
        """按不可逆媒体指纹查询既有 ASR 结果；命中时不消耗腾讯额度。"""
        now = datetime.now(timezone.utc)
        cached = service.lookup(
            subject_hash=subject_hash,
            media_fingerprint=media_fingerprint,
            now=now,
        )
        if not cached:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "ASR_CACHE_MISS"},
            )
        return cached

    @application.post("/v1/analyze", response_model=AsrAnalysisResponse)
    def analyze(
        operation_id: str = Form(...),
        media_fingerprint: str = Form(...),
        duration_seconds: float = Form(...),
        voice_format: str = Form("m4a"),
        audio: UploadFile = File(...),
        subject_hash: str = Depends(require_babyplayer_token),
    ) -> dict:
        """识别一次临时音频上传；服务端最终执行缓存、原子额度和并发硬限制。"""
        now = datetime.now(timezone.utc)
        try:
            # Starlette 可能把 multipart 暂存到 PrivateTmp；有界读取后 finally 关闭即可删除。
            audio_bytes = audio.file.read(config.max_audio_bytes + 1)
            if not config.provider_enabled:
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail={"code": "TENCENT_ASR_NOT_CONFIGURED"},
                )
            return service.analyze(
                subject_hash=subject_hash,
                operation_id=operation_id,
                media_fingerprint=media_fingerprint,
                duration_seconds=duration_seconds,
                voice_format=voice_format,
                audio=audio_bytes,
                now=now,
            )
        except MonthlyLimitReachedError:
            reset = next_reset_at(now)
            reset_date = datetime.fromisoformat(reset)
            friendly_reset = (
                f"{reset_date.year}年{reset_date.month}月{reset_date.day}日 "
                f"{reset_date.hour:02d}:{reset_date.minute:02d}"
            )
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail={
                    "code": "MONTHLY_ASR_LIMIT_REACHED",
                    "message": f"本月声音分析额度已用完，可于 {friendly_reset} 再次使用",
                    "next_available_at": reset,
                },
            )
        except RateLimitReachedError:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail={"code": "ASR_RATE_LIMITED", "message": "声音分析请求过于频繁，请稍后再试"},
            )
        except OperationAlreadyUsedError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={"code": "ASR_OPERATION_ALREADY_USED"},
            )
        except AudioValidationError as exc:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail={"code": "INVALID_AUDIO_SAMPLE", "message": str(exc)},
            )
        except ServerBusyError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail={"code": "ASR_SERVER_BUSY"},
            )
        except TencentAsrError:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail={"code": "TENCENT_ASR_UNAVAILABLE"},
            )
        finally:
            audio.file.close()

    return application


app = create_app()
