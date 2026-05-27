/*******************************************************************************
 * SQL Server Monitoring - Top Queries by I/O
 *
 * Purpose : Identify the most I/O-intensive statements from the plan cache, by
 *           logical reads, physical reads, and writes. STEP 2 of the workflow
 *           when waits point at I/O (PAGEIOLATCH_*, low PLE, memory churn).
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box), Managed Instance, Azure SQL Database.
 * Safety  : Read-only. No modifications.
 *
 * Notes   : Logical reads = pages touched (in memory or not) - the truest sign
 *           of an inefficient query/plan. Physical reads = pages actually read
 *           from disk - inflated by memory pressure or cold cache. Reflects
 *           cached plans only; use Query Store for durable history.
 *
 * Sections:
 *   1. Top 20 Statements by TOTAL Logical Reads
 *   2. Top 20 Statements by AVERAGE Logical Reads per Execution
 *   3. Top 20 Statements by Physical Reads (disk pressure)
 *   4. Top 20 Statements by Logical Writes
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Top 20 Statements by TOTAL Logical Reads
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (20)
    qs.total_logical_reads,
    qs.execution_count,
    qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_logical_reads,
    qs.total_physical_reads,
    qs.total_worker_time / 1000                         AS total_cpu_ms,
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
ORDER BY qs.total_logical_reads DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Top 20 Statements by AVERAGE Logical Reads per Execution
  Surfaces individually expensive scans even if not run frequently.
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (20)
    qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_logical_reads,
    qs.execution_count,
    qs.total_logical_reads,
    qs.total_physical_reads / NULLIF(qs.execution_count, 0) AS avg_physical_reads,
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
WHERE qs.execution_count > 1
ORDER BY (qs.total_logical_reads / NULLIF(qs.execution_count, 0)) DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Top 20 Statements by Physical Reads (disk pressure)
  High physical reads with high logical reads => the query is also a memory
  pressure driver; correlate with PLE (07-memory-pressure.sql).
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (20)
    qs.total_physical_reads,
    qs.execution_count,
    qs.total_physical_reads / NULLIF(qs.execution_count, 0) AS avg_physical_reads,
    qs.total_logical_reads,
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
WHERE qs.total_physical_reads > 0
ORDER BY qs.total_physical_reads DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Top 20 Statements by Logical Writes
  Write-heavy statements (INSERT/UPDATE/DELETE, index maintenance, spills).
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (20)
    qs.total_logical_writes,
    qs.execution_count,
    qs.total_logical_writes / NULLIF(qs.execution_count, 0) AS avg_logical_writes,
    qs.total_worker_time / 1000                         AS total_cpu_ms,
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
WHERE qs.total_logical_writes > 0
ORDER BY qs.total_logical_writes DESC;
