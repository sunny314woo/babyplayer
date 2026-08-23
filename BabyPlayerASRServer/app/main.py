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
from app.deepseek_refiner import DeepSeekLyricsRefinerClient, DeepSeekRefinerError
from app.lyrics_refiner import LyricsRefinementValidationError, LyricsRefinerService
from app.models import (
    AsrAnalysisResponse,
    LyricsRefineRequest,
    LyricsRefineResponse,
    UsageResponse,
)
from app.service import AsrService, AudioValidationError, ServerBusyError
from app.tencent_asr import TencentAsrError, TencentFlashAsrClient


def create_app(
    config: Settings = settings,
    repository: AsrRepository | None = None,
    provider_client=None,
    refiner_client=None,
) -> FastAPI:
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
    refiner_provider = refiner_client or DeepSeekLyricsRefinerClient(
        api_key=config.deepseek_api_key,
        endpoint=config.deepseek_endpoint,
        model=config.deepseek_model,
        timeout_seconds=config.timeout_seconds,
    )
    refiner_service = LyricsRefinerService(refiner_provider, config.deepseek_model)
    application = FastAPI(
        title="BabyPlayer ASR Service",
        version="1.0.0",
        docs_url="/docs" if config.product_env != "production" else None,
        redoc_url=None,
    )

    def require_babyplayer_token(authorization: str | None = Header(default=None)) -> str:
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
        return {
            "status": "ok",
            "provider_configured": config.provider_enabled,
            "lyrics_refiner_configured": config.lyrics_refiner_enabled,
            "monthly_limit_seconds": config.monthly_limit_seconds,
        }

    @application.get("/v1/usage", response_model=UsageResponse)
    def usage(subject_hash: str = Depends(require_babyplayer_token)) -> dict:
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
        now = datetime.now(timezone.utc)
        try:
            # Starlette may spool multipart data into a private temporary file.
            # Reading a bounded amount and closing in finally guarantees its deletion.
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

    @application.post("/v1/refine", response_model=LyricsRefineResponse)
    def refine_lyrics(
        request: LyricsRefineRequest,
        subject_hash: str = Depends(require_babyplayer_token),
    ) -> dict:
        del subject_hash
        if not config.lyrics_refiner_enabled:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail={"code": "DEEPSEEK_NOT_CONFIGURED"},
            )
        try:
            return refiner_service.refine(request)
        except LyricsRefinementValidationError as exc:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail={"code": "INVALID_LYRICS_REFINEMENT", "message": str(exc)},
            )
        except DeepSeekRefinerError:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail={"code": "DEEPSEEK_UNAVAILABLE", "message": "AI 文案校正暂时不可用"},
            )

    return application


app = create_app()
