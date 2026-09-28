-- Optional. Requires confirmed Fabric workspace Admin.
-- Returns visible connections, potentially beyond the target Warehouse.
SELECT TOP (201)
    SYSUTCDATETIME() AS collected_at_utc,
    DB_ID() AS target_database_id,
    c.connection_id,
    c.connect_time,
    c.session_id,
    s.database_id AS session_current_database_id,
    s.login_time AS session_login_time,
    s.login_name,
    s.program_name,
    s.status AS session_status
FROM sys.dm_exec_connections AS c
LEFT JOIN sys.dm_exec_sessions AS s
    ON s.session_id = c.session_id
WHERE c.session_id <> @@SPID
ORDER BY c.connect_time, c.session_id, c.connection_id;
