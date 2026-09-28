-- Target-database scope. 501 rows signals the 500-row reporting limit.
-- Return raw statuses, including grants, waits and conversion requests.
SELECT TOP (501)
    SYSUTCDATETIME() AS collected_at_utc,
    l.resource_database_id,
    l.request_session_id,
    l.resource_type,
    l.resource_associated_entity_id,
    l.resource_description,
    l.request_mode,
    l.request_status,
    CASE
        WHEN l.request_status IN
            ('WAIT', 'CONVERT', 'LOW_PRIORITY_WAIT', 'LOW_PRIORITY_CONVERT')
            THEN 'WAIT_OR_CONVERSION'
        WHEN l.request_status IN ('GRANT', 'GRANTED') THEN 'GRANTED'
        ELSE 'OTHER_STATUS_REVIEW'
    END AS lock_state_group
FROM sys.dm_tran_locks AS l
WHERE l.resource_database_id = DB_ID()
    AND l.request_session_id <> @@SPID
ORDER BY
    CASE
        WHEN l.request_status IN
            ('WAIT', 'CONVERT', 'LOW_PRIORITY_WAIT', 'LOW_PRIORITY_CONVERT') THEN 0
        WHEN l.request_status IN ('GRANT', 'GRANTED') THEN 2
        ELSE 1
    END,
    l.request_session_id,
    l.resource_type,
    l.resource_associated_entity_id;
