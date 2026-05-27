/*******************************************************************************
 * SQL Server Monitoring - Query Store Analysis
 *
 * Purpose : Mine Query Store for top and regressed queries, plus a forced-plan
 *           inventory - the durable, restart-surviving alternative to the plan
 *           cache. Answers "what changed?" and "what is the heaviest query?".
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box, requires Query Store enabled), Managed
 *           Instance, Azure SQL Database (Query Store default-ON).
 * Safety  : Read-only. Does NOT force/unforce plans or clear the store
 *           (those are mutating; see references/query-store.md).
 *
 * Usage   : Run IN THE TARGET USER DATABASE (Query Store is database-scoped).
 *           Adjust @hours / @history_hours below.
 *
 * Sections:
 *   1. Query Store State & Storage Health (guard)
 *   2. Top Queries by Duration (last @hours)
 *   3. Regressed Queries (plan change made them slower)
 *   4. Forced-Plan Inventory
 *   5. Top Wait Categories per Query (2017+)
 ******************************************************************************/
SET NOCOUNT ON;

DECLARE @hours         INT = 24;     -- "recent" window for top/regressed queries
DECLARE @history_hours INT = 168;    -- baseline window for regression comparison (7 days)

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Query Store State & Storage Health (guard)
  All later sections only run if Query Store is ON for this database.
──────────────────────────────────────────────────────────────────────────────*/
IF NOT EXISTS (SELECT 1 FROM sys.databases
               WHERE database_id = DB_ID() AND is_query_store_on = 1)
BEGIN
    SELECT 'Query Store is NOT enabled on database [' + DB_NAME() + ']. '
         + 'Enable with: ALTER DATABASE [' + DB_NAME()
         + '] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);' AS info_message;
END
ELSE
BEGIN
    SELECT
        DB_NAME()                                       AS database_name,
        actual_state_desc,
        desired_state_desc,
        readonly_reason,                                -- non-zero => why it went READ_ONLY
        CAST(current_storage_size_mb AS DECIMAL(18,2))  AS used_mb,
        max_storage_size_mb,
        CAST(100.0 * current_storage_size_mb
             / NULLIF(max_storage_size_mb, 0) AS DECIMAL(5,2)) AS pct_full,
        interval_length_minutes,
        stale_query_threshold_days,
        query_capture_mode_desc,
        size_based_cleanup_mode_desc,
        wait_stats_capture_mode_desc                    -- 2017+
    FROM sys.database_query_store_options;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Top Queries by Duration (last @hours)
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND is_query_store_on = 1)
BEGIN
    SELECT TOP (25)
        q.query_id,
        p.plan_id,
        p.is_forced_plan,
        SUM(rs.count_executions)                        AS executions,
        CAST(SUM(rs.avg_duration  * rs.count_executions) / 1000.0
             / NULLIF(SUM(rs.count_executions), 0) AS DECIMAL(18,2)) AS avg_duration_ms,
        CAST(SUM(rs.avg_cpu_time  * rs.count_executions) / 1000.0
             / NULLIF(SUM(rs.count_executions), 0) AS DECIMAL(18,2)) AS avg_cpu_ms,
        CAST(SUM(rs.avg_logical_io_reads * rs.count_executions)
             / NULLIF(SUM(rs.count_executions), 0) AS BIGINT)        AS avg_logical_reads,
        SUBSTRING(qt.query_sql_text, 1, 300)            AS query_text_snippet
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS rsi
         ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    JOIN sys.query_store_plan       AS p  ON rs.plan_id = p.plan_id
    JOIN sys.query_store_query      AS q  ON p.query_id = q.query_id
    JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
    WHERE rsi.start_time >= DATEADD(HOUR, -@hours, SYSUTCDATETIME())
    GROUP BY q.query_id, p.plan_id, p.is_forced_plan, qt.query_sql_text
    ORDER BY avg_duration_ms DESC;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Regressed Queries (plan change made them slower)
  Compares a recent window against an older baseline window for the same query.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND is_query_store_on = 1)
BEGIN
    ;WITH recent AS
    (
        SELECT p.query_id, rs.plan_id,
               SUM(rs.avg_duration * rs.count_executions)
                   / NULLIF(SUM(rs.count_executions), 0) AS avg_dur,
               SUM(rs.count_executions) AS execs
        FROM sys.query_store_runtime_stats rs
        JOIN sys.query_store_runtime_stats_interval rsi
             ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
        JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
        WHERE rsi.start_time >= DATEADD(HOUR, -@hours, SYSUTCDATETIME())
        GROUP BY p.query_id, rs.plan_id
    ),
    hist AS
    (
        SELECT p.query_id,
               SUM(rs.avg_duration * rs.count_executions)
                   / NULLIF(SUM(rs.count_executions), 0) AS avg_dur
        FROM sys.query_store_runtime_stats rs
        JOIN sys.query_store_runtime_stats_interval rsi
             ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
        JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
        WHERE rsi.start_time >= DATEADD(HOUR, -@history_hours, SYSUTCDATETIME())
          AND rsi.start_time <  DATEADD(HOUR, -@hours,         SYSUTCDATETIME())
        GROUP BY p.query_id
    )
    SELECT TOP (25)
        r.query_id, r.plan_id,
        CAST(h.avg_dur / 1000.0 AS DECIMAL(18,2))       AS old_avg_ms,
        CAST(r.avg_dur / 1000.0 AS DECIMAL(18,2))       AS new_avg_ms,
        CAST((r.avg_dur - h.avg_dur) * 100.0
             / NULLIF(h.avg_dur, 0) AS DECIMAL(10,1))   AS pct_regression,
        r.execs,
        SUBSTRING(qt.query_sql_text, 1, 300)            AS query_text_snippet
    FROM recent r
    JOIN hist h ON r.query_id = h.query_id
    JOIN sys.query_store_query      q  ON r.query_id = q.query_id
    JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
    WHERE r.avg_dur > h.avg_dur * 1.5      -- >= 50% slower
      AND h.avg_dur > 1000                 -- ignore trivially fast queries (< 1 ms)
    ORDER BY pct_regression DESC;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Forced-Plan Inventory
  Lists every forced plan; force_failure_count > 0 means the force is no longer
  honored (e.g. an index was dropped) and SQL silently optimizes normally.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND is_query_store_on = 1)
BEGIN
    SELECT
        q.query_id,
        p.plan_id,
        p.is_forced_plan,
        p.force_failure_count,
        p.last_force_failure_reason_desc,
        p.last_execution_time,
        SUBSTRING(qt.query_sql_text, 1, 300)            AS query_text_snippet
    FROM sys.query_store_plan AS p
    JOIN sys.query_store_query      AS q  ON p.query_id = q.query_id
    JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
    WHERE p.is_forced_plan = 1
    ORDER BY q.query_id;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Top Wait Categories per Query (2017+)
  Requires WAIT_STATS_CAPTURE_MODE = ON. Guarded by column existence so it is
  safe on 2016 (where sys.query_store_wait_stats does not exist).
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND is_query_store_on = 1)
   AND EXISTS (SELECT 1 FROM sys.all_objects WHERE name = N'query_store_wait_stats' AND schema_id = SCHEMA_ID(N'sys'))
BEGIN
    SELECT TOP (25)
        q.query_id,
        qsws.wait_category_desc,
        SUM(qsws.total_query_wait_time_ms)              AS total_wait_ms,
        SUBSTRING(qt.query_sql_text, 1, 200)            AS query_text_snippet
    FROM sys.query_store_wait_stats AS qsws
    JOIN sys.query_store_plan       AS p  ON qsws.plan_id = p.plan_id
    JOIN sys.query_store_query      AS q  ON p.query_id = q.query_id
    JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
    JOIN sys.query_store_runtime_stats_interval AS rsi
         ON qsws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(HOUR, -@hours, SYSUTCDATETIME())
    GROUP BY q.query_id, qsws.wait_category_desc, qt.query_sql_text
    ORDER BY total_wait_ms DESC;
END;
