/*******************************************************************************
 * SQL Server Monitoring - Active Requests (live "what is running now?")
 *
 * Purpose : Show everything currently executing: wait type/resource, blocking,
 *           CPU/reads, elapsed time, SQL text, query plan, and % complete for
 *           backup/restore/DBCC/index operations. A dependency-free equivalent
 *           of sp_whoisactive for ad-hoc live triage.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box), Managed Instance, Azure SQL Database.
 * Safety  : Read-only. No modifications. Never kills a session.
 *
 * Sections:
 *   1. Active User Requests (full detail)
 *   2. Long-Running Operations with % Complete (backup/restore/DBCC/rebuild)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Active User Requests (full detail)
  Excludes this session and system SPIDs; ordered by CPU consumed.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    r.session_id,
    r.status,
    r.command,
    r.wait_type,
    r.wait_time / 1000                                  AS wait_seconds,
    r.last_wait_type,
    r.wait_resource,
    r.blocking_session_id,
    r.open_transaction_count,
    r.cpu_time                                          AS cpu_ms,
    r.total_elapsed_time / 1000                         AS elapsed_seconds,
    r.logical_reads,
    r.reads                                             AS physical_reads,
    r.writes,
    r.granted_query_memory * 8 / 1024                   AS granted_memory_mb,
    r.dop                                               AS degree_of_parallelism,  -- 2016+
    DB_NAME(r.database_id)                              AS database_name,
    s.login_name,
    s.host_name,
    s.program_name,
    s.last_request_start_time,
    s.transaction_isolation_level,
    SUBSTRING(t.text,
        r.statement_start_offset / 2 + 1,
        (CASE WHEN r.statement_end_offset = -1
              THEN DATALENGTH(t.text)
              ELSE r.statement_end_offset END
         - r.statement_start_offset) / 2 + 1)           AS current_statement,
    t.text                                              AS full_batch_text,
    qp.query_plan
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle)     AS t
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle)  AS qp
WHERE r.session_id <> @@SPID
  AND s.is_user_process = 1
ORDER BY r.cpu_time DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Long-Running Operations with % Complete
  percent_complete is populated for BACKUP, RESTORE, DBCC CHECK*, index
  rebuild/reorg, rollback, and a few others - gives an ETA.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    r.session_id,
    r.command,
    DB_NAME(r.database_id)                              AS database_name,
    CAST(r.percent_complete AS DECIMAL(5,2))            AS percent_complete,
    r.total_elapsed_time / 1000                         AS elapsed_seconds,
    -- Estimated time remaining from current progress rate
    CAST(r.estimated_completion_time / 1000.0 AS DECIMAL(18,1)) AS est_seconds_remaining,
    DATEADD(SECOND, r.estimated_completion_time / 1000, GETDATE()) AS est_completion_time,
    r.wait_type,
    r.cpu_time                                          AS cpu_ms,
    SUBSTRING(t.text,
        r.statement_start_offset / 2 + 1,
        (CASE WHEN r.statement_end_offset = -1
              THEN DATALENGTH(t.text)
              ELSE r.statement_end_offset END
         - r.statement_start_offset) / 2 + 1)           AS current_statement
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.percent_complete > 0
ORDER BY r.percent_complete DESC;
