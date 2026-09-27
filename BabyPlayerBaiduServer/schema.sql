-- 用途：BabyPlayer 百度设备绑定的独立 MySQL schema。
-- 主要功能：隔离设备、短时配对和单账号单 Root Folder 凭证。
-- 最近修改：【MODIFIED】Phase 5 使用原生 SQL，不复用 English Follow 数据库。
CREATE TABLE IF NOT EXISTS bp_devices (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  token_hash CHAR(64) NOT NULL UNIQUE,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS bp_pairings (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  device_id BIGINT UNSIGNED NOT NULL,
  pair_hash CHAR(64) NOT NULL UNIQUE,
  pair_cipher VARBINARY(512) NOT NULL,
  oauth_state_hash CHAR(64) NULL UNIQUE,
  access_cipher VARBINARY(4096) NULL,
  refresh_cipher VARBINARY(4096) NULL,
  token_expires_at DATETIME(6) NULL,
  expires_at DATETIME(6) NOT NULL,
  completed_at DATETIME(6) NULL,
  CONSTRAINT fk_bp_pair_device FOREIGN KEY (device_id) REFERENCES bp_devices(id),
  INDEX idx_bp_pair_expiry (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS bp_bindings (
  device_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
  access_cipher VARBINARY(4096) NOT NULL,
  refresh_cipher VARBINARY(4096) NOT NULL,
  token_expires_at DATETIME(6) NOT NULL,
  root_path VARCHAR(2048) NOT NULL,
  root_fs_id BIGINT UNSIGNED NOT NULL,
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  CONSTRAINT fk_bp_binding_device FOREIGN KEY (device_id) REFERENCES bp_devices(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
