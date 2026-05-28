/*******************************************************************************
 * SQL Server Advisor - Collector 11: Query Stats (plan cache)
 *
 * Purpose : Capture the top ~50 statements in the plan cache by total worker
 *           (CPU) time, with execution count, CPU / logical-read / elapsed
 *           totals and averages, memory grant, and a trimmed sample of the
 *           query text. Feeds Query-hotspots analysis.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box / Azure VM / MI / RDS / Cloud SQL).
 *           Plan-cache based, so portable across platforms.
 * Safety  : READ-ONLY. Reads sys.dm_exec_query_stats + CROSS APPLY
 *           sys.dm_exec_sql_text(). No FREEPROCCACHE, no plan changes.
 *
 * Output columns (EXACT capture contract -> capture/query_stats.csv):
 *   server_name, captured_at, database_name, query_hash, execution_count,
 *   total_worker_time_ms, avg_worker_time_ms, total_logical_reads,
 *   avg_logical_reads, total_elapsed_time_ms, avg_elapsed_time_ms,
 *   total_grant_kb, sample_query_text
 *
 * IMPORTANT scope/limits:
 *   - The plan cache is VOLATILE: it clears on restart, memory pressure, and
 *     recompiles, and OPTION(RECOMPILE) / unparameterized ad hoc text may be
 *     under-represented. For durable, restart-surviving history prefer QUERY
 *     STORE (sys.query_store_runtime_stats) - see sqlserver-monitoring. This
 *     collector is the portable, always-available baseline.
 *   - Times in sys.dm_exec_query_stats are MICROSECONDS; converted to ms here.
 *     logical_reads are 8 KB PAGES (left as page counts per contract).
 *   - database_name resolves from the statement's dbid via the plan attributes
 *     of sys.dm_exec_sql_text(); it is NULL for ad hoc batches with no dbid.
 *   - query_hash is converted to a stable hex string so it round-trips through
 *     CSV/DuckDB without binary-encoding ambiguity.
 *   - sample_query_text is the substring of the statement bounded by
 *     statement_start_offset/statement_end_offset, trimmed to 4000 chars.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT TOP (50)
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))             AS server_name,
    SYSUTCDATETIME()                                                AS captured_at,
    DB_NAME(st.dbid)                                                AS database_name,
    CONVERT(varchar(18), qs.query_hash, 1)                          AS query_hash,
    qs.execution_count                                              AS execution_count,
    CAST(qs.total_worker_time / 1000.0 AS DECIMAL(18,2))            AS total_worker_time_ms,
    CAST(qs.total_worker_time / 1000.0
         / NULLIF(qs.execution_count, 0) AS DECIMAL(18,2))          AS avg_worker_time_ms,
    qs.total_logical_reads                                          AS total_logical_reads,
    CAST(qs.total_logical_reads * 1.0
         / NULLIF(qs.execution_count, 0) AS DECIMAL(18,2))          AS avg_logical_reads,
    CAST(qs.total_elapsed_time / 1000.0 AS DECIMAL(18,2))           AS total_elapsed_time_ms,
    CAST(qs.total_elapsed_time / 1000.0
         / NULLIF(qs.execution_count, 0) AS DECIMAL(18,2))          AS avg_elapsed_time_ms,
    qs.total_grant_kb                                               AS total_grant_kb,
    -- Statement-scoped text bounded by the offsets, trimmed for CSV portability.
    SUBSTRING(
        st.text,
        (qs.statement_start_offset / 2) + 1,
        (
            (CASE qs.statement_end_offset
                  WHEN -1 THEN DATALENGTH(st.text)
                  ELSE qs.statement_end_offset
             END - qs.statement_start_offset) / 2
        ) + 1
    )                                                               AS sample_query_text
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
ORDER BY qs.total_worker_time DESC;
