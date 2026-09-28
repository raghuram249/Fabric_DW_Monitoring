-- All visible databases: retain upstream cross-database blocking leads.
-- LEFT JOIN preserves idle, inaccessible and no-longer-visible blockers.
SELECT TOP (201)
    SYSUTCDATETIME() AS collected_at_utc,
    DB_ID() AS target_database_id,
    r.database_id AS blocked_request_database_id,
    r.session_id AS blocked_session_id,
    r.request_id AS blocked_request_id,
    r.start_time AS blocked_request_start_time,
    r.status AS blocked_request_status,
    r.command AS blocked_command_type,
    r.total_elapsed_time / 1000.0 AS blocked_request_elapsed_seconds,
    r.wait_type,
    r.wait_time AS wait_time_ms,
    r.open_transaction_count AS blocked_request_open_transaction_count,
    r.blocking_session_id,
    b.login_time AS blocker_session_login_time,
    b.login_name AS blocker_login_name,
    b.program_name AS blocker_program_name,
    b.database_id AS blocker_session_current_database_id,
    b.status AS blocker_session_status,
    b.open_transaction_count AS blocker_open_transaction_count,
    b.last_request_start_time AS blocker_last_request_start_time,
    b.last_request_end_time AS blocker_last_request_end_time,
    CASE
        WHEN r.blocking_session_id < 0 THEN 'SPECIAL_BLOCKER_VALUE'
        WHEN b.session_id IS NULL THEN 'SESSION_NOT_VISIBLE_OR_CHANGED'
        ELSE 'SESSION_VISIBLE'
    END AS blocker_resolution
FROM sys.dm_exec_requests AS r
LEFT JOIN sys.dm_exec_sessions AS b
    ON b.session_id = r.blocking_session_id
WHERE r.blocking_session_id <> 0
    AND r.session_id <> @@SPID
ORDER BY
    CASE WHEN r.database_id = DB_ID() THEN 0 ELSE 1 END,
    r.total_elapsed_time DESC,
    r.session_id,
    r.request_id;
