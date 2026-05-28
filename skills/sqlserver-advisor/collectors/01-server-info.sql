/*******************************************************************************
 * SQL Server Advisor - Collector 01: Server Info
 *
 * Purpose : Capture a single-row identity/footprint of the target instance:
 *           version, edition, engine edition, host CPU/memory, the SQL Server
 *           memory ceiling, start time, and HADR flag. This row anchors every
 *           later version/edition/platform-sensitive recommendation in DuckDB.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (13.x-17.x) on Windows/Linux/containers.
 *           Azure SQL DB / MI / AWS RDS / Cloud SQL notes below.
 * Safety  : READ-ONLY. SELECT only. No writes, no DDL, no config changes.
 *
 * Output columns (EXACT capture contract -> capture/server_info.csv):
 *   server_name, captured_at, product_version, product_major_version, edition,
 *   engine_edition, host_cpu_count, host_physical_memory_mb, sql_memory_limit_mb,
 *   sqlserver_start_time, is_hadr_enabled
 *
 * Platform / DMV caveats:
 *   - host_cpu_count / host_physical_memory_mb come from sys.dm_os_sys_info.
 *     On Azure SQL Database (EngineEdition 5) sys.dm_os_sys_info IS queryable
 *     but reflects the logical container, not a dedicated host; treat host_*
 *     fields as approximate there. On Azure SQL MI (8) and AWS RDS they reflect
 *     the managed VM. On AWS RDS some host-level detail may be masked.
 *   - sql_memory_limit_mb uses committed_target_kb (the memory broker target,
 *     2012+). This is the effective SQL Server memory ceiling, not 'max server
 *     memory' sp_configure (which is captured in 02-config.sql).
 *   - IsHadrEnabled is 0/1 on box; NULL/0 on Azure SQL DB (AG concept differs).
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))             AS server_name,
    SYSUTCDATETIME()                                                AS captured_at,
    CONVERT(varchar(64),  SERVERPROPERTY('ProductVersion'))         AS product_version,
    CONVERT(int,          SERVERPROPERTY('ProductMajorVersion'))    AS product_major_version,
    CONVERT(varchar(128), SERVERPROPERTY('Edition'))                AS edition,
    CONVERT(int,          SERVERPROPERTY('EngineEdition'))           AS engine_edition,
    si.cpu_count                                                    AS host_cpu_count,
    CONVERT(bigint, si.physical_memory_kb / 1024)                   AS host_physical_memory_mb,
    CONVERT(bigint, si.committed_target_kb / 1024)                  AS sql_memory_limit_mb,
    si.sqlserver_start_time                                         AS sqlserver_start_time,
    CONVERT(int,          SERVERPROPERTY('IsHadrEnabled'))           AS is_hadr_enabled
FROM sys.dm_os_sys_info AS si;
