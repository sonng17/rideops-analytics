-- =====================================================================
-- Đối chiếu số liệu: mọi lớp phải ra cùng một tổng. Mỗi dòng có cột ok.
--   psql -h localhost -p 5433 -U dw -d trips_dw -f sql/03_checks.sql
-- =====================================================================
WITH f AS (SELECT COUNT(*) AS n, COUNT(wait_seconds) AS wn, SUM(wait_seconds) AS ws,
                  SUM(driver_pay) AS pay FROM dw.fact_trips),
     a AS (SELECT SUM(trip_count) AS n, SUM(wait_count) AS wn, SUM(wait_seconds_sum) AS ws,
                  SUM(driver_pay_sum) AS pay FROM dw.agg_trips_zone_hour),
     p AS (SELECT SUM(trips) AS n, SUM(wait_count) AS wn FROM mart.mv_zone_hour_profile),
     fl AS (SELECT SUM(pickups_per_day * CASE day_type WHEN 'Cuối tuần' THEN we.n ELSE wd.n END) AS pick
            FROM mart.mv_zone_hour_flow,
                 (SELECT COUNT(*) n FROM dw.dim_date d WHERE is_weekend
                    AND EXISTS (SELECT 1 FROM dw.agg_trips_zone_hour x WHERE x.pickup_date_key = d.date_key)) we,
                 (SELECT COUNT(*) n FROM dw.dim_date d WHERE NOT is_weekend
                    AND EXISTS (SELECT 1 FROM dw.agg_trips_zone_hour x WHERE x.pickup_date_key = d.date_key)) wd)
SELECT 'Số chuyến: fact = agg' AS check_name, f.n::text AS left_value, a.n::text AS right_value, f.n = a.n AS ok FROM f, a
UNION ALL
SELECT 'Số chuyến có wait: fact = agg', f.wn::text, a.wn::text, f.wn = a.wn FROM f, a
UNION ALL
SELECT 'Tổng giây chờ: fact = agg', f.ws::text, a.ws::text, f.ws = a.ws FROM f, a
UNION ALL
SELECT 'Tổng driver_pay: fact = agg', f.pay::text, a.pay::text, f.pay = a.pay FROM f, a
UNION ALL
SELECT 'Số chuyến: fact = mv_zone_hour_profile', f.n::text, p.n::text, f.n = p.n FROM f, p
UNION ALL
SELECT 'Số chuyến đón: fact ≈ mv_zone_hour_flow (sai số làm tròn < 0.1%)', f.n::text,
       ROUND(fl.pick)::text, ABS(fl.pick - f.n) < f.n * 0.001 FROM f, fl
UNION ALL
SELECT 'Đã chạy mart.sp_refresh_marts() (lần gần nhất)',
       (SELECT MAX(refreshed_at)::text FROM mart.refresh_log), '-',
       (SELECT COUNT(*) FROM mart.refresh_log) > 0;
