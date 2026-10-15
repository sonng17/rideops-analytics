-- =====================================================================
-- RideOps Analytics — truy vấn phân tích vận hành
--   psql -h localhost -p 5433 -U dw -d trips_dw -f sql/02_analysis.sql
-- Quy tắc: trung bình = tổng / số đếm (không lấy trung bình của trung bình).
-- =====================================================================

-- Q1. KPI theo tháng và hãng --------------------------------------------
SELECT d.year, d.month, c.company_name,
       SUM(a.trip_count)                                                             AS trips,
       ROUND(SUM(a.trip_count)::numeric / COUNT(DISTINCT a.pickup_date_key), 0)      AS trips_per_day,
       ROUND(SUM(a.wait_seconds_sum)::numeric / NULLIF(SUM(a.wait_count), 0) / 60, 2) AS avg_wait_min,
       ROUND(SUM(a.trip_miles_sum) / SUM(a.trip_count), 2)                           AS avg_trip_miles,
       ROUND(SUM(a.base_fare_sum) / SUM(a.trip_count), 2)                            AS avg_base_fare,
       ROUND(SUM(a.driver_pay_sum) / NULLIF(SUM(a.base_fare_sum), 0) * 100, 1)       AS driver_share_pct,
       ROUND(SUM(a.driver_pay_sum) / NULLIF(SUM(a.trip_seconds_sum) / 3600.0, 0), 2) AS driver_pay_per_trip_hour
FROM dw.agg_trips_zone_hour a
JOIN dw.dim_date d    ON d.date_key = a.pickup_date_key
JOIN dw.dim_company c ON c.company_key = a.company_key
GROUP BY d.year, d.month, c.company_name
ORDER BY d.year, d.month, c.company_name;

-- Q2. Thứ trong tuần x giờ: nhu cầu và thời gian chờ (dữ liệu cho heatmap) --
SELECT d.day_of_week, d.day_name, a.pickup_hour,
       ROUND(SUM(a.trip_count)::numeric / COUNT(DISTINCT a.pickup_date_key), 1)     AS trips_per_day,
       ROUND(SUM(a.wait_seconds_sum)::numeric / NULLIF(SUM(a.wait_count), 0) / 60, 2) AS avg_wait_min
FROM dw.agg_trips_zone_hour a
JOIN dw.dim_date d ON d.date_key = a.pickup_date_key
GROUP BY d.day_of_week, d.day_name, a.pickup_hour
ORDER BY d.day_of_week, a.pickup_hour;

-- Q3. Quận (borough) x giờ: thời gian chờ và chênh lệch so với cả thành phố --
WITH bh AS (
    SELECT z.borough, a.pickup_hour,
           SUM(a.trip_count)       AS trips,
           SUM(a.wait_seconds_sum) AS wait_sum,
           SUM(a.wait_count)       AS wait_n
    FROM dw.agg_trips_zone_hour a
    JOIN dw.dim_zone z ON z.zone_id = a.pu_zone_id
    GROUP BY z.borough, a.pickup_hour
)
SELECT borough, pickup_hour, trips,
       ROUND(wait_sum::numeric / NULLIF(wait_n, 0) / 60, 2) AS avg_wait_min,
       ROUND(
         (wait_sum::numeric / NULLIF(wait_n, 0))
         / NULLIF(SUM(wait_sum) OVER (PARTITION BY pickup_hour)::numeric
                  / NULLIF(SUM(wait_n) OVER (PARTITION BY pickup_hour), 0), 0), 2) AS wait_vs_city
FROM bh
ORDER BY borough, pickup_hour;

-- Q4. Top 15 khu vực - giờ thiếu xe (ngày thường) --------------------------
SELECT * FROM mart.fn_top_shortage('Ngày thường', 15);

-- Q5. Độ ổn định của tình trạng thiếu xe: trong các khu vực - giờ bị gắn cờ,
--     bao nhiêu % số ngày thường có thời gian chờ trung bình ngày đó vượt 1.25 lần
--     mặt bằng thành phố cùng ngày, cùng giờ? Cao = vấn đề lặp lại, không phải ngẫu nhiên.
WITH flagged AS (
    SELECT pu_zone_id, pickup_hour, zone_name
    FROM mart.v_shortage
    WHERE is_shortage AND day_type = 'Ngày thường'
),
daily AS (
    SELECT a.pickup_date_key, a.pu_zone_id, a.pickup_hour,
           SUM(a.wait_seconds_sum)::numeric / NULLIF(SUM(a.wait_count), 0) AS zone_wait,
           SUM(SUM(a.wait_seconds_sum)) OVER (PARTITION BY a.pickup_date_key, a.pickup_hour)::numeric
             / NULLIF(SUM(SUM(a.wait_count)) OVER (PARTITION BY a.pickup_date_key, a.pickup_hour), 0)
                                                                        AS city_wait
    FROM dw.agg_trips_zone_hour a
    JOIN dw.dim_date d ON d.date_key = a.pickup_date_key AND NOT d.is_weekend
    GROUP BY a.pickup_date_key, a.pu_zone_id, a.pickup_hour
)
SELECT f.zone_name, f.pickup_hour,
       COUNT(*)                                                     AS days_observed,
       SUM(CASE WHEN dl.zone_wait >= 1.25 * dl.city_wait THEN 1 ELSE 0 END) AS days_over,
       ROUND(AVG(CASE WHEN dl.zone_wait >= 1.25 * dl.city_wait THEN 1.0 ELSE 0 END) * 100, 1)
                                                                    AS pct_days_over
FROM flagged f
JOIN daily dl ON dl.pu_zone_id = f.pu_zone_id AND dl.pickup_hour = f.pickup_hour
GROUP BY f.zone_name, f.pickup_hour
ORDER BY pct_days_over DESC;

-- Q6. Cung - cầu: khu vực "hút" tài xế (nhiều chuyến đón hơn chuyến trả)
--     trong giờ cao điểm chiều ngày thường (17h-19h).
SELECT z.zone_name, z.borough,
       ROUND(SUM(fl.pickups_per_day), 1)    AS pickups_per_day,
       ROUND(SUM(fl.dropoffs_per_day), 1)   AS dropoffs_per_day,
       ROUND(SUM(fl.net_supply_per_day), 1) AS net_supply_per_day
FROM mart.mv_zone_hour_flow fl
JOIN dw.dim_zone z ON z.zone_id = fl.zone_id
WHERE fl.day_type = 'Ngày thường' AND fl.hour BETWEEN 17 AND 19
GROUP BY z.zone_name, z.borough
ORDER BY net_supply_per_day ASC
LIMIT 15;

-- Q7. Thu nhập tài xế theo giờ trong ngày: tiền nhận trên mỗi giờ chở khách --
SELECT a.pickup_hour,
       SUM(a.trip_count)                                                              AS trips,
       ROUND(SUM(a.driver_pay_sum) / NULLIF(SUM(a.trip_seconds_sum) / 3600.0, 0), 2)  AS pay_per_trip_hour,
       ROUND(SUM(a.driver_pay_sum) / SUM(a.trip_count), 2)                            AS pay_per_trip,
       ROUND(SUM(a.tips_sum) / NULLIF(SUM(a.driver_pay_sum), 0) * 100, 1)             AS tips_pct_of_pay
FROM dw.agg_trips_zone_hour a
GROUP BY a.pickup_hour
ORDER BY a.pickup_hour;

-- Q8. Sân bay so với phần còn lại (JFK = 132, LaGuardia = 138, Newark = 1) --
SELECT CASE WHEN a.pu_zone_id IN (1, 132, 138) THEN 'Sân bay' ELSE 'Khác' END     AS pickup_area,
       SUM(a.trip_count)                                                             AS trips,
       ROUND(SUM(a.wait_seconds_sum)::numeric / NULLIF(SUM(a.wait_count), 0) / 60, 2) AS avg_wait_min,
       ROUND(SUM(a.trip_miles_sum) / SUM(a.trip_count), 2)                           AS avg_trip_miles,
       ROUND(SUM(a.driver_pay_sum) / NULLIF(SUM(a.trip_seconds_sum) / 3600.0, 0), 2) AS pay_per_trip_hour
FROM dw.agg_trips_zone_hour a
GROUP BY 1;
