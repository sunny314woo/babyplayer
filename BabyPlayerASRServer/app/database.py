import json
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


class MonthlyLimitReachedError(Exception):
    pass


class RateLimitReachedError(Exception):
    pass


class OperationAlreadyUsedError(Exception):
    pass


class AnalysisInProgressError(Exception):
    pass


@dataclass(frozen=True)
class Usage:
    month: str
    used_seconds: int
    reserved_seconds: int
    limit_seconds: int

    @property
    def remaining_seconds(self) -> int:
        return max(0, self.limit_seconds - self.used_seconds - self.reserved_seconds)


SCHEMA = """
CREATE TABLE IF NOT EXISTS asr_usage_monthly (
  month TEXT PRIMARY KEY,
  used_seconds INTEGER NOT NULL DEFAULT 0,
  reserved_seconds INTEGER NOT NULL DEFAULT 0,
  request_count INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS asr_rate_windows (
  subject_hash TEXT NOT NULL,
  window_started_at TEXT NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (subject_hash, window_started_at)
);
CREATE TABLE IF NOT EXISTS asr_operations (
  operation_id TEXT PRIMARY KEY,
  subject_hash TEXT NOT NULL,
  usage_month TEXT NOT NULL,
  media_fingerprint_hash TEXT NOT NULL,
  audio_sha256 TEXT NOT NULL,
  reserved_seconds INTEGER NOT NULL,
  billed_seconds INTEGER,
  status TEXT NOT NULL CHECK (status IN ('CLAIMED', 'COMPLETED')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS asr_analysis_cache (
  subject_hash TEXT NOT NULL,
  media_fingerprint_hash TEXT NOT NULL,
  analysis_version TEXT NOT NULL,
  audio_sha256 TEXT NOT NULL,
  engine_type TEXT NOT NULL,
  audio_duration_seconds REAL NOT NULL,
  transcript TEXT NOT NULL,
  segments_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (subject_hash, media_fingerprint_hash, analysis_version)
);
CREATE INDEX IF NOT EXISTS idx_asr_cache_audio_sha
ON asr_analysis_cache(subject_hash, audio_sha256);
CREATE UNIQUE INDEX IF NOT EXISTS idx_asr_one_claimed_audio
ON asr_operations(subject_hash, audio_sha256)
WHERE status='CLAIMED';
CREATE TABLE IF NOT EXISTS ai_lyrics_cache (
  subject_hash TEXT NOT NULL,
  media_fingerprint_hash TEXT NOT NULL,
  reconciliation_version TEXT NOT NULL,
  result_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (subject_hash, media_fingerprint_hash, reconciliation_version)
);
"""


class AsrRepository:
    def __init__(self, database_path: str) -> None:
        self.database_path = database_path

    def initialize(self) -> None:
        path = Path(self.database_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.executescript(SCHEMA)

    def cached(self, subject_hash: str, fingerprint_hash: str, version: str):
        with self._connect() as connection:
            row = connection.execute(
                """SELECT engine_type, audio_duration_seconds, transcript, segments_json
                   FROM asr_analysis_cache
                   WHERE subject_hash=? AND media_fingerprint_hash=? AND analysis_version=?""",
                (subject_hash, fingerprint_hash, version),
            ).fetchone()
        if not row:
            return None
        return {
            "engine_type": row["engine_type"],
            "audio_duration_seconds": float(row["audio_duration_seconds"]),
            "transcript": row["transcript"],
            "segments": json.loads(row["segments_json"]),
        }

    def cached_ai_lyrics(
        self, subject_hash: str, fingerprint_hash: str, reconciliation_version: str
    ):
        """Read a cached D3 result without exposing or copying ASR/audio evidence."""
        with self._connect() as connection:
            row = connection.execute(
                """SELECT result_json FROM ai_lyrics_cache
                   WHERE subject_hash=? AND media_fingerprint_hash=?
                     AND reconciliation_version=?""",
                (subject_hash, fingerprint_hash, reconciliation_version),
            ).fetchone()
        return json.loads(row["result_json"]) if row else None

    def store_ai_lyrics(
        self,
        *,
        subject_hash: str,
        fingerprint_hash: str,
        reconciliation_version: str,
        result: dict,
        now: datetime,
    ) -> None:
        """Atomically replace one fingerprint's reusable D3 lyrics result."""
        timestamp = now.astimezone(timezone.utc).isoformat()
        serialized = json.dumps(result, ensure_ascii=False, separators=(",", ":"))
        with self._transaction() as connection:
            connection.execute(
                """INSERT INTO ai_lyrics_cache
                   (subject_hash, media_fingerprint_hash, reconciliation_version,
                    result_json, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?)
                   ON CONFLICT(subject_hash, media_fingerprint_hash, reconciliation_version)
                   DO UPDATE SET result_json=excluded.result_json,
                     updated_at=excluded.updated_at""",
                (
                    subject_hash,
                    fingerprint_hash,
                    reconciliation_version,
                    serialized,
                    timestamp,
                    timestamp,
                ),
            )

    def alias_cached_audio(
        self,
        *,
        subject_hash: str,
        fingerprint_hash: str,
        audio_sha256: str,
        version: str,
        now: datetime,
    ):
        """Attach a new media fingerprint to an already recognized identical audio file."""
        timestamp = now.astimezone(timezone.utc).isoformat()
        with self._transaction() as connection:
            row = connection.execute(
                """SELECT engine_type, audio_duration_seconds, transcript, segments_json,
                          created_at
                   FROM asr_analysis_cache
                   WHERE subject_hash=? AND audio_sha256=? AND analysis_version=?
                   ORDER BY updated_at DESC LIMIT 1""",
                (subject_hash, audio_sha256, version),
            ).fetchone()
            if not row:
                return None
            connection.execute(
                """INSERT INTO asr_analysis_cache
                   (subject_hash, media_fingerprint_hash, analysis_version, audio_sha256,
                    engine_type, audio_duration_seconds, transcript, segments_json,
                    created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(subject_hash, media_fingerprint_hash, analysis_version)
                   DO UPDATE SET audio_sha256=excluded.audio_sha256,
                     engine_type=excluded.engine_type,
                     audio_duration_seconds=excluded.audio_duration_seconds,
                     transcript=excluded.transcript, segments_json=excluded.segments_json,
                     updated_at=excluded.updated_at""",
                (
                    subject_hash, fingerprint_hash, version, audio_sha256,
                    row["engine_type"], row["audio_duration_seconds"], row["transcript"],
                    row["segments_json"], row["created_at"], timestamp,
                ),
            )
        return {
            "engine_type": row["engine_type"],
            "audio_duration_seconds": float(row["audio_duration_seconds"]),
            "transcript": row["transcript"],
            "segments": json.loads(row["segments_json"]),
        }

    def usage(self, monthly_limit: int, now: datetime) -> Usage:
        month = month_key(now)
        with self._connect() as connection:
            row = connection.execute(
                "SELECT used_seconds, reserved_seconds FROM asr_usage_monthly WHERE month=?",
                (month,),
            ).fetchone()
        return Usage(
            month=month,
            used_seconds=int(row["used_seconds"]) if row else 0,
            reserved_seconds=int(row["reserved_seconds"]) if row else 0,
            limit_seconds=monthly_limit,
        )

    def claim(
        self,
        *,
        operation_id: str,
        subject_hash: str,
        fingerprint_hash: str,
        audio_sha256: str,
        reserve_seconds: int,
        monthly_limit: int,
        requests_per_minute: int,
        now: datetime,
    ) -> None:
        month = month_key(now)
        minute = now.astimezone(timezone.utc).replace(second=0, microsecond=0).isoformat()
        timestamp = now.astimezone(timezone.utc).isoformat()
        with self._transaction() as connection:
            if connection.execute(
                "SELECT 1 FROM asr_operations WHERE operation_id=?", (operation_id,)
            ).fetchone():
                raise OperationAlreadyUsedError()
            if connection.execute(
                """SELECT 1 FROM asr_operations
                   WHERE subject_hash=? AND audio_sha256=? AND status='CLAIMED'""",
                (subject_hash, audio_sha256),
            ).fetchone():
                raise AnalysisInProgressError()
            connection.execute(
                """INSERT OR IGNORE INTO asr_rate_windows
                   (subject_hash, window_started_at, request_count, updated_at)
                   VALUES (?, ?, 0, ?)""",
                (subject_hash, minute, timestamp),
            )
            rate = connection.execute(
                """SELECT request_count FROM asr_rate_windows
                   WHERE subject_hash=? AND window_started_at=?""",
                (subject_hash, minute),
            ).fetchone()
            if int(rate["request_count"]) >= requests_per_minute:
                raise RateLimitReachedError()
            connection.execute(
                """UPDATE asr_rate_windows SET request_count=request_count+1, updated_at=?
                   WHERE subject_hash=? AND window_started_at=?""",
                (timestamp, subject_hash, minute),
            )
            connection.execute(
                """INSERT OR IGNORE INTO asr_usage_monthly
                   (month, used_seconds, reserved_seconds, request_count, updated_at)
                   VALUES (?, 0, 0, 0, ?)""",
                (month, timestamp),
            )
            usage = connection.execute(
                """SELECT used_seconds, reserved_seconds FROM asr_usage_monthly
                   WHERE month=?""",
                (month,),
            ).fetchone()
            if int(usage["used_seconds"]) + int(usage["reserved_seconds"]) + reserve_seconds > monthly_limit:
                raise MonthlyLimitReachedError()
            connection.execute(
                """UPDATE asr_usage_monthly
                   SET reserved_seconds=reserved_seconds+?, updated_at=? WHERE month=?""",
                (reserve_seconds, timestamp, month),
            )
            connection.execute(
                """INSERT INTO asr_operations
                   (operation_id, subject_hash, usage_month, media_fingerprint_hash, audio_sha256,
                    reserved_seconds, billed_seconds, status, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, NULL, 'CLAIMED', ?, ?)""",
                (
                    operation_id, subject_hash, month, fingerprint_hash, audio_sha256,
                    reserve_seconds, timestamp, timestamp,
                ),
            )

    def complete(
        self,
        *,
        operation_id: str,
        subject_hash: str,
        fingerprint_hash: str,
        analysis_version: str,
        audio_sha256: str,
        engine_type: str,
        duration_seconds: float,
        transcript: str,
        segments: list[dict],
        monthly_limit: int,
        now: datetime,
    ) -> Usage:
        timestamp = now.astimezone(timezone.utc).isoformat()
        provider_seconds = max(1, int(duration_seconds + 0.999))
        with self._transaction() as connection:
            operation = connection.execute(
                """SELECT usage_month, reserved_seconds, status FROM asr_operations
                   WHERE operation_id=? AND subject_hash=?""",
                (operation_id, subject_hash),
            ).fetchone()
            if not operation or operation["status"] != "CLAIMED":
                raise OperationAlreadyUsedError()
            reserved = int(operation["reserved_seconds"])
            usage_month = operation["usage_month"]
            # The trusted tvOS client declares the exported time range. Tencent's
            # measured duration must not exceed it by more than container rounding.
            if provider_seconds > reserved + 2:
                raise ValueError("Provider duration exceeded the reserved audio duration")
            # AAC container padding may make the provider report a fraction over the
            # exported time range. Never let accounting exceed the atomic reservation.
            billed = min(reserved, provider_seconds)
            connection.execute(
                """UPDATE asr_usage_monthly
                   SET reserved_seconds=MAX(reserved_seconds-?, 0),
                       used_seconds=used_seconds+?, request_count=request_count+1,
                       updated_at=? WHERE month=?""",
                (reserved, billed, timestamp, usage_month),
            )
            connection.execute(
                """UPDATE asr_operations SET billed_seconds=?, status='COMPLETED', updated_at=?
                   WHERE operation_id=?""",
                (billed, timestamp, operation_id),
            )
            connection.execute(
                """INSERT INTO asr_analysis_cache
                   (subject_hash, media_fingerprint_hash, analysis_version, audio_sha256,
                    engine_type, audio_duration_seconds, transcript, segments_json,
                    created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(subject_hash, media_fingerprint_hash, analysis_version)
                   DO UPDATE SET audio_sha256=excluded.audio_sha256,
                     engine_type=excluded.engine_type,
                     audio_duration_seconds=excluded.audio_duration_seconds,
                     transcript=excluded.transcript, segments_json=excluded.segments_json,
                     updated_at=excluded.updated_at""",
                (
                    subject_hash, fingerprint_hash, analysis_version, audio_sha256,
                    engine_type, duration_seconds, transcript,
                    json.dumps(segments, ensure_ascii=False, separators=(",", ":")),
                    timestamp, timestamp,
                ),
            )
        return self.usage(monthly_limit, now)

    def release(self, operation_id: str, now: datetime) -> None:
        timestamp = now.astimezone(timezone.utc).isoformat()
        with self._transaction() as connection:
            operation = connection.execute(
                "SELECT usage_month, reserved_seconds, status FROM asr_operations WHERE operation_id=?",
                (operation_id,),
            ).fetchone()
            if not operation or operation["status"] != "CLAIMED":
                return
            connection.execute(
                """UPDATE asr_usage_monthly
                   SET reserved_seconds=MAX(reserved_seconds-?, 0), updated_at=?
                   WHERE month=?""",
                (int(operation["reserved_seconds"]), timestamp, operation["usage_month"]),
            )
            connection.execute("DELETE FROM asr_operations WHERE operation_id=?", (operation_id,))

    @contextmanager
    def _connect(self):
        connection = sqlite3.connect(self.database_path, timeout=10)
        connection.row_factory = sqlite3.Row
        try:
            yield connection
            connection.commit()
        finally:
            connection.close()

    @contextmanager
    def _transaction(self):
        connection = sqlite3.connect(self.database_path, timeout=10, isolation_level=None)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("BEGIN IMMEDIATE")
            yield connection
            connection.execute("COMMIT")
        except Exception:
            connection.execute("ROLLBACK")
            raise
        finally:
            connection.close()


def month_key(now: datetime) -> str:
    return now.astimezone(ZoneInfo("Asia/Shanghai")).strftime("%Y-%m")


def next_reset_at(now: datetime) -> str:
    local = now.astimezone(ZoneInfo("Asia/Shanghai"))
    if local.month == 12:
        reset = local.replace(year=local.year + 1, month=1, day=1)
    else:
        reset = local.replace(month=local.month + 1, day=1)
    return reset.replace(hour=0, minute=0, second=0, microsecond=0).isoformat()
