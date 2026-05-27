/*******************************************************************************
 * Azure SQL Managed Instance (PaaS) - Instance Health Checks
 *
 * Purpose : Instance resource utilization, tier/vCores, storage, tempdb,
 *           SQL Agent job status, and recent backups for a Managed Instance.
 * Target  : Azure SQL Managed Instance ONLY  (EngineEdition = 8).
 * Safety  : Read-only. No modifications to data or configuration.
 *
 * Sections:
 *   0. Platform guard (must be Managed Instance / EngineEdition 8)
 *   1. Instance Identity, Tier & vCores
 *   2. Instance Resource Utilization over time (sys.server_resource_stats)
 *   3. Reserved vs Used Storage
 *   4. tempdb Configuration
 *   5. SQL Agent Job Status (MI HAS SQL Agent)
 *   6. Recent Backups (msdb)
 *   7. Error Log Access (sp_readerrorlog)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 0: Platform guard
  EngineEdition: 8 = Managed Instance. (5 = Azure SQL DB, 2/3/4 = box engine.)
──────────────────────────────────────────────────────────────────────────────*/
IF CONVERT(INT, SERVERPROPERTY('EngineEdition')) <> 8
BEGIN
    SELECT
        'WRONG PLATFORM' AS status,
        CONVERT(INT, SERVERPROPERTY('EngineEdition')) AS engine_edition,
        CONVERT(NVARCHAR(128), SERVERPROPERTY('Edition'))  AS edition,
        'This script targets Azure SQL Managed Instance (EngineEdition = 8). '
      + 'For Azure SQL Database (5) use 01-azure-sql-db-health.sql; '
      + 'for a box engine on VM/RDS (2/3/4) use 04-iaas-cloud-readiness.sql.'
                                                          AS guidance;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Instance Identity, Tier & vCores
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SERVERPROPERTY('ServerName')                           AS instance_name,
    SERVERPROPERTY('ProductVersion')                       AS product_version,
    SERVERPROPERTY('Edition')                              AS edition,                -- e.g. 'SQL Azure'
    SERVERPROPERTY('EngineEdition')                        AS engine_edition,         -- 8
    SERVERPROPERTY('Collation')                            AS instance_collation,     -- fixed at create on MI
    si.cpu_count                                           AS visible_vcores,
    si.physical_memory_kb / 1024                           AS memory_mb,
    si.committed_target_kb / 1024                          AS target_memory_mb,
    si.sqlserver_start_time                                AS instance_start_time,
    DATEDIFF(HOUR, si.sqlserver_start_time, SYSDATETIME()) AS uptime_hours
FROM sys.dm_os_sys_info AS si;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Instance Resource Utilization over time
  sys.server_resource_stats is the MI-level telemetry (CPU / IO / memory),
  one row per ~15s, retained for a limited window. (On Azure SQL DB the
  equivalent is sys.dm_db_resource_stats; on a box engine, perfmon DMVs.)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    COUNT(*)                                               AS sample_count,
    MIN(start_time)                                        AS window_start,
    MAX(end_time)                                          AS window_end,
    CAST(AVG(avg_cpu_percent) AS DECIMAL(5,2))             AS avg_cpu_pct,
    CAST(MAX(avg_cpu_percent) AS DECIMAL(5,2))             AS max_cpu_pct,
    MAX(virtual_core_count)                                AS vcores,
    CAST(AVG(io_requests) AS DECIMAL(18,1))                AS avg_io_requests,
    CAST(AVG(reserved_storage_mb) AS DECIMAL(18,1))        AS reserved_storage_mb,
    CAST(AVG(storage_space_used_mb) AS DECIMAL(18,1))      AS storage_used_mb
FROM sys.server_resource_stats;

-- Recent raw samples (newest first)
SELECT TOP (20)
    start_time,
    end_time,
    sku,
    hardware_generation,
    virtual_core_count                                     AS vcores,
    CAST(avg_cpu_percent AS DECIMAL(5,2))                  AS cpu_pct,
    io_requests,
    io_bytes_read,
    io_bytes_written,
    reserved_storage_mb,
    storage_space_used_mb
FROM sys.server_resource_stats
ORDER BY end_time DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Reserved vs Used Storage (instance-level)
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (1)
    reserved_storage_mb,
    storage_space_used_mb,
    reserved_storage_mb - storage_space_used_mb            AS free_storage_mb,
    CAST(100.0 * storage_space_used_mb
       / NULLIF(reserved_storage_mb, 0) AS DECIMAL(5,2))   AS pct_storage_used
FROM sys.server_resource_stats
ORDER BY end_time DESC;

-- Per-database file footprint (aggregate of all databases on the instance)
SELECT
    DB_NAME(mf.database_id)                                AS database_name,
    CAST(SUM(CASE WHEN mf.type = 0 THEN mf.size END) * 8.0 / 1024 AS DECIMAL(18,2)) AS data_mb,
    CAST(SUM(CASE WHEN mf.type = 1 THEN mf.size END) * 8.0 / 1024 AS DECIMAL(18,2)) AS log_mb
FROM sys.master_files AS mf
GROUP BY mf.database_id
ORDER BY data_mb DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: tempdb Configuration
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    mf.file_id,
    mf.name                                                AS logical_name,
    mf.type_desc                                           AS file_type,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2))            AS size_mb,
    mf.growth,
    mf.is_percent_growth
FROM sys.master_files AS mf
WHERE mf.database_id = DB_ID(N'tempdb')
ORDER BY mf.type_desc, mf.file_id;

-- Quick view: count of tempdb data files vs visible vCores (sizing sanity)
SELECT
    (SELECT COUNT(*) FROM sys.master_files
      WHERE database_id = DB_ID(N'tempdb') AND type = 0) AS tempdb_data_files,
    (SELECT cpu_count FROM sys.dm_os_sys_info)           AS visible_vcores;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: SQL Agent Job Status   (Managed Instance HAS SQL Server Agent)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    j.name                                                 AS job_name,
    j.enabled,
    SUSER_SNAME(j.owner_sid)                               AS job_owner,
    ja.start_execution_date                                AS last_start,
    ja.stop_execution_date                                 AS last_stop,
    CASE
        WHEN ja.stop_execution_date IS NULL
         AND ja.start_execution_date IS NOT NULL THEN 'RUNNING'
        ELSE 'IDLE'
    END                                                    AS run_state
FROM msdb.dbo.sysjobs AS j
OUTER APPLY (
    SELECT TOP (1) a.start_execution_date, a.stop_execution_date
    FROM msdb.dbo.sysjobactivity AS a
    WHERE a.job_id = j.job_id
    ORDER BY a.start_execution_date DESC
) AS ja
ORDER BY j.enabled DESC, j.name;

-- Recent failed job-step outcomes (last 24h)
SELECT TOP (50)
    j.name                                                 AS job_name,
    h.step_id,
    h.step_name,
    h.run_status,                                          -- 0=Failed,1=Succeeded,2=Retry,3=Canceled
    msdb.dbo.agent_datetime(h.run_date, h.run_time)        AS run_datetime,
    h.message
FROM msdb.dbo.sysjobhistory AS h
INNER JOIN msdb.dbo.sysjobs AS j ON h.job_id = j.job_id
WHERE h.run_status <> 1
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(DAY, -1, GETDATE())
ORDER BY run_datetime DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 6: Recent Backups (managed automatically on MI; this confirms cadence)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    bs.database_name,
    bs.type                                                AS backup_type,        -- D=Full, I=Diff, L=Log
    CASE bs.type WHEN 'D' THEN 'Full' WHEN 'I' THEN 'Differential'
                 WHEN 'L' THEN 'Log'  ELSE bs.type END     AS backup_type_desc,
    MAX(bs.backup_finish_date)                             AS most_recent_backup,
    DATEDIFF(MINUTE, MAX(bs.backup_finish_date), GETDATE()) AS minutes_since
FROM msdb.dbo.backupset AS bs
WHERE bs.backup_finish_date >= DATEADD(DAY, -3, GETDATE())
GROUP BY bs.database_name, bs.type
ORDER BY bs.database_name, backup_type_desc;

/*──────────────────────────────────────────────────────────────────────────────
  Section 7: Error Log Access pointer
  MI exposes the error log via sp_readerrorlog (no OS/file access). Uncomment
  to read the most recent log; left commented to keep this strictly read-only
  and avoid large result sets by default.
──────────────────────────────────────────────────────────────────────────────*/
-- EXEC sp_readerrorlog 0;   -- 0 = current log; this is a read-only system proc
SELECT 'Run  EXEC sp_readerrorlog 0;  to read the current error log (read-only).' AS info_message;
