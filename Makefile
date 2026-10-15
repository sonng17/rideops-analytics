PSQL = psql -v ON_ERROR_STOP=1 -h localhost -p 5433 -U dw -d trips_dw

.PHONY: setup mart refresh analysis checks excel all

setup:      ## Tạo venv và cài thư viện
	python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

mart:       ## Tạo schema mart (view, materialized view, function, procedure)
	$(PSQL) -f sql/01_mart.sql

refresh:    ## Làm mới materialized view sau khi project 1 nạp tháng mới
	$(PSQL) -c "CALL mart.sp_refresh_marts();"

analysis:   ## Chạy các truy vấn phân tích
	$(PSQL) -f sql/02_analysis.sql

checks:     ## Đối chiếu số liệu giữa các lớp
	$(PSQL) -f sql/03_checks.sql

excel:      ## Xuất báo cáo Excel
	.venv/bin/python scripts/export_excel.py

all: mart refresh checks excel
