/*******************************************************************************
 * SQL Server Monitoring - Performance Counter Snapshot
 *
 * Purpose : Read the key SQL Server Perfmon counters in T-SQL, handling the
 *           three counter shapes correctly: raw values, ratio/base pairs, and
 *           per-second cumulative counters (sampled over a short interval).
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box) and Managed Instance. On Azure SQL
 *           Database prefer sys.dm_db_resource_stats (see sqlserver-cloud).
 * Safety  : Read-only. No modifications. WAITFOR DELAY is used only as the
 *           sampling gap for per-second rates.
 *
 * Counter shapes (cntr_type):
 *   65792     raw value           -> read cntr_value directly
 *   537003264 ratio numerator     -> divide by its 1073939712 base partner
 *   272696576 per-second (cumul.) -> delta over an interval = true rate
 *
 * Sections:
 *   1. Raw-Value Counters (read directly)
 *   2. Ratio Counters (ratio/base pattern)
 *   3. Per-Second Rate Counters (sampled delta over 5s)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Raw-Value Counters (read cntr_value directly)
  PLE, pending grants, blocked processes, connections, etc.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    RTRIM(object_name)                                  AS counter_object,
    RTRIM(counter_name)                                 AS counter_name,
    RTRIM(instance_name)                                AS counter_instance,
    cntr_value
FROM sys.dm_os_performance_counters
WHERE
    (object_name LIKE N'%Buffer Manager%'    AND counter_name = N'Page life expectancy')
 OR (object_name LIKE N'%Memory Manager%'    AND counter_name IN (N'Memory Grants Pending',
                                                                  N'Memory Grants Outstanding',
                                                                  N'Total Server Memory (KB)',
                                                                  N'Target Server Memory (KB)'))
 OR (object_name LIKE N'%General Statistics%' AND counter_name IN (N'User Connections',
                                                                   N'Processes blocked',
                                                                   N'Temp Tables Creation Rate'))
ORDER BY counter_object, counter_name, counter_instance;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Ratio Counters (ratio/base pattern)
  Each ratio counter is meaningless without its matching '... base' partner.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    RTRIM(ratio.object_name)                            AS counter_object,
    RTRIM(ratio.counter_name)                           AS counter_name,
    CAST(100.0 * ratio.cntr_value / NULLIF(base.cntr_value, 0) AS DECIMAL(7,3)) AS ratio_pct
FROM sys.dm_os_performance_counters AS ratio
JOIN sys.dm_os_performance_counters AS base
    ON  ratio.object_name = base.object_name
   AND  REPLACE(base.counter_name, N' base', N'') = ratio.counter_name
   AND  ISNULL(NULLIF(ratio.instance_name, N''), N'@') = ISNULL(NULLIF(base.instance_name, N''), N'@')
WHERE ratio.cntr_type = 537003264          -- ratio numerator
  AND base.cntr_type  = 1073939712         -- matching base
  AND ratio.counter_name IN (N'Buffer cache hit ratio',
                             N'Plan Cache Hit Ratio',
                             N'Log Cache Hit Ratio',
                             N'Worktables From Cache Ratio')
ORDER BY counter_object, counter_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Per-Second Rate Counters (sampled delta over 5s)
  Per-second counters are CUMULATIVE; the true rate is (delta / elapsed seconds).
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID(N'tempdb..#pc_t0') IS NOT NULL DROP TABLE #pc_t0;

SELECT RTRIM(object_name) AS object_name, RTRIM(counter_name) AS counter_name,
       RTRIM(instance_name) AS instance_name, cntr_value
INTO #pc_t0
FROM sys.dm_os_performance_counters
WHERE cntr_type = 272696576                -- per-second cumulative
  AND counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec',
                       N'SQL Re-Compilations/sec', N'Page reads/sec',
                       N'Page writes/sec', N'Lock Waits/sec',
                       N'Number of Deadlocks/sec', N'Page Splits/sec',
                       N'Forwarded Records/sec', N'Transactions/sec');

DECLARE @interval_s INT = 5;
WAITFOR DELAY '00:00:05';

SELECT
    t1.object_name                                      AS counter_object,
    t1.counter_name,
    t1.instance_name                                    AS counter_instance,
    CAST((t1.cntr_value - t0.cntr_value) * 1.0 / @interval_s AS DECIMAL(18,2)) AS per_second_rate
FROM
(
    SELECT RTRIM(object_name) AS object_name, RTRIM(counter_name) AS counter_name,
           RTRIM(instance_name) AS instance_name, cntr_value
    FROM sys.dm_os_performance_counters
    WHERE cntr_type = 272696576
) AS t1
JOIN #pc_t0 AS t0
    ON  t1.object_name   = t0.object_name
   AND  t1.counter_name  = t0.counter_name
   AND  t1.instance_name = t0.instance_name
ORDER BY t1.counter_name, t1.counter_instance;

DROP TABLE #pc_t0;

/*──────────────────────────────────────────────────────────────────────────────
  Derived signal: Compilations as a % of Batch Requests.
  A high ratio indicates plan-cache churn (unparameterized ad-hoc SQL).
  Computed from the per-second snapshot above is ideal; the cumulative ratio
  below is a quick approximation since restart.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    CAST(100.0 * comp.cntr_value / NULLIF(batch.cntr_value, 0) AS DECIMAL(5,2))
        AS compilations_pct_of_batches_since_restart
FROM sys.dm_os_performance_counters AS comp
CROSS JOIN sys.dm_os_performance_counters AS batch
WHERE comp.counter_name  = N'SQL Compilations/sec'  AND comp.instance_name  = N''
  AND batch.counter_name = N'Batch Requests/sec'    AND batch.instance_name = N'';
