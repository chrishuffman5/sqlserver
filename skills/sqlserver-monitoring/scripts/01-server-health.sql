/*******************************************************************************
 * SQL Server Monitoring - Instance Health Snapshot
 *
 * Purpose : One-page health overview of a SQL Server instance: uptime, build,
 *           database states, connections, recent CPU, memory, blocking, and the
 *           oldest open transaction. Run first when triaging "is it healthy?".
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box). Some sections are skipped on Azure SQL
 *           Database where instance-scoped DMVs are unavailable (see notes).
 * Safety  : Read-only. No modifications to data or configuration.
 *
 * Sections:
 *   1. Version, Edition & Build
 *   2. Uptime
 *   3. Database Count & States
 *   4. Active Connections & Sessions
 *   5. Recent CPU Utilization (Scheduler Monitor Ring Buffer)
 *   6. Memory Summary
 *   7. Current Blocking Count
 *   8. Oldest Open Transaction
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Version, Edition & Build
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SERVERPROPERTY('ServerName')                        AS server_name,
    SERVERPROPERTY('ProductVersion')                    AS product_version,   -- e.g. 16.0.x
    SERVERPROPERTY('ProductLevel')                      AS product_level,     -- RTM / SPn / CUn
    SERVERPROPERTY('ProductUpdateLevel')                AS update_level,      -- CU label (2016+)
    SERVERPROPERTY('Edition')                           AS edition,
    SERVERPROPERTY('EngineEdition')                     AS engine_edition,    -- 5=Azure SQL DB, 8=MI
    SERVERPROPERTY('IsHadrEnabled')                     AS is_hadr_enabled,
    SERVERPROPERTY('IsClustered')                       AS is_clustered,
    CASE WHEN SERVERPROPERTY('EngineEdition') IN (5, 8) THEN 'Cloud (Azure SQL DB / MI) - see sqlserver-cloud'
         ELSE 'Box / IaaS' END                          AS platform_class;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Uptime
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    sqlserver_start_time,
    DATEDIFF(HOUR, sqlserver_start_time, GETDATE())     AS uptime_hours,
    DATEDIFF(DAY,  sqlserver_start_time, GETDATE())     AS uptime_days
FROM sys.dm_os_sys_info;

-- Reminder: cumulative DMVs (waits, file stats, perf counters) reset at this start time.

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Database Count & States
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    state_desc,
    COUNT(*)                                            AS database_count
FROM sys.databases
GROUP BY state_desc
ORDER BY database_count DESC;

-- Any database not ONLINE is flagged here
SELECT
    name                                                AS database_name,
    state_desc,
    recovery_model_desc,
    compatibility_level,
    is_read_only,
    is_auto_close_on,
    is_auto_shrink_on,                                  -- should be 0 everywhere
    log_reuse_wait_desc                                 -- why the log cannot truncate
FROM sys.databases
WHERE state_desc <> N'ONLINE'
   OR is_auto_shrink_on = 1
   OR is_auto_close_on = 1
ORDER BY name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Active Connections & Sessions
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    COUNT(*)                                            AS total_sessions,
    SUM(CASE WHEN status = N'running'  THEN 1 ELSE 0 END) AS running_sessions,
    SUM(CASE WHEN status = N'sleeping' THEN 1 ELSE 0 END) AS sleeping_sessions,
    SUM(CASE WHEN is_user_process = 1  THEN 1 ELSE 0 END) AS user_sessions,
    COUNT(DISTINCT login_name)                          AS distinct_logins
FROM sys.dm_exec_sessions;

-- Connections by login / program / host
SELECT TOP (20)
    es.login_name,
    es.program_name,
    es.host_name,
    COUNT(*)                                            AS session_count
FROM sys.dm_exec_sessions AS es
WHERE es.is_user_process = 1
GROUP BY es.login_name, es.program_name, es.host_name
ORDER BY session_count DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Recent CPU Utilization (Scheduler Monitor Ring Buffer)
  Ring buffer is unavailable on Azure SQL Database (use sys.dm_db_resource_stats).
──────────────────────────────────────────────────────────────────────────────*/
IF SERVERPROPERTY('EngineEdition') NOT IN (5)   -- skip on Azure SQL Database
BEGIN
    SELECT TOP (15)
        DATEADD(ms, -1 * (si.ms_ticks - rb.[timestamp]), GETDATE()) AS sample_time,
        rb.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int') AS sql_cpu_pct,
        rb.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]','int')         AS system_idle_pct,
        100
          - rb.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]','int')
          - rb.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int') AS other_cpu_pct
    FROM
    (
        SELECT [timestamp], CONVERT(XML, record) AS record
        FROM sys.dm_os_ring_buffers
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
          AND record LIKE N'%<SystemHealth>%'
    ) AS rb
    CROSS JOIN sys.dm_os_sys_info AS si
    ORDER BY rb.[timestamp] DESC;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 6: Memory Summary
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    (SELECT cpu_count FROM sys.dm_os_sys_info)          AS logical_cpus,
    (SELECT physical_memory_kb / 1024 FROM sys.dm_os_sys_info) AS server_physical_mem_mb,
    pm.physical_memory_in_use_kb / 1024                 AS sql_working_set_mb,
    pm.memory_utilization_percentage,
    pm.process_physical_memory_low                      AS external_memory_pressure,  -- 1 = pressure
    (SELECT cntr_value
       FROM sys.dm_os_performance_counters
      WHERE counter_name = N'Page life expectancy'
        AND object_name LIKE N'%Buffer Manager%')       AS page_life_expectancy_sec,
    (SELECT cntr_value
       FROM sys.dm_os_performance_counters
      WHERE counter_name = N'Memory Grants Pending'
        AND object_name LIKE N'%Memory Manager%')       AS memory_grants_pending
FROM sys.dm_os_process_memory AS pm;

/*──────────────────────────────────────────────────────────────────────────────
  Section 7: Current Blocking Count
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    COUNT(*)                                            AS blocked_requests,
    COUNT(DISTINCT blocking_session_id)                 AS distinct_blockers,
    MAX(wait_time) / 1000                               AS max_block_wait_sec
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0;

/*──────────────────────────────────────────────────────────────────────────────
  Section 8: Oldest Open Transaction
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (5)
    at.transaction_id,
    at.transaction_begin_time,
    DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) AS open_seconds,
    st.session_id,
    es.login_name,
    es.host_name,
    es.program_name,
    DB_NAME(dt.database_id)                             AS database_name,
    dt.database_transaction_log_bytes_used / 1024       AS log_kb_used
FROM sys.dm_tran_active_transactions AS at
LEFT JOIN sys.dm_tran_session_transactions  AS st ON at.transaction_id = st.transaction_id
LEFT JOIN sys.dm_tran_database_transactions AS dt ON at.transaction_id = dt.transaction_id
LEFT JOIN sys.dm_exec_sessions              AS es ON st.session_id     = es.session_id
WHERE at.transaction_begin_time IS NOT NULL
  AND st.session_id IS NOT NULL
ORDER BY at.transaction_begin_time ASC;
