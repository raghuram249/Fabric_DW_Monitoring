-- Fabric Warehouse only. Run on a separate diagnostic connection.
-- TOP (0) probes check column binding, not all-user visibility.
SELECT
    SYSUTCDATETIME() AS collected_at_utc,
    DB_NAME() AS current_database,
    DB_ID() AS current_database_id,
    @@SPID AS diagnostic_session_id;

SELECT TOP (0)
    session_id, database_id, login_time, login_name, program_name, status,
    last_request_start_time, last_request_end_time, open_transaction_count
FROM sys.dm_exec_sessions;

SELECT TOP (0)
    session_id, request_id, database_id, start_time, status, command,
    total_elapsed_time, blocking_session_id, wait_type, wait_time,
    open_transaction_count
FROM sys.dm_exec_requests;

SELECT TOP (0)
    request_session_id, resource_database_id, resource_type,
    resource_associated_entity_id, resource_description,
    request_mode, request_status
FROM sys.dm_tran_locks;
