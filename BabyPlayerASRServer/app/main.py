import hashlib
import hmac
import logging
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, Request, UploadFile, status
from fastapi.exception_handlers import request_validation_exception_handler
from fastapi.exceptions import RequestValidationError

from app.config import Settings, settings
from app.database import (
    AnalysisInProgressError,
    AsrRepository,
    MonthlyLimitReachedError,
    OperationAlreadyUsedError,
    RateLimitReachedError,
    next_reset_at,
)
from app.deepseek_refiner import DeepSeekLyricsRefinerClient, DeepSeekRefinerError
from app.deepseek_lyrics_reconciler import DeepSeekLyricsReconcilerClient
from app.development_artifacts import DevelopmentArtifactWriter
from app.lyrics_reconciler import LyricsReconciliationError, LyricsReconcilerService
from app.lyrics_refiner import LyricsRefinementValidationError, LyricsRefinerService
from app.lyrics_retriever import AllowlistedWebLyricsRetriever, NoopLyricsRetriever
from app.local_analysis import LocalAnalysisJobManager, LocalMediaAudioExtractor
from app.models import (
    AsrAnalysisResponse,
    LocalAnalysisJobRequest,
    LocalAnalysisJobResponse,
    LyricsReconcileRequest,
    LyricsReconcileResponse,
    LyricsRefineRequest,
    LyricsRefineResponse,
    UsageResponse,
)
from app.service import AsrService, AudioValidationError, ServerBusyError
from app.tencent_asr import TencentAsrError, TencentFlashAsrClient
from app.voice_activity import SileroVoiceActivityDetector
from app.vocal_separation import LocalVocalStemSeparator


logger = logging.getLogger("babyplayer.api")


def create_app(
    config: Settings = settings,
    repository: AsrRepository | None = None,
    provider_client=None,
    refiner_client=None,
    reconciler_client=None,
    lyrics_retriever=None,
    local_media_extractor=None,
    voice_activity_detector=None,
    vocal_stem_separator=None,
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
    artifact_writer = DevelopmentArtifactWriter(
        config.development_artifacts_directory,
        enabled=config.product_env != "production",
    )
    # 【MODIFIED】本地路径分析只在 Mac 开发环境使用，最终结果仍进入现有 SQLite 缓存。
    resolved_voice_activity_detector = voice_activity_detector
    if resolved_voice_activity_detector is None and config.local_voice_activity_enabled:
        resolved_voice_activity_detector = SileroVoiceActivityDetector(
            threshold=config.local_voice_activity_threshold,
        )
    resolved_vocal_stem_separator = vocal_stem_separator
    if (
        resolved_vocal_stem_separator is None
        and config.local_vocal_separation_enabled
    ):
        resolved_vocal_stem_separator = LocalVocalStemSeparator(config)
    resolved_local_extractor = local_media_extractor or LocalMediaAudioExtractor(
        config,
        voice_activity_detector=resolved_voice_activity_detector,
        vocal_stem_separator=resolved_vocal_stem_separator,
    )
    local_jobs = LocalAnalysisJobManager(
        service=service,
        extractor=resolved_local_extractor,
        artifact_writer=artifact_writer,
        max_concurrency=config.max_concurrency,
    )
    refiner_provider = refiner_client or DeepSeekLyricsRefinerClient(
        api_key=config.deepseek_api_key,
        endpoint=config.deepseek_endpoint,
        model=config.deepseek_model,
        timeout_seconds=config.timeout_seconds,
    )
    refiner_service = LyricsRefinerService(refiner_provider, config.deepseek_model)
    reconciliation_provider = reconciler_client or DeepSeekLyricsReconcilerClient(
        api_key=config.deepseek_api_key,
        endpoint=config.deepseek_endpoint,
        model=config.deepseek_model,
        timeout_seconds=config.timeout_seconds,
    )
    resolved_retriever = lyrics_retriever
    if resolved_retriever is None:
        resolved_retriever = AllowlistedWebLyricsRetriever(
            timeout_seconds=config.lyrics_web_search_timeout_seconds,
            max_results=config.lyrics_web_search_max_results,
        ) if config.lyrics_web_search_enabled else NoopLyricsRetriever()
    reconciliation_service = LyricsReconcilerService(
        repository=database,
        model=reconciliation_provider,
        retriever=resolved_retriever,
        model_name=config.deepseek_model,
        analysis_version=service.analysis_version,
        reconciliation_version=config.lyrics_reconciliation_version,
    )
    application = FastAPI(
        title="BabyPlayer ASR Service",
        version="1.0.0",
        docs_url="/docs" if config.product_env != "production" else None,
        redoc_url=None,
    )

    @application.exception_handler(RequestValidationError)
    async def log_request_validation_failure(
        request: Request, exc: RequestValidationError
    ):
        # Log only schema locations/types/messages. Input values may contain lyrics or ASR text.
        safe_errors = [
            {
                "loc": list(error.get("loc") or []),
                "type": error.get("type"),
                "msg": error.get("msg"),
            }
            for error in exc.errors()
        ]
        logger.error(
            "Request validation failed path=%s errors=%s",
            request.url.path,
            safe_errors,
        )
        return await request_validation_exception_handler(request, exc)

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
            "local_analysis_enabled": config.product_env != "production",
            "voice_activity_configured": bool(
                config.local_voice_activity_enabled
                and SileroVoiceActivityDetector.available()
            ),
            "vocal_separation_configured": bool(
                config.local_vocal_separation_enabled
                and LocalVocalStemSeparator.available()
            ),
            "vocal_separation_model_ready": bool(
                config.local_vocal_separation_enabled
                and resolved_vocal_stem_separator is not None
                and resolved_vocal_stem_separator.model_ready()
            ),
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

    @application.post(
        "/v1/local-analysis/jobs", response_model=LocalAnalysisJobResponse
    )
    def submit_local_analysis(
        request: LocalAnalysisJobRequest,
        subject_hash: str = Depends(require_babyplayer_token),
    ) -> dict:
        if config.product_env == "production":
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "LOCAL_ANALYSIS_DISABLED"},
            )
        if not config.provider_enabled:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail={"code": "TENCENT_ASR_NOT_CONFIGURED"},
            )
        return local_jobs.submit(
            subject_hash=subject_hash,
            request=request,
        )

    @application.get(
        "/v1/local-analysis/jobs/{job_id}", response_model=LocalAnalysisJobResponse
    )
    def local_analysis_status(
        job_id: str,
        subject_hash: str = Depends(require_babyplayer_token),
    ) -> dict:
        if config.product_env == "production":
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "LOCAL_ANALYSIS_DISABLED"},
            )
        job = local_jobs.get(job_id, subject_hash=subject_hash)
        if not job:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "LOCAL_ANALYSIS_JOB_NOT_FOUND"},
            )
        return job

    @application.post("/v1/analyze", response_model=AsrAnalysisResponse)
    def analyze(
        operation_id: str = Form(...),
        media_fingerprint: str = Form(...),
        media_title: str = Form(""),
        duration_seconds: float = Form(...),
        voice_format: str = Form("m4a"),
        force_refresh: bool = Form(False),
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
            result = service.analyze(
                subject_hash=subject_hash,
                operation_id=operation_id,
                media_fingerprint=media_fingerprint,
                duration_seconds=duration_seconds,
                voice_format=voice_format,
                audio=audio_bytes,
                force_refresh=force_refresh,
                now=now,
            )
            artifact_writer.store_asr(
                media_fingerprint=media_fingerprint,
                media_title=media_title,
                audio=audio_bytes,
                response=result,
                force_refresh=force_refresh,
            )
            return result
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
        except AnalysisInProgressError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "code": "ASR_ANALYSIS_IN_PROGRESS",
                    "message": "同一音频正在识别，请稍后读取缓存",
                },
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
            logger.error("Lyrics refinement rejected reason=%s", str(exc))
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail={"code": "INVALID_LYRICS_REFINEMENT", "message": str(exc)},
            )
        except DeepSeekRefinerError:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail={"code": "DEEPSEEK_UNAVAILABLE", "message": "AI 文案校正暂时不可用"},
            )

    @application.post(
        "/v1/lyrics/reconcile", response_model=LyricsReconcileResponse
    )
    def reconcile_lyrics(
        request: LyricsReconcileRequest,
        subject_hash: str = Depends(require_babyplayer_token),
    ) -> dict:
        if not config.lyrics_refiner_enabled:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail={"code": "DEEPSEEK_NOT_CONFIGURED"},
            )
        now = datetime.now(timezone.utc)
        asr_analysis = service.lookup(
            subject_hash=subject_hash,
            media_fingerprint=request.media_fingerprint,
            now=now,
        )
        if not asr_analysis:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "code": "ASR_CACHE_REQUIRED",
                    "message": "请先完成这首歌的腾讯声音分析",
                },
            )
        try:
            result = reconciliation_service.reconcile(
                subject_hash=subject_hash,
                request=request,
                asr_analysis=asr_analysis,
                now=now,
            )
            artifact_writer.store_deepseek(
                media_fingerprint=request.media_fingerprint,
                media_title=request.song_title,
                request=request.model_dump(mode="json"),
                response=result,
            )
            return result
        except LyricsReconciliationError as exc:
            logger.error("Lyrics reconciliation rejected reason=%s", str(exc))
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail={"code": "INVALID_LYRICS_RECONCILIATION", "message": str(exc)},
            )
        except DeepSeekRefinerError:
            logger.exception(
                "DeepSeek lyrics reconciliation unavailable title=%s fingerprint=%s",
                request.song_title,
                request.media_fingerprint,
            )
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail={"code": "DEEPSEEK_UNAVAILABLE", "message": "AI 歌词重建暂时不可用"},
            )

    @application.get(
        "/v1/lyrics/cache", response_model=LyricsReconcileResponse
    )
    def cached_reconciled_lyrics(
        media_fingerprint: str = Query(min_length=8, max_length=512),
        subject_hash: str = Depends(require_babyplayer_token),
    ) -> dict:
        """Return only an existing result; never invoke ASR, web search, or DeepSeek."""
        result = database.latest_cached_ai_lyrics(
            subject_hash,
            hashlib.sha256(media_fingerprint.strip().encode("utf-8")).hexdigest(),
        )
        if not result:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "AI_LYRICS_CACHE_NOT_FOUND"},
            )
        return {**result, "cache_hit": True}

    return application


app = create_app()
