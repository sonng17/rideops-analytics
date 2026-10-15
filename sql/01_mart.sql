-- =====================================================================
-- RideOps Analytics — lớp mart trên kho dữ liệu dw của Trip Data Pipeline
-- Chạy lại được nhiều lần (idempotent).
--   psql -h localhost -p 5433 -U dw -d trips_dw -f sql/01_mart.sql
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS mart;

-- Xóa theo thứ tự phụ thuộc để có thể sửa định nghĩa và chạy lại
DROP FUNCTION IF EXISTS mart.fn_top_shortage(TEXT, INTEGER);
DROP VIEW IF EXISTS mart.v_shortage;
DROP VIEW IF EXISTS mart.v_zone_hour_flow;
DROP MATERIALIZED VIEW IF EXISTS mart.mv_zone_hour_flow;
DROP MATERIALIZED VIEW IF EXISTS mart.mv_zone_hour_profile;

-- ---------------------------------------------------------------------
-- 1. Hồ sơ khu vực x khung giờ x loại ngày (ngày thường / cuối tuần)
--    Tính từ bảng fact để có percentile (P50, P90) thời gian chờ —
--    bảng tổng hợp chỉ có tổng và số đếm, không tính được percentile.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW mart.mv_zone_hour_profile AS
WITH day_counts AS (          -- số ngày có dữ liệu của mỗi loại ngày
    SELECT d.is_weekend, COUNT(*) AS n_days
    FROM dw.dim_date d
    WHERE EXISTS (SELECT 1 FROM dw.agg_trips_zone_hour a WHERE a.pickup_date_key = d.date_key)
    GROUP BY d.is_weekend
)
SELECT
    CASE WHEN d.is_weekend THEN 'Cuối tuần' ELSE 'Ngày thường' END     AS day_type,
    f.pu_zone_id,
    f.pickup_hour,
    COUNT(*)                                                           AS trips,
    ROUND(COUNT(*)::numeric / MAX(dc.n_days), 2)                       AS trips_per_day,
    COUNT(f.wait_seconds)                                              AS wait_count,
    ROUND(AVG(f.wait_seconds) / 60.0, 2)                               AS avg_wait_min,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.wait_seconds) / 60.0)::numeric, 2) AS p50_wait_min,
    ROUND((PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY f.wait_seconds) / 60.0)::numeric, 2) AS p90_wait_min,
    ROUND(AVG(f.trip_miles), 2)                                        AS avg_trip_miles,
    ROUND(SUM(f.driver_pay) / NULLIF(SUM(f.trip_seconds) / 3600.0, 0), 2) AS driver_pay_per_trip_hour
FROM dw.fact_trips f
JOIN dw.dim_date d   ON d.date_key = f.pickup_date_key
JOIN day_counts dc   ON dc.is_weekend = d.is_weekend
GROUP BY d.is_weekend, f.pu_zone_id, f.pickup_hour;

CREATE UNIQUE INDEX ux_mv_zone_hour_profile
    ON mart.mv_zone_hour_profile (day_type, pickup_hour, pu_zone_id);

-- ---------------------------------------------------------------------
-- 2. Luồng cung - cầu: số chuyến đón (cầu) và số chuyến trả (proxy cho
--    nguồn cung — tài xế vừa trả khách sẽ rảnh tại khu vực đó) theo giờ.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW mart.mv_zone_hour_flow AS
WITH day_counts AS (
    SELECT d.is_weekend, COUNT(*) AS n_days
    FROM dw.dim_date d
    WHERE EXISTS (SELECT 1 FROM dw.agg_trips_zone_hour a WHERE a.pickup_date_key = d.date_key)
    GROUP BY d.is_weekend
),
pickups AS (
    SELECT d.is_weekend, f.pu_zone_id AS zone_id, f.pickup_hour AS hour, COUNT(*) AS n
    FROM dw.fact_trips f
    JOIN dw.dim_date d ON d.date_key = f.pickup_date_key
    GROUP BY 1, 2, 3
),
dropoffs AS (
    SELECT EXTRACT(ISODOW FROM f.dropoff_datetime) >= 6 AS is_weekend,
           f.do_zone_id AS zone_id,
           EXTRACT(HOUR FROM f.dropoff_datetime)::smallint AS hour,
           COUNT(*) AS n
    FROM dw.fact_trips f
    GROUP BY 1, 2, 3
)
SELECT
    CASE WHEN COALESCE(p.is_weekend, o.is_weekend) THEN 'Cuối tuần' ELSE 'Ngày thường' END AS day_type,
    COALESCE(p.zone_id, o.zone_id)                                           AS zone_id,
    COALESCE(p.hour, o.hour)                                                 AS hour,
    ROUND(COALESCE(p.n, 0)::numeric / dc.n_days, 2)                          AS pickups_per_day,
    ROUND(COALESCE(o.n, 0)::numeric / dc.n_days, 2)                          AS dropoffs_per_day,
    ROUND((COALESCE(o.n, 0) - COALESCE(p.n, 0))::numeric / dc.n_days, 2)     AS net_supply_per_day
FROM pickups p
FULL OUTER JOIN dropoffs o
       ON o.is_weekend = p.is_weekend AND o.zone_id = p.zone_id AND o.hour = p.hour
JOIN day_counts dc ON dc.is_weekend = COALESCE(p.is_weekend, o.is_weekend);

CREATE UNIQUE INDEX ux_mv_zone_hour_flow
    ON mart.mv_zone_hour_flow (day_type, hour, zone_id);

-- View thường bọc materialized view: Navigator của Power BI chỉ liệt kê bảng và view thường
CREATE VIEW mart.v_zone_hour_flow AS SELECT * FROM mart.mv_zone_hour_flow;

-- ---------------------------------------------------------------------
-- 3. Chẩn đoán thiếu xe.
--    baseline_wait_min = thời gian chờ trung bình của TOÀN THÀNH PHỐ cùng
--                        loại ngày, cùng giờ (trung bình có trọng số).
--    wait_ratio        = chờ của khu vực / baseline. > 1 = chờ lâu hơn mặt bằng.
--    excess_wait_min_per_day = (chờ khu vực - baseline) x số chuyến/ngày
--                        = tổng số phút khách phải chờ VƯỢT mức chung mỗi ngày.
--                        Kết hợp được "chờ lâu" và "nhiều khách" vào một con số.
--    is_shortage       = chờ >= 1.25 lần baseline VÀ thuộc nửa bận rộn hơn
--                        (theo số chuyến) trong cùng giờ.
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_shortage AS
WITH base AS (
    SELECT p.*,
           SUM(p.avg_wait_min * p.wait_count) OVER w
             / NULLIF(SUM(p.wait_count) OVER w, 0)            AS baseline_wait_min,
           PERCENT_RANK() OVER (PARTITION BY p.day_type, p.pickup_hour
                                ORDER BY p.trips_per_day)     AS demand_pct_rank
    FROM mart.mv_zone_hour_profile p
    WINDOW w AS (PARTITION BY p.day_type, p.pickup_hour)
)
SELECT
    b.day_type,
    b.pickup_hour,
    b.pu_zone_id,
    z.borough,
    z.zone_name,
    b.trips,
    b.trips_per_day,
    b.avg_wait_min,
    b.p50_wait_min,
    b.p90_wait_min,
    ROUND(b.baseline_wait_min, 2)                                         AS baseline_wait_min,
    ROUND(b.avg_wait_min / NULLIF(b.baseline_wait_min, 0), 2)             AS wait_ratio,
    ROUND(b.demand_pct_rank::numeric, 2)                                  AS demand_pct_rank,
    ROUND(GREATEST(b.avg_wait_min - b.baseline_wait_min, 0) * b.trips_per_day, 1)
                                                                          AS excess_wait_min_per_day,
    fl.net_supply_per_day,
    (b.avg_wait_min >= 1.25 * b.baseline_wait_min AND b.demand_pct_rank >= 0.5) AS is_shortage
FROM base b
JOIN dw.dim_zone z ON z.zone_id = b.pu_zone_id
LEFT JOIN mart.mv_zone_hour_flow fl
       ON fl.day_type = b.day_type AND fl.hour = b.pickup_hour AND fl.zone_id = b.pu_zone_id;

-- ---------------------------------------------------------------------
-- 4. Function: top khu vực - giờ thiếu xe, xếp theo phút chờ vượt mức.
--    SELECT * FROM mart.fn_top_shortage('Ngày thường', 10);
-- ---------------------------------------------------------------------
CREATE FUNCTION mart.fn_top_shortage(p_day_type TEXT DEFAULT NULL, p_limit INTEGER DEFAULT 20)
RETURNS TABLE (
    day_type TEXT, pickup_hour SMALLINT, zone_name VARCHAR, borough VARCHAR,
    trips_per_day NUMERIC, avg_wait_min NUMERIC, baseline_wait_min NUMERIC,
    wait_ratio NUMERIC, p90_wait_min NUMERIC, excess_wait_min_per_day NUMERIC,
    net_supply_per_day NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT s.day_type, s.pickup_hour, s.zone_name, s.borough,
           s.trips_per_day, s.avg_wait_min, s.baseline_wait_min,
           s.wait_ratio, s.p90_wait_min, s.excess_wait_min_per_day,
           s.net_supply_per_day
    FROM mart.v_shortage s
    WHERE s.is_shortage
      AND (p_day_type IS NULL OR s.day_type = p_day_type)
    ORDER BY s.excess_wait_min_per_day DESC
    LIMIT p_limit;
$$;

-- ---------------------------------------------------------------------
-- 5. Procedure: làm mới các materialized view và ghi nhật ký.
--    CALL mart.sp_refresh_marts();
--    Gọi sau mỗi lần pipeline nạp tháng mới (có thể thêm vào DAG project 1).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart.refresh_log (
    id            BIGSERIAL PRIMARY KEY,
    object_name   TEXT        NOT NULL,
    row_count     BIGINT      NOT NULL,
    duration_ms   INTEGER     NOT NULL,
    refreshed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE PROCEDURE mart.sp_refresh_marts()
LANGUAGE plpgsql AS $$
DECLARE
    v_name    TEXT;
    v_started TIMESTAMPTZ;
    v_rows    BIGINT;
BEGIN
    FOREACH v_name IN ARRAY ARRAY['mart.mv_zone_hour_profile', 'mart.mv_zone_hour_flow'] LOOP
        v_started := clock_timestamp();
        -- CONCURRENTLY: người khác vẫn đọc được view trong lúc làm mới
        -- (cần unique index, đã tạo ở trên)
        EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %s', v_name);
        EXECUTE format('SELECT COUNT(*) FROM %s', v_name) INTO v_rows;
        INSERT INTO mart.refresh_log (object_name, row_count, duration_ms)
        VALUES (v_name, v_rows,
                (EXTRACT(EPOCH FROM clock_timestamp() - v_started) * 1000)::int);
        RAISE NOTICE 'Đã làm mới % (% dòng)', v_name, v_rows;
    END LOOP;
END;
$$;
