/*******************************************************************************
 * SQL Server Monitoring - Top Queries by CPU
 *
 * Purpose : Identify the most CPU-intensive statements from the plan cache,
 *           by both total and average worker time. STEP 2 of the workflow when
 *           waits point at CPU (SOS_SCHEDULER_YIELD, high signal-wait %).
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box), Managed Instance, Azure SQL Database.
 * Safety  : Read-only. No modifications.
 *
 * Notes   : sys.dm_exec_query_stats reflects only CACHED plans and resets on
 *           restart / memory pressure / recompile. For durable history use
 *           Query Store (see 09-query-store-analysis.sql).
 *
 * Sections:
 *   1. Top 20 Statements by TOTAL CPU
 *   2. Top 20 Statements by AVERAGE CPU per Execution
 *   3. Top Stored Procedures by Total CPU
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Top 20 Statements by TOTAL CPU
  Total CPU = the queries consuming the most aggregate CPU across all executions.
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (20)
    qs.execution_count,
    qs.total_worker_time / 1000                         AS total_cpu_ms,
    qs.total_worker_time / NULLIF(qs.execution_count, 0) / 1000 AS avg_cpu_ms,
    qs.total_elapsed_time / 1000                        AS total_elapsed_ms,
    qs.total_logical_reads,
    qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_logical_reads,
    qs.creation_time,
    qs.last_execution_time,
    DB_NAME(qt.dbid)                                    AS database_name,
    SUBSTRING(qt.text,
        qs.statement_start_offset / 2 + 1,
        (CASE WHEN qs.statement_end_offset = -1
              THEN DATALENGTH(qt.text)
              ELSE qs.statement_end_offset END
         - qs.statement_start_offset) / 2 + 1)          AS statement_text,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS qt
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
ORDER BY qs.total_worker_time DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Top 20 Statements by AVERAGE CPU per Execution
  Surfaces expensive-per-run queries that may not yet have run often.
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (20)
    qs.total_worker_time / NULLIF(qs.execution_count, 0) / 1000 AS avg_cpu_ms,
    qs.execution_count,
    qs.total_worker_time / 1000                         AS total_cpu_ms,
    qs.total_elapsed_time / NULLIF(qs.execution_count, 0) / 1000 AS avg_elapsed_ms,
    qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_logical_reads,
    qs.last_execution_time,
    DB_NAME(qt.dbid)                                    AS database_name,
    SUBSTRING(qt.text,
        qs.statement_start_offset / 2 + 1,
        (CASE WHEN qs.statement_end_offset = -1
              THEN DATALENGTH(qt.text)
              ELSE qs.statement_end_offset END
         - qs.statement_start_offset) / 2 + 1)          AS statement_text,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS qt
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.execution_count > 1                            -- ignore one-off ad-hoc
ORDER BY (qs.total_worker_time / NULLIF(qs.execution_count, 0)) DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Top Stored Procedures by Total CPU
  Procedure-level aggregation (sys.dm_exec_procedure_stats).
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (20)
    DB_NAME(ps.database_id)                             AS database_name,
    OBJECT_SCHEMA_NAME(ps.object_id, ps.database_id) + N'.' +
        OBJECT_NAME(ps.object_id, ps.database_id)       AS procedure_name,
    ps.execution_count,
    ps.total_worker_time / 1000                         AS total_cpu_ms,
    ps.total_worker_time / NULLIF(ps.execution_count, 0) / 1000 AS avg_cpu_ms,
    ps.total_elapsed_time / 1000                        AS total_elapsed_ms,
    ps.total_logical_reads,
    ps.last_execution_time,
    qp.query_plan
FROM sys.dm_exec_procedure_stats AS ps
OUTER APPLY sys.dm_exec_query_plan(ps.plan_handle) AS qp
ORDER BY ps.total_worker_time DESC;
