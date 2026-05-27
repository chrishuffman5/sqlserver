/*******************************************************************************
 * SQL Server on Azure VM / AWS RDS - Cloud IaaS Hygiene Check
 *
 * Purpose : Confirm the box engine is configured sensibly for a cloud VM /
 *           managed-box environment: IFI, data/log latency vs cloud-disk
 *           suitability, tempdb layout, max memory vs VM size, and AG/witness
 *           presence. Framed as cloud-IaaS readiness, not deep perf tuning.
 * Target  : Box engine in the cloud (SQL on Azure VM, AWS RDS, GCP).
 *           EngineEdition 2 (Standard), 3 (Enterprise/Developer), 4 (Express).
 *           NOT for Azure SQL Database (5) or Managed Instance (8).
 * Safety  : Read-only. No modifications to data or configuration.
 *
 * Sections:
 *   0. Platform guard (must be a box engine: EngineEdition 2/3/4)
 *   1. Platform / Edition / Cloud-host hints
 *   2. Instant File Initialization (IFI) status
 *   3. Data & Log File Latency vs cloud-disk expectations
 *   4. tempdb Configuration (file count, sizing, location hint)
 *   5. max server memory vs detected physical RAM (VM size sanity)
 *   6. HA: Always On / Clustering / Witness presence
 ******************************************************************************/
SET NOCOUNT ON;

DECLARE @engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

/*──────────────────────────────────────────────────────────────────────────────
  Section 0: Platform guard
  Box engine editions only: 2=Standard, 3=Enterprise/Developer, 4=Express.
──────────────────────────────────────────────────────────────────────────────*/
IF @engine NOT IN (2, 3, 4)
BEGIN
    SELECT
        'WRONG PLATFORM' AS status,
        @engine AS engine_edition,
        CONVERT(NVARCHAR(128), SERVERPROPERTY('Edition'))  AS edition,
        CASE @engine
            WHEN 5 THEN 'This is Azure SQL Database - use 01-azure-sql-db-health.sql. Storage/IFI/tempdb/memory are managed by the platform.'
            WHEN 8 THEN 'This is Azure SQL Managed Instance - use 02-managed-instance-checks.sql. Storage/tempdb are platform-managed.'
            ELSE 'Unrecognized EngineEdition for an IaaS box engine.'
        END                                                AS guidance;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Platform / Edition / Cloud-host hints
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SERVERPROPERTY('ServerName')                           AS server_name,
    SERVERPROPERTY('MachineName')                          AS machine_name,
    SERVERPROPERTY('ProductVersion')                       AS product_version,
    SERVERPROPERTY('Edition')                              AS edition,
    @engine                                                AS engine_edition,
    SERVERPROPERTY('IsClustered')                          AS is_clustered,
    SERVERPROPERTY('IsHadrEnabled')                        AS is_hadr_enabled,
    si.cpu_count                                           AS logical_cpus,
    si.socket_count                                        AS sockets,
    si.cores_per_socket                                    AS cores_per_socket,
    si.physical_memory_kb / 1024                           AS physical_memory_mb,
    si.virtual_machine_type_desc                           AS vm_type,             -- 'HYPERVISOR' on a cloud VM
    si.sqlserver_start_time                                AS instance_start_time
FROM sys.dm_os_sys_info AS si;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Instant File Initialization (IFI) status
  IFI ("Perform volume maintenance tasks") avoids zero-filling data files on
  growth/restore - important on cloud disks where growth events are common.
  Note: AWS RDS manages this for you and may not expose the setting.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    instant_file_initialization_enabled,                   -- 'Y' / 'N' (2016 SP1+)
    service_account
FROM sys.dm_server_services
WHERE servicename LIKE N'SQL Server (%';

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Data & Log File Latency vs cloud-disk expectations
  Cumulative average since startup from sys.dm_io_virtual_file_stats.
  Cloud guidance: data read/write < ~20ms, LOG WRITE < ~5ms (ideally lower).
  Sustained high log latency on a cloud VM usually means: log on a cached
  disk (should be NO caching), undersized disk IOPS, or a too-small VM IO cap.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME(vfs.database_id)                               AS database_name,
    mf.type_desc                                           AS file_type,           -- ROWS (data) / LOG
    mf.name                                                AS logical_name,
    mf.physical_name,
    CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS DECIMAL(10,2)) AS avg_read_latency_ms,
    CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS DECIMAL(10,2)) AS avg_write_latency_ms,
    CASE
        WHEN mf.type_desc = 'LOG'
             AND (vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0)) > 5
             THEN 'LOG write > 5ms - check disk caching (should be NONE on log), IOPS, VM IO cap'
        WHEN mf.type_desc = 'ROWS'
             AND (vfs.io_stall_read_ms * 1.0 / NULLIF(vfs.num_of_reads, 0)) > 20
             THEN 'DATA read > 20ms - enable read caching on data disk, raise IOPS, or stripe disks'
        ELSE 'OK'
    END                                                    AS cloud_disk_assessment,
    vfs.num_of_reads,
    vfs.num_of_writes,
    CAST((vfs.num_of_bytes_read + vfs.num_of_bytes_written) / 1048576.0 AS DECIMAL(18,1)) AS total_mb_io
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
INNER JOIN sys.master_files AS mf
    ON vfs.database_id = mf.database_id
   AND vfs.file_id     = mf.file_id
ORDER BY avg_write_latency_ms DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: tempdb Configuration
  Cloud best practice: tempdb on the VM's local/ephemeral SSD where available;
  one data file per logical CPU up to 8; equal sizing for proportional fill.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    mf.file_id,
    mf.name                                                AS logical_name,
    mf.physical_name,
    mf.type_desc                                           AS file_type,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2))            AS size_mb,
    mf.growth,
    mf.is_percent_growth
FROM sys.master_files AS mf
WHERE mf.database_id = DB_ID(N'tempdb')
ORDER BY mf.type_desc, mf.file_id;

-- tempdb data-file count vs CPU count, with a sizing verdict
SELECT
    tempdb_data_files,
    logical_cpus,
    CASE
        WHEN tempdb_data_files < CASE WHEN logical_cpus < 8 THEN logical_cpus ELSE 8 END
            THEN 'Consider more tempdb data files (1 per CPU up to 8) to reduce allocation contention'
        ELSE 'tempdb data-file count looks reasonable'
    END                                                    AS tempdb_verdict
FROM (
    SELECT
        (SELECT COUNT(*) FROM sys.master_files
          WHERE database_id = DB_ID(N'tempdb') AND type = 0)  AS tempdb_data_files,
        (SELECT cpu_count FROM sys.dm_os_sys_info)            AS logical_cpus
) AS x;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: max server memory vs physical RAM (VM-size sanity)
  On a cloud VM you pay for RAM - leave headroom for the OS but don't strand it.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    c.name                                                 AS config_name,
    CAST(c.value_in_use AS BIGINT)                         AS max_server_memory_mb,
    si.physical_memory_kb / 1024                           AS physical_memory_mb,
    CAST(100.0 * c.value_in_use
        / NULLIF(si.physical_memory_kb / 1024.0, 0) AS DECIMAL(5,2)) AS pct_of_physical,
    CASE
        WHEN CAST(c.value_in_use AS BIGINT) >= 2147483647
            THEN 'max server memory is at the default MAX - SET IT. On a VM, leave 10-20% (min ~4GB) for the OS.'
        WHEN (si.physical_memory_kb / 1024.0) - c.value_in_use < 2048
            THEN 'Too little headroom for the OS - lower max server memory.'
        ELSE 'max server memory leaves reasonable OS headroom.'
    END                                                    AS memory_verdict
FROM sys.configurations AS c
CROSS JOIN sys.dm_os_sys_info AS si
WHERE c.name = 'max server memory (MB)';

/*──────────────────────────────────────────────────────────────────────────────
  Section 6: HA - Always On / Clustering / Witness presence
  Confirms whether cloud-aware HA is configured (AG with Cloud Witness, FCI on
  Azure shared disks / S2D, or RDS Multi-AZ which is opaque to T-SQL).
──────────────────────────────────────────────────────────────────────────────*/
IF SERVERPROPERTY('IsHadrEnabled') = 1
BEGIN
    SELECT
        ag.name                                            AS ag_name,
        ag.cluster_type_desc                               AS cluster_type,        -- WSFC / EXTERNAL / NONE
        ag.is_distributed                                  AS is_distributed_ag,
        ar.replica_server_name,
        ar.availability_mode_desc                          AS availability_mode,
        ar.failover_mode_desc                              AS failover_mode
    FROM sys.availability_groups AS ag
    INNER JOIN sys.availability_replicas AS ar
        ON ag.group_id = ar.group_id
    ORDER BY ag.name, ar.replica_server_name;

    -- Cluster quorum / witness (Cloud Witness shows here on WSFC-based clusters)
    BEGIN TRY
        SELECT
            cluster_name,
            quorum_type_desc,
            quorum_state_desc
        FROM sys.dm_hadr_cluster;
    END TRY
    BEGIN CATCH
        SELECT 'sys.dm_hadr_cluster not available (cluster-less AG or no WSFC).' AS info_message;
    END CATCH;
END
ELSE IF SERVERPROPERTY('IsClustered') = 1
BEGIN
    SELECT 'Failover Cluster Instance (FCI) detected. On a cloud VM this implies '
         + 'Azure shared disks or Storage Spaces Direct with a Cloud Witness for quorum.' AS info_message;
END
ELSE
BEGIN
    SELECT 'No Always On AG and not an FCI. If this is production, HA is NOT configured '
         + 'at the SQL layer. On AWS RDS, HA is provided by Multi-AZ (opaque to T-SQL); '
         + 'on a VM you must build AG/FCI with a Cloud Witness.' AS info_message;
END;
