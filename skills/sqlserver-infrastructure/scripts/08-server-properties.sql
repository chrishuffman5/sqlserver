/*******************************************************************************
 * SQL Server Infrastructure - Server Properties & Platform Identity
 *
 * Purpose : Dump the identity of the instance and host - version/edition/engine
 *           edition, collation, clustering/HADR/security flags, CPU/memory,
 *           uptime, VM/container type, and OS platform (Windows vs Linux) - the
 *           first thing to establish before any infrastructure recommendation.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x) on Windows/Linux. Box product.
 *           sys.dm_os_host_info and container_type guarded (2017+ / 14.x).
 * Safety  : READ-ONLY. No data or configuration is modified.
 *
 * Sections:
 *   1. SERVERPROPERTY dump (version, edition, flags)
 *   2. sys.dm_os_sys_info (CPU, memory, uptime, VM type)
 *   3. OS platform / host info (2017+)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: SERVERPROPERTY dump
  EngineEdition: 2=Standard, 3=Enterprise/Dev, 4=Express, 5=Azure SQL DB, 8=MI
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SERVERPROPERTY('MachineName')                       AS machine_name,
    SERVERPROPERTY('ServerName')                        AS server_name,
    SERVERPROPERTY('InstanceName')                      AS instance_name,         -- NULL = default instance
    SERVERPROPERTY('ProductVersion')                    AS product_version,
    SERVERPROPERTY('ProductMajorVersion')               AS product_major_version, -- 13/14/15/16/17
    SERVERPROPERTY('ProductLevel')                      AS product_level,         -- RTM / CUxx
    SERVERPROPERTY('ProductUpdateLevel')                AS product_update_level,
    SERVERPROPERTY('Edition')                           AS edition,
    SERVERPROPERTY('EngineEdition')                     AS engine_edition,        -- see note above
    SERVERPROPERTY('Collation')                         AS server_collation,
    SERVERPROPERTY('IsClustered')                       AS is_clustered,          -- 1 = FCI
    SERVERPROPERTY('IsHadrEnabled')                     AS is_hadr_enabled,       -- 1 = Always On AGs enabled
    SERVERPROPERTY('IsIntegratedSecurityOnly')          AS is_windows_auth_only,  -- 1 = Windows-auth only
    SERVERPROPERTY('IsFullTextInstalled')               AS is_fulltext_installed,
    SERVERPROPERTY('IsPolyBaseInstalled')               AS is_polybase_installed,
    CASE SERVERPROPERTY('EngineEdition')
        WHEN 5 THEN 'Azure SQL Database (PaaS) - most instance config does NOT apply (see sqlserver-cloud)'
        WHEN 8 THEN 'Azure SQL Managed Instance (PaaS) - subset of instance config applies'
        ELSE 'Box product - full instance configuration surface'
    END                                                 AS platform_note;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: sys.dm_os_sys_info (CPU, memory, uptime, VM / container type)
  container_type_desc is 2017+; guarded below.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.all_columns
           WHERE object_id = OBJECT_ID('sys.dm_os_sys_info')
             AND name = 'container_type_desc')
BEGIN
    SELECT
        cpu_count                            AS logical_cpus,
        scheduler_count,
        physical_memory_kb / 1024            AS physical_memory_mb,
        sqlserver_start_time,
        DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) AS uptime_hours,
        virtual_machine_type_desc            AS vm_type,         -- NONE / HYPERVISOR
        container_type_desc                  AS container_type   -- NONE / WINDOWS_CONTAINER / etc (2017+)
    FROM sys.dm_os_sys_info;
END
ELSE
BEGIN
    SELECT
        cpu_count                            AS logical_cpus,
        scheduler_count,
        physical_memory_kb / 1024            AS physical_memory_mb,
        sqlserver_start_time,
        DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) AS uptime_hours,
        virtual_machine_type_desc            AS vm_type,
        'container_type_desc requires 2017+ (14.x)' AS container_type
    FROM sys.dm_os_sys_info;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: OS platform / host info (2017+ / 14.x)
  Distinguishes Windows vs Linux - governs how memory/trace flags are set.
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('sys.dm_os_host_info') IS NOT NULL
BEGIN
    SELECT
        host_platform,           -- 'Windows' or 'Linux'
        host_distribution,       -- e.g. 'Ubuntu', 'Red Hat Enterprise Linux', 'Windows ...'
        host_release,
        host_service_pack_level,
        host_sku,
        os_language_version,
        CASE WHEN host_platform = 'Linux'
             THEN 'Configure memory/trace flags via mssql-conf (see references/platform-and-network.md)'
             ELSE 'Configure via Configuration Manager / Windows policy'
        END AS config_surface_note
    FROM sys.dm_os_host_info;
END
ELSE
BEGIN
    SELECT 'sys.dm_os_host_info requires SQL Server 2017+ (14.x). Assume Windows on older builds.' AS info_message;
END;
