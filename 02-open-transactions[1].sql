-- Visible-session scope, not proof of transactions in the target database.
-- Anchor on sessions so an idle owner is not lost when it has no request.
WITH active_requests AS
(
    SELECT session_id, COUNT(*) AS active_request_count
    FROM sys.dm_exec_requests
    GROUP BY session_id
)
SELECT TOP (201)
    SYSUTCDATETIME() AS collected_at_utc,
    DB_ID() AS target_database_id,
    s.database_id AS session_current_database_id,
    s.session_id,
    s.login_time AS session_login_time,
    s.login_name,
    s.program_name,
    s.status AS session_status,
    s.open_transaction_count AS session_open_transaction_count,
    s.last_request_start_time,
    s.last_request_end_time,
    COALESCE(a.active_request_count, 0) AS observed_active_request_count,
    CASE WHEN a.session_id IS NULL THEN 1 ELSE 0 END AS is_idle_candidate
FROM sys.dm_exec_sessions AS s
LEFT JOIN active_requests AS a
    ON a.session_id = s.session_id
WHERE s.open_transaction_count > 0
    AND s.session_id <> @@SPID
ORDER BY
    CASE WHEN a.session_id IS NULL THEN 0 ELSE 1 END,
    s.last_request_end_time,
    s.session_id;
