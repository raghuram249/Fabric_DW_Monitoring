/*
Wipro - Microsoft Fabric Warehouse workload / WLM assessment
Prepared 2026-09-28. Customer-run, SELECT-only collection.

Read COLLECTION-GUIDE.txt before running. Execute numbered sections separately
in SSMS or the Fabric SQL query editor, connected to each relevant Warehouse.
No customer endpoint was used to prepare this script.

WINDOW: replace BOTH literals in EACH windowed section.
Default: 2026-09-14 00:00 UTC inclusive to 2026-09-28 00:00 UTC exclusive.
For large histories, run one day at a time and retain all result rows.
Use an approved local export destination, not a truncated results-grid copy.

Sections 1/2: context and available columns.
Section 3: completed-request detail, attributed to completion date.
Sections 4/5: submitted-request cohorts, containing only completed requests.
Section 6: historical request-interval concurrency, NOT worker concurrency.
Section 7: SQL-pool state-change events, including preceding state.
Section 8: optional SQL text for a small, explicitly selected query shape.
Section 9: daily request-volume and successful-latency summary by SQL pool.

History covers user-context requests, not all system activity. Query Insights
retains 30 days and publication can lag 15 minutes or more under heavy load.
All dates and buckets here are UTC. Confirm the customer's business-day zone.
CPU allocation is not actual CPU utilization and is NOT billed CU(s).
NULL metric values remain unknown; SUM/AVG ignore NULLs.
*/

-- 1. Record the connection context. Confirm it before proceeding.
SELECT
    SYSUTCDATETIME() AS collected_at_utc,
    DB_NAME() AS current_database,
    DB_ID() AS current_database_id,
    @@SPID AS diagnostic_session_id;

-- 2. Record exposed schemas. Missing columns are a collection gap, not zero.
SELECT
    s.name AS schema_name,
    o.name AS view_name,
    c.column_id,
    c.name AS column_name,
    t.name AS data_type
FROM sys.schemas AS s
JOIN sys.objects AS o ON o.schema_id = s.schema_id
JOIN sys.columns AS c ON c.object_id = o.object_id
JOIN sys.types AS t ON t.user_type_id = c.user_type_id
WHERE s.name = 'queryinsights'
  AND o.name IN ('exec_requests_history', 'sql_pool_insights')
ORDER BY o.name, c.column_id;

-- 3. PRIMARY EXPORT: every visible request completed in the window, no TOP.
-- Long requests submitted before the window are deliberately retained.
-- SQL text is excluded by default; identity/label fields remain sensitive.
WITH collection_window AS
(
    SELECT
        CAST('2026-09-14T00:00:00' AS datetime2(6)) AS from_utc,
        CAST('2026-09-28T00:00:00' AS datetime2(6)) AS to_utc
)
SELECT
    SYSUTCDATETIME() AS collected_at_utc,
    DB_NAME() AS source_warehouse,
    h.distributed_statement_id,
    h.database_name,
    h.submit_time,
    h.start_time,
    h.end_time,
    h.statement_type,
    h.status,
    h.error_code,
    h.total_elapsed_time_ms,
    DATEDIFF_BIG(millisecond, h.submit_time, h.start_time)
        AS submit_to_start_ms,
    h.allocated_cpu_time_ms,
    h.data_scanned_remote_storage_mb,
    h.data_scanned_memory_mb,
    h.data_scanned_disk_mb,
    h.row_count,
    h.login_name,
    h.program_name,
    h.sql_pool_name,
    h.query_hash,
    h.label,
    h.result_cache_hit,
    h.is_distributed,
    h.session_id,
    h.connection_id,
    h.batch_id,
    h.root_batch_id
FROM queryinsights.exec_requests_history AS h
CROSS JOIN collection_window AS w
WHERE h.end_time >= w.from_utc
  AND h.end_time < w.to_utc;

-- 4. HOURLY WORKLOAD MIX: application, pool, statement type, outcome and cost.
-- Latency percentiles below cover SUCCEEDED requests only.
-- Query counts/CPU cover all reported outcomes.
-- Whole-request metrics are assigned to submit hour, NOT apportioned across
-- execution hours. These are cohort totals, not instantaneous utilization.
WITH collection_window AS
(
    SELECT
        CAST('2026-09-14T00:00:00' AS datetime2(6)) AS from_utc,
        CAST('2026-09-28T00:00:00' AS datetime2(6)) AS to_utc
),
base AS
(
    SELECT
        DATEADD(hour, DATEDIFF(hour, CAST('2000-01-01' AS datetime2(6)),
            h.submit_time), CAST('2000-01-01' AS datetime2(6)))
            AS submit_hour_utc,
        h.*
    FROM queryinsights.exec_requests_history AS h
    CROSS JOIN collection_window AS w
    WHERE h.submit_time >= w.from_utc
      AND h.submit_time < w.to_utc
),
with_percentiles AS
(
    SELECT *,
        PERCENTILE_CONT(0.50) WITHIN GROUP
        (ORDER BY CASE WHEN status = 'Succeeded'
            THEN total_elapsed_time_ms END)
        OVER (PARTITION BY submit_hour_utc, program_name, sql_pool_name,
            statement_type) AS p50_success_ms,
        PERCENTILE_CONT(0.95) WITHIN GROUP
        (ORDER BY CASE WHEN status = 'Succeeded'
            THEN total_elapsed_time_ms END)
        OVER (PARTITION BY submit_hour_utc, program_name, sql_pool_name,
            statement_type) AS p95_success_ms
    FROM base
)
SELECT
    submit_hour_utc,
    program_name,
    sql_pool_name,
    statement_type,
    COUNT_BIG(*) AS completed_requests_in_submit_cohort,
    SUM(CAST(CASE WHEN status = 'Succeeded' THEN 1 ELSE 0 END AS bigint))
        AS succeeded_requests,
    SUM(CAST(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END AS bigint))
        AS failed_requests,
    SUM(CAST(CASE WHEN status = 'Canceled' THEN 1 ELSE 0 END AS bigint))
        AS canceled_requests,
    SUM(CAST(CASE WHEN status IS NULL
        OR status NOT IN ('Succeeded', 'Failed', 'Canceled')
        THEN 1 ELSE 0 END AS bigint)) AS other_or_unknown_status,
    COUNT(DISTINCT login_name) AS distinct_known_logins,
    AVG(CASE WHEN status = 'Succeeded'
        THEN CAST(total_elapsed_time_ms AS decimal(19,3)) END)
        AS avg_success_ms,
    MAX(p50_success_ms) AS p50_success_ms,
    MAX(p95_success_ms) AS p95_success_ms,
    MAX(total_elapsed_time_ms) AS max_elapsed_ms_all_statuses,
    SUM(CAST(allocated_cpu_time_ms AS decimal(28,3))) / 1000.0
        AS allocated_cpu_seconds,
    COUNT_BIG(allocated_cpu_time_ms) AS requests_with_cpu_metric,
    SUM(data_scanned_remote_storage_mb) AS remote_scan_mb,
    SUM(data_scanned_memory_mb) AS memory_scan_mb,
    SUM(data_scanned_disk_mb) AS disk_scan_mb,
    SUM(CAST(CASE WHEN result_cache_hit = 2 THEN 1 ELSE 0 END AS bigint))
        AS result_cache_hits
FROM with_percentiles
GROUP BY submit_hour_utc, program_name, sql_pool_name, statement_type
ORDER BY submit_hour_utc, allocated_cpu_seconds DESC;

-- 5. QUERY-SHAPE RANKING: recurring cost and latency by application and pool.
-- No TOP: retain the full ranking. NULL hashes are not one logical query shape.
WITH collection_window AS
(
    SELECT
        CAST('2026-09-14T00:00:00' AS datetime2(6)) AS from_utc,
        CAST('2026-09-28T00:00:00' AS datetime2(6)) AS to_utc
)
SELECT
    h.query_hash,
    h.program_name,
    h.sql_pool_name,
    h.statement_type,
    h.status,
    COUNT_BIG(*) AS executions,
    MIN(h.submit_time) AS first_submit_utc,
    MAX(h.submit_time) AS last_submit_utc,
    AVG(CAST(h.total_elapsed_time_ms AS decimal(19,3))) AS avg_elapsed_ms,
    MAX(h.total_elapsed_time_ms) AS max_elapsed_ms,
    SUM(CAST(h.allocated_cpu_time_ms AS decimal(28,3))) / 1000.0
        AS allocated_cpu_seconds,
    COUNT_BIG(h.allocated_cpu_time_ms) AS requests_with_cpu_metric,
    SUM(h.data_scanned_remote_storage_mb) AS remote_scan_mb,
    SUM(h.data_scanned_memory_mb) AS memory_scan_mb,
    SUM(h.data_scanned_disk_mb) AS disk_scan_mb,
    SUM(CAST(CASE WHEN h.result_cache_hit = 2 THEN 1 ELSE 0 END AS bigint))
        AS result_cache_hits
FROM queryinsights.exec_requests_history AS h
CROSS JOIN collection_window AS w
WHERE h.submit_time >= w.from_utc
  AND h.submit_time < w.to_utc
GROUP BY h.query_hash, h.program_name, h.sql_pool_name,
    h.statement_type, h.status
ORDER BY allocated_cpu_seconds DESC, executions DESC;

-- 6. HISTORICAL PEAK REQUEST OVERLAP, per pool, for the chosen window.
-- Uses [start_time,end_time) intervals and includes carry-in requests.
-- Requests still running / not yet published are absent: this is incomplete
-- near the collection boundary. Waiting within an interval still counts.
-- NULL/empty pool is retained; it can represent non-distributed requests.
-- A zero-duration request contributes no interval. Missing timestamps cannot
-- be reconstructed. This is not the number of simultaneously executing tasks.
WITH collection_window AS
(
    SELECT
        CAST('2026-09-14T00:00:00' AS datetime2(6)) AS from_utc,
        CAST('2026-09-28T00:00:00' AS datetime2(6)) AS to_utc
),
intervals AS
(
    SELECT
        h.sql_pool_name,
        CASE WHEN h.start_time < w.from_utc
            THEN w.from_utc ELSE h.start_time END AS interval_start,
        CASE WHEN h.end_time > w.to_utc
            THEN w.to_utc ELSE h.end_time END AS interval_end
    FROM queryinsights.exec_requests_history AS h
    CROSS JOIN collection_window AS w
    WHERE h.start_time < w.to_utc
      AND h.end_time > w.from_utc
      AND h.end_time > h.start_time
),
events AS
(
    SELECT sql_pool_name, interval_start AS event_time, CAST(1 AS bigint) AS delta
    FROM intervals
    UNION ALL
    SELECT sql_pool_name, interval_end, CAST(-1 AS bigint)
    FROM intervals
),
net_events AS
(
    SELECT sql_pool_name, event_time, SUM(delta) AS delta
    FROM events
    GROUP BY sql_pool_name, event_time
),
overlap AS
(
    SELECT sql_pool_name, event_time,
        SUM(delta) OVER
        (PARTITION BY sql_pool_name ORDER BY event_time
            ROWS UNBOUNDED PRECEDING) AS overlapping_requests
    FROM net_events
),
ranked AS
(
    SELECT *,
        ROW_NUMBER() OVER
        (PARTITION BY sql_pool_name
            ORDER BY overlapping_requests DESC, event_time) AS peak_rank
    FROM overlap
)
SELECT
    sql_pool_name,
    event_time AS first_peak_time_utc,
    overlapping_requests AS peak_observed_request_overlap
FROM ranked
WHERE peak_rank = 1
ORDER BY peak_observed_request_overlap DESC;

-- 7. POOL CONFIGURATION/PRESSURE EVENTS plus last retained pre-window event.
-- Event rows are NOT periodic samples. Do not compute pressure percentage as
-- COUNT(pressure rows) / COUNT(all rows). Logging can pause during inactivity.
WITH collection_window AS
(
    SELECT
        CAST('2026-09-14T00:00:00' AS datetime2(6)) AS from_utc,
        CAST('2026-09-28T00:00:00' AS datetime2(6)) AS to_utc
),
prior_events AS
(
    SELECT p.*,
        ROW_NUMBER() OVER
        (PARTITION BY p.sql_pool_name ORDER BY p.[timestamp] DESC) AS rn
    FROM queryinsights.sql_pool_insights AS p
    CROSS JOIN collection_window AS w
    WHERE p.[timestamp] < w.from_utc
),
selected_events AS
(
    SELECT
        p.sql_pool_name, p.[timestamp], p.max_resource_percentage,
        p.is_optimized_for_reads, p.current_workspace_capacity,
        p.is_pool_under_pressure,
        'LAST_RETAINED_PRE_WINDOW_EVENT' AS event_scope
    FROM prior_events AS p
    WHERE p.rn = 1
    UNION ALL
    SELECT
        p.sql_pool_name, p.[timestamp], p.max_resource_percentage,
        p.is_optimized_for_reads, p.current_workspace_capacity,
        p.is_pool_under_pressure,
        'IN_WINDOW_EVENT'
    FROM queryinsights.sql_pool_insights AS p
    CROSS JOIN collection_window AS w
    WHERE p.[timestamp] >= w.from_utc
      AND p.[timestamp] < w.to_utc
)
SELECT *
FROM selected_events
ORDER BY sql_pool_name, [timestamp];

/*
8. OPTIONAL TARGETED TEXT - disabled by default.
After customer approval, replace the hash and dates and execute separately.
Text can contain confidential literals or credentials; review/redact locally.
TOP (20) here is a deliberate sample, not the full workload export.

SELECT TOP (20)
    distributed_statement_id,
    submit_time,
    status,
    error_code,
    total_elapsed_time_ms,
    allocated_cpu_time_ms,
    query_hash,
    program_name,
    sql_pool_name,
    command
FROM queryinsights.exec_requests_history
WHERE query_hash = '<query_hash_from_section_5>'
  AND submit_time >= CAST('2026-09-14T00:00:00' AS datetime2(6))
  AND submit_time < CAST('2026-09-28T00:00:00' AS datetime2(6))
ORDER BY total_elapsed_time_ms DESC;
*/

-- 9. DAILY SUMMARY by UTC submission day and pool.
-- As in section 4, only completed/published requests are available.
-- Daily percentiles are calculated from requests, not hourly percentiles.
WITH collection_window AS
(
    SELECT
        CAST('2026-09-14T00:00:00' AS datetime2(6)) AS from_utc,
        CAST('2026-09-28T00:00:00' AS datetime2(6)) AS to_utc
),
base AS
(
    SELECT
        CAST(h.submit_time AS date) AS submit_day_utc,
        h.sql_pool_name,
        h.status,
        h.total_elapsed_time_ms,
        h.allocated_cpu_time_ms,
        h.data_scanned_remote_storage_mb
    FROM queryinsights.exec_requests_history AS h
    CROSS JOIN collection_window AS w
    WHERE h.submit_time >= w.from_utc
      AND h.submit_time < w.to_utc
),
with_percentiles AS
(
    SELECT *,
        PERCENTILE_CONT(0.50) WITHIN GROUP
        (ORDER BY CASE WHEN status = 'Succeeded'
            THEN total_elapsed_time_ms END)
        OVER (PARTITION BY submit_day_utc, sql_pool_name) AS p50_success_ms,
        PERCENTILE_CONT(0.95) WITHIN GROUP
        (ORDER BY CASE WHEN status = 'Succeeded'
            THEN total_elapsed_time_ms END)
        OVER (PARTITION BY submit_day_utc, sql_pool_name) AS p95_success_ms
    FROM base
)
SELECT
    submit_day_utc,
    sql_pool_name,
    COUNT_BIG(*) AS completed_requests_in_submit_cohort,
    SUM(CAST(CASE WHEN status = 'Succeeded' THEN 1 ELSE 0 END AS bigint))
        AS succeeded_requests,
    SUM(CAST(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END AS bigint))
        AS failed_requests,
    SUM(CAST(CASE WHEN status = 'Canceled' THEN 1 ELSE 0 END AS bigint))
        AS canceled_requests,
    SUM(CAST(CASE WHEN status IS NULL
        OR status NOT IN ('Succeeded', 'Failed', 'Canceled')
        THEN 1 ELSE 0 END AS bigint)) AS other_or_unknown_status,
    AVG(CASE WHEN status = 'Succeeded'
        THEN CAST(total_elapsed_time_ms AS decimal(19,3)) END)
        AS avg_success_ms,
    MAX(p50_success_ms) AS p50_success_ms,
    MAX(p95_success_ms) AS p95_success_ms,
    MAX(total_elapsed_time_ms) AS max_elapsed_ms_all_statuses,
    SUM(CAST(allocated_cpu_time_ms AS decimal(28,3))) / 1000.0
        AS allocated_cpu_seconds,
    COUNT_BIG(allocated_cpu_time_ms) AS requests_with_cpu_metric,
    SUM(data_scanned_remote_storage_mb) AS remote_scan_mb
FROM with_percentiles
GROUP BY submit_day_utc, sql_pool_name
ORDER BY submit_day_utc, sql_pool_name;
