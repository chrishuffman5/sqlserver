/*******************************************************************************
 * Azure SQL Database (PaaS) - Resource & SLO Health
 *
 * Purpose : Resource utilization, service objective, size vs MAXSIZE, and
 *           connection overview for an Azure SQL Database (single / pooled).
 * Target  : Azure SQL Database ONLY  (SERVERPROPERTY('EngineEdition') = 5).
 *           Run in the context of the user database, NOT master.
 * Safety  : Read-only. No modifications to data or configuration.
 *
 * Sections:
 *   0. Platform guard (must be Azure SQL Database / EngineEdition 5)
 *   1. Service Objective & Edition (current SLO)
 *   2. Resource Utilization - last hour (sys.dm_db_resource_stats)
 *   3. Resource Utilization - history (sys.resource_stats, master)
 *   4. Database Size vs MAXSIZE
 *   5. Connection / Session Overview
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 0: Platform guard
  EngineEdition values: 5 = Azure SQL Database, 8 = Managed Instance,
  2 = Standard box, 3 = Enterprise/Developer box, 4 = Express.
──────────────────────────────────────────────────────────────────────────────*/
IF CONVERT(INT, SERVERPROPERTY('EngineEdition')) <> 5
BEGIN
    SELECT
        'WRONG PLATFORM' AS status,
        CONVERT(INT, SERVERPROPERTY('EngineEdition')) AS engine_edition,
        CONVERT(NVARCHAR(128), SERVERPROPERTY('Edition'))  AS edition,
        'This script targets Azure SQL Database (EngineEdition = 5). '
      + 'For Managed Instance (8) use 02-managed-instance-checks.sql; '
      + 'for a box engine on VM/RDS (2/3/4) use 04-iaas-cloud-readiness.sql.'
                                                          AS guidance;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Service Objective & Edition (current SLO)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME()                                              AS database_name,
    DATABASEPROPERTYEX(DB_NAME(), 'Edition')               AS service_tier,        -- e.g. GeneralPurpose, BusinessCritical, Hyperscale, Standard, Premium
    DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective')      AS service_objective,   -- e.g. GP_Gen5_4, S3, P2, HS_Gen5_8
    DATABASEPROPERTYEX(DB_NAME(), 'IsXTPSupported')        AS in_memory_oltp_supported,
    DATABASEPROPERTYEX(DB_NAME(), 'MaxSizeInBytes') / 1073741824.0 AS max_size_gb,
    DATABASEPROPERTYEX(DB_NAME(), 'Updateability')         AS updateability;        -- READ_WRITE vs READ_ONLY (e.g. geo-secondary)

-- Richer SLO detail. sys.database_service_objectives is database-scoped on
-- Azure SQL DB; join to sys.databases to resolve the database name.
SELECT
    d.name                  AS database_name,
    dso.edition,
    dso.service_objective,
    dso.elastic_pool_name,
    dso.dtu_limit,
    dso.cpu_limit,
    dso.min_cpu,
    dso.max_cpu,
    dso.max_storage_in_gb
FROM sys.database_service_objectives AS dso
INNER JOIN sys.databases AS d
    ON dso.database_id = d.database_id;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Resource Utilization - LAST HOUR
  sys.dm_db_resource_stats emits one row every ~15 seconds for the current DB.
  This is the primary Azure SQL DB telemetry source (replaces much of the
  on-prem perfmon/DMV surface that does not exist here).
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    COUNT(*)                                               AS sample_count,
    MIN(end_time)                                          AS window_start,
    MAX(end_time)                                          AS window_end,
    CAST(AVG(avg_cpu_percent) AS DECIMAL(5,2))             AS avg_cpu_pct,
    CAST(MAX(avg_cpu_percent) AS DECIMAL(5,2))             AS max_cpu_pct,
    CAST(AVG(avg_data_io_percent) AS DECIMAL(5,2))         AS avg_data_io_pct,
    CAST(MAX(avg_data_io_percent) AS DECIMAL(5,2))         AS max_data_io_pct,
    CAST(AVG(avg_log_write_percent) AS DECIMAL(5,2))       AS avg_log_write_pct,
    CAST(MAX(avg_log_write_percent) AS DECIMAL(5,2))       AS max_log_write_pct,
    CAST(AVG(avg_memory_usage_percent) AS DECIMAL(5,2))    AS avg_memory_pct,
    CAST(MAX(avg_memory_usage_percent) AS DECIMAL(5,2))    AS max_memory_pct,
    -- DTU percent is the blended max of CPU/data-IO/log for DTU SKUs;
    -- on vCore SKUs treat the component percentages above as authoritative.
    CAST(MAX(dtu_limit) AS DECIMAL(10,2))                  AS dtu_limit,
    CAST(MAX(max_worker_percent) AS DECIMAL(5,2))          AS max_worker_pct,
    CAST(MAX(max_session_percent) AS DECIMAL(5,2))         AS max_session_pct
FROM sys.dm_db_resource_stats;

-- Recent raw samples (top 20, newest first) for spotting spikes
SELECT TOP (20)
    end_time,
    CAST(avg_cpu_percent AS DECIMAL(5,2))        AS cpu_pct,
    CAST(avg_data_io_percent AS DECIMAL(5,2))    AS data_io_pct,
    CAST(avg_log_write_percent AS DECIMAL(5,2))  AS log_write_pct,
    CAST(avg_memory_usage_percent AS DECIMAL(5,2)) AS memory_pct,
    CAST(max_worker_percent AS DECIMAL(5,2))     AS worker_pct,
    CAST(max_session_percent AS DECIMAL(5,2))    AS session_pct
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Resource Utilization - HISTORY (up to ~14 days)
  sys.resource_stats lives in the logical master; query it when connected to
  master. We probe gracefully so the script still runs from a user DB.
──────────────────────────────────────────────────────────────────────────────*/
IF DB_NAME() = N'master'
BEGIN
    SELECT TOP (100)
        database_name,
        start_time,
        end_time,
        sku,
        CAST(avg_cpu_percent AS DECIMAL(5,2))        AS avg_cpu_pct,
        CAST(avg_data_io_percent AS DECIMAL(5,2))    AS avg_data_io_pct,
        CAST(avg_log_write_percent AS DECIMAL(5,2))  AS avg_log_write_pct,
        CAST(max_worker_percent AS DECIMAL(5,2))     AS max_worker_pct,
        CAST(max_session_percent AS DECIMAL(5,2))    AS max_session_pct,
        storage_in_megabytes
    FROM sys.resource_stats
    ORDER BY start_time DESC;
END
ELSE
BEGIN
    SELECT 'sys.resource_stats history is only readable from the logical [master] database. '
         + 'Reconnect to master and re-run Section 3 for multi-day trends.' AS info_message;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Database Size vs MAXSIZE
──────────────────────────────────────────────────────────────────────────────*/
-- Per-file allocated vs used space (current database)
SELECT
    df.file_id,
    df.name                                                AS logical_name,
    df.type_desc                                           AS file_type,
    CAST(df.size * 8.0 / 1024 AS DECIMAL(18,2))            AS allocated_mb,
    CAST(FILEPROPERTY(df.name, 'SpaceUsed') * 8.0 / 1024 AS DECIMAL(18,2)) AS used_mb,
    df.max_size,
    df.growth,
    df.is_percent_growth
FROM sys.database_files AS df;

-- Total data size vs the MAXSIZE quota of the service objective
SELECT
    DB_NAME()                                              AS database_name,
    CAST(SUM(CASE WHEN df.type = 0 THEN df.size END) * 8.0 / 1024 AS DECIMAL(18,2)) AS data_allocated_mb,
    CAST(DATABASEPROPERTYEX(DB_NAME(), 'MaxSizeInBytes') / 1048576.0 AS DECIMAL(18,2)) AS max_size_mb,
    CAST(
        100.0
      * (SUM(CASE WHEN df.type = 0 THEN df.size END) * 8192.0)
      / NULLIF(CONVERT(DECIMAL(38,0), DATABASEPROPERTYEX(DB_NAME(), 'MaxSizeInBytes')), 0)
        AS DECIMAL(5,2))                                   AS pct_of_maxsize
FROM sys.database_files AS df;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Connection / Session Overview
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    COUNT(*)                                               AS total_sessions,
    SUM(CASE WHEN s.is_user_process = 1 THEN 1 ELSE 0 END) AS user_sessions,
    SUM(CASE WHEN s.status = 'running' THEN 1 ELSE 0 END)  AS running_sessions
FROM sys.dm_exec_sessions AS s;

-- Sessions by host / program / login (top talkers)
SELECT TOP (25)
    s.host_name,
    s.program_name,
    s.login_name,
    COUNT(*)                                               AS session_count
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
GROUP BY s.host_name, s.program_name, s.login_name
ORDER BY session_count DESC;
