/*******************************************************************************
 * SQL Server - Parameter Sniffing Detection (Query Store)
 *
 * Purpose : Identify queries whose runtime varies wildly (max >> avg) and that
 *           have MULTIPLE plans - the classic fingerprint of parameter-
 *           sensitive (sniffed) plans over skewed data.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x) with Query Store ENABLED;
 *           Azure SQL DB / Managed Instance (Query Store on by default).
 * Safety  : READ-ONLY. No plans are forced and no hints are applied.
 *
 * Sections:
 *   0. Guard: confirm Query Store is ON for this database
 *   1. Queries with high duration variance AND multiple plans
 *   2. Plan count per query (multi-plan queries ranked)
 *
 * FIX (do NOT do here): see SKILL.md / query-optimization.md for the full
 *   mitigation ladder - Query Store plan forcing/hints (2022), PSP (2022),
 *   OPTIMIZE FOR UNKNOWN, OPTION (RECOMPILE). Query Store OPERATION/config
 *   lives in sqlserver-monitoring.
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 0: Guard - Query Store must be ON
──────────────────────────────────────────────────────────────────────────────*/
IF (SELECT is_query_store_on FROM sys.databases WHERE database_id = DB_ID()) <> 1
BEGIN
    SELECT 'Query Store is NOT enabled for this database. Enable it (see '
         + 'sqlserver-monitoring) before running the analysis below.'
                                                AS info_message;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: High Duration Variance + Multiple Plans (last 7 days)
  Aggregated across runtime-stats intervals; durations are in microseconds.
──────────────────────────────────────────────────────────────────────────────*/
;WITH q AS (
    SELECT
        q.query_id,
        COUNT(DISTINCT p.plan_id)               AS plan_count,
        SUM(rs.count_executions)                AS total_executions,
        CAST(MAX(rs.max_duration)   / 1000.0 AS decimal(18,2)) AS max_duration_ms,
        CAST(AVG(rs.avg_duration)   / 1000.0 AS decimal(18,2)) AS avg_duration_ms,
        CAST(MIN(rs.min_duration)   / 1000.0 AS decimal(18,2)) AS min_duration_ms
    FROM sys.query_store_query                  AS q
    JOIN sys.query_store_plan                   AS p
        ON p.query_id = q.query_id
    JOIN sys.query_store_runtime_stats          AS rs
        ON rs.plan_id = p.plan_id
    JOIN sys.query_store_runtime_stats_interval AS rsi
        ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(DAY, -7, SYSUTCDATETIME())
    GROUP BY q.query_id
)
SELECT
    q.query_id,
    qt.query_sql_text,
    q.plan_count,
    q.total_executions,
    q.min_duration_ms,
    q.avg_duration_ms,
    q.max_duration_ms,
    CASE WHEN q.avg_duration_ms > 0
         THEN CAST(q.max_duration_ms / q.avg_duration_ms AS decimal(10,1))
         ELSE NULL END                          AS max_to_avg_ratio,
    'SUSPECT parameter sniffing: variance + multiple plans. See the '
        + 'mitigation ladder in query-optimization.md before acting.'
                                                AS recommendation
FROM q
JOIN sys.query_store_query      AS qq ON qq.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = qq.query_text_id
WHERE q.plan_count > 1
  AND q.max_duration_ms > q.avg_duration_ms * 5     -- high variance
  AND q.total_executions >= 10                      -- ignore rare one-offs
ORDER BY max_to_avg_ratio DESC, q.total_executions DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Plan Count per Query (multi-plan queries ranked)
  Many plans for one query => plan instability / sniffing / recompiles.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    q.query_id,
    COUNT(DISTINCT p.plan_id)                   AS plan_count,
    MIN(p.initial_compile_start_time)           AS first_compiled,
    MAX(p.last_compile_start_time)              AS last_compiled,
    SUBSTRING(qt.query_sql_text, 1, 300)        AS query_text_sample
FROM sys.query_store_query      AS q
JOIN sys.query_store_plan       AS p  ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
GROUP BY q.query_id, SUBSTRING(qt.query_sql_text, 1, 300)
HAVING COUNT(DISTINCT p.plan_id) > 1
ORDER BY plan_count DESC;
