-- 201 rows means the 200-row reporting limit was exceeded.
-- Waiting/suspended requests are deliberately retained.
SELECT TOP (201)
    SYSUTCDATETIME() AS collected_at_utc,
    r.database_id,
    r.session_id,
    r.request_id,
    r.start_time,
    r.status AS request_status,
    r.command AS command_type,
    r.total_elapsed_time / 1000.0 AS elapsed_seconds,
    CASE WHEN r.total_elapsed_time >= 300000 THEN 1 ELSE 0 END AS is_long_running,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time AS wait_time_ms,
    r.open_transaction_count AS request_open_transaction_count,
    s.login_time AS session_login_time,
    s.login_name,
    s.program_name
FROM sys.dm_exec_requests AS r
LEFT JOIN sys.dm_exec_sessions AS s
    ON s.session_id = r.session_id
WHERE r.database_id = DB_ID()
    AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC, r.session_id, r.request_id;
