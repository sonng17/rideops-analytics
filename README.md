# RideOps Analytics

Operational analysis of NYC ride-hailing (Uber, Lyft) built on the warehouse produced by
[trip-data-pipeline](https://github.com/sonng17/trip-data-pipeline): where and when riders wait too long,
how demand and driver earnings move by hour, zone and weekday, and three data-backed recommendations.

**Stack:** PostgreSQL (views, materialized views, window functions, percentiles, PL/pgSQL function & procedure),
Power BI (data model + DAX), Excel (automated report with heatmaps), Python.

```
dw (star schema, project 1) ──▶ mart (SQL) ──▶ Power BI dashboard (4 pages)
                                          └──▶ Excel report ──▶ findings & recommendations
```

## Key questions

1. Which zone × hour cells have a rider-wait shortage, and is it persistent?
2. How do demand, wait time and driver pay per trip-hour vary by hour, weekday and borough?
3. What should operations do about it?

## Method: finding driver shortages

For each zone × hour × day type the wait is compared with the **city-wide weighted average for the same hour**.
A cell is flagged when its wait is ≥ 1.25× the city baseline **and** it is in the busier half of zones for that hour.
Cells are ranked by **excess wait minutes per day** = (zone wait − baseline) × trips per day,
which combines "how much longer" with "how many riders".
Persistence is checked day by day (share of weekdays above threshold).

## How to run

```bash
cp .env.example .env
make setup
make all            # create mart, refresh, reconcile, export Excel -> reports/rideops_report.xlsx
make analysis       # print analysis queries
```

Power BI: open Power BI Desktop → Get data → PostgreSQL → `localhost:5433` / `trips_dw`, then follow
`powerbi/measures.dax`.

## Repository

```
sql/01_mart.sql          mart schema: profile & flow materialized views, shortage view, function, procedure
sql/02_analysis.sql      8 analysis queries
sql/03_checks.sql        reconciliation across layers
scripts/export_excel.py  Excel report with conditional-format heatmaps
powerbi/measures.dax     DAX measures
powerbi/rideops.pbix     dashboard (add after building)
docs/findings.md         findings & 3 recommendations
```

## Findings

See [docs/findings.md](docs/findings.md). <!-- tóm tắt 3 đề xuất + ảnh dashboard -->
