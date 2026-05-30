-- ============================================================
-- BLOCK PUZZLE NEO — Global Battle Records Schema
-- 対応DB: PostgreSQL 14+ / MySQL 8.0+
-- ============================================================

-- ============================================================
-- 1. DDL — テーブル定義
-- ============================================================

-- PostgreSQL
CREATE TABLE IF NOT EXISTS cpu_battle_stats (
    cpu_level   SMALLINT    NOT NULL,           -- CPUレベル (1〜4)
    battles     BIGINT      NOT NULL DEFAULT 0, -- 総バトル回数
    wins        BIGINT      NOT NULL DEFAULT 0, -- 総勝利回数
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT cpu_battle_stats_pkey PRIMARY KEY (cpu_level),
    CONSTRAINT cpu_battle_stats_level_check CHECK (cpu_level BETWEEN 1 AND 4),
    CONSTRAINT cpu_battle_stats_battles_nn CHECK (battles >= 0),
    CONSTRAINT cpu_battle_stats_wins_nn    CHECK (wins >= 0)
);

-- 初期データ投入（レベル1〜4を事前登録）
INSERT INTO cpu_battle_stats (cpu_level) VALUES (1),(2),(3),(4)
    ON CONFLICT (cpu_level) DO NOTHING;

-- ============================================================
-- 【オーバーフロー対策の設計意図】
-- BIGINT は 9,223,372,036,854,775,807（約922京）まで格納可能。
-- 全世界で毎秒1,000試合 × 1年間 = 約315億件でも桁あふれしない。
-- SMALLINT で cpu_level を節約しつつ、CHECK制約で不正値を排除。
-- ============================================================


-- ============================================================
-- 2. DML — データ更新（試合終了時: POST /api/stats）
-- ============================================================

-- PostgreSQL: UPSERT + アトミック加算
-- :cpu_level = 対戦したCPUレベル (1〜4)
-- :is_win    = プレイヤーが勝利したか (true/false)

-- 勝利時
INSERT INTO cpu_battle_stats (cpu_level, battles, wins, updated_at)
    VALUES (:cpu_level, 1, 1, NOW())
    ON CONFLICT (cpu_level)
    DO UPDATE SET
        battles    = cpu_battle_stats.battles + 1,
        wins       = cpu_battle_stats.wins    + 1,
        updated_at = NOW();

-- 敗北時（wins を加算しない）
INSERT INTO cpu_battle_stats (cpu_level, battles, wins, updated_at)
    VALUES (:cpu_level, 1, 0, NOW())
    ON CONFLICT (cpu_level)
    DO UPDATE SET
        battles    = cpu_battle_stats.battles + 1,
        updated_at = NOW();

-- ============================================================
-- アプリケーション側で勝敗を判定してクエリを分岐させる代わりに、
-- 以下の単一クエリでも対応可能（:is_win は 1 または 0 の整数）
-- ============================================================
INSERT INTO cpu_battle_stats (cpu_level, battles, wins, updated_at)
    VALUES (:cpu_level, 1, :is_win::INT, NOW())
    ON CONFLICT (cpu_level)
    DO UPDATE SET
        battles    = cpu_battle_stats.battles + 1,
        wins       = cpu_battle_stats.wins    + EXCLUDED.wins,
        updated_at = NOW();

-- ============================================================
-- 【同時書き込み対策の設計意図】
-- SET battles = battles + 1 はDBエンジンがロウレベルで排他制御するため、
-- アプリが SELECT→計算→UPDATE する「Read-Modify-Write」パターンと違い、
-- 複数セッションが同時に実行してもカウントが失われない（ロストアップデート防止）。
-- ON CONFLICT (UPSERT) により INSERT と UPDATE を1文にまとめ、
-- デッドロックの温床となるGAP LOCKも発生しない。
-- PRIMARY KEY インデックスによりレベル別の行ロックのみが取得され、
-- 異なるレベルの同時書き込みは互いにブロックしない。
-- ============================================================


-- ============================================================
-- 3. DML — データ取得（fetchGlobalStats() から呼び出し）
-- ============================================================

-- 全CPUレベルの最新戦績を1クエリで取得
SELECT
    cpu_level,
    battles,
    wins,
    CASE
        WHEN battles = 0 THEN 0
        ELSE ROUND(wins::NUMERIC / battles * 100, 1)
    END AS win_rate_pct
FROM cpu_battle_stats
ORDER BY cpu_level ASC;

-- ============================================================
-- 【高速取得の設計意図】
-- cpu_level が PRIMARY KEY のためフルスキャン不要（最大4行）。
-- CASE式でゼロ除算を回避しつつ、勝率を DB 側で計算して転送量を削減。
-- 読み取りは行ロックを取らない（デフォルト READ COMMITTED）ため、
-- 大量の書き込みと並行しても読み込みをブロックしない。
-- ============================================================


-- ============================================================
-- 補足: MySQL 8.0 向け等価スキーマ
-- ============================================================

-- CREATE TABLE IF NOT EXISTS cpu_battle_stats (
--     cpu_level   TINYINT UNSIGNED NOT NULL,
--     battles     BIGINT UNSIGNED  NOT NULL DEFAULT 0,
--     wins        BIGINT UNSIGNED  NOT NULL DEFAULT 0,
--     updated_at  DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
--                                  ON UPDATE CURRENT_TIMESTAMP(3),
--     PRIMARY KEY (cpu_level),
--     CONSTRAINT chk_level CHECK (cpu_level BETWEEN 1 AND 4)
-- ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
--
-- INSERT INTO cpu_battle_stats (cpu_level) VALUES (1),(2),(3),(4)
--     ON DUPLICATE KEY UPDATE cpu_level = cpu_level;
--
-- -- 更新クエリ (MySQL UPSERT)
-- INSERT INTO cpu_battle_stats (cpu_level, battles, wins)
--     VALUES (:cpu_level, 1, :is_win)
--     ON DUPLICATE KEY UPDATE
--         battles    = battles + 1,
--         wins       = wins    + VALUES(wins),
--         updated_at = CURRENT_TIMESTAMP(3);
