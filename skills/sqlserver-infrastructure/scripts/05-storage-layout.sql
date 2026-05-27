/*******************************************************************************
 * SQL Server Infrastructure - Storage Layout & I/O Latency
 *
 * Purpose : Report the on-disk layout of all database files (by volume) with
 *           size/used/autogrowth, Instant File Initialization status, and
 *           per-file I/O latency from dm_io_virtual_file_stats - to validate
 *           file placement, growth settings, and that latency meets targets.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x) on Windows/Linux. Box product.
 *           instant_file_initialization_enabled guarded (2017+ / 14.x).
 * Safety  : READ-ONLY. No data or configuration is modified.
 *
 * Sections:
 *   1. Files by volume (size, autogrowth, percent-growth flag)
 *   2. Instant File Initialization status (2017+)
 *   3. Per-file I/O latency vs targets (<5ms log write, <20ms data)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Files by volume
  Separate data / log / tempdb / backup onto separate volumes.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    LEFT(mf.physical_name, 3)            AS volume,
    DB_NAME(mf.database_id)              AS database_name,
    mf.name                              AS logical_name,
    mf.type_desc,
    mf.size * 8 / 1024                   AS size_mb,
    CASE WHEN mf.is_percent_growth = 1
         THEN CONCAT(mf.growth, ' %  <- DEVIATION: use fixed MB')
         ELSE CONCAT(mf.growth * 8 / 1024, ' MB') END AS autogrowth,
    mf.is_percent_growth,
    mf.max_size,                          -- -1 = unlimited, 0 = no growth, else max pages
    mf.physical_name
FROM sys.master_files AS mf
ORDER BY volume, DB_NAME(mf.database_id), mf.type_desc DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Instant File Initialization status (2017+ reports directly)
  IFI speeds data-file create/grow/restore. Log files are ALWAYS zeroed (no IFI).
──────────────────────────────────────────────────────────────────────────────*/
IF CONVERT(INT, SERVERPROPERTY('ProductMajorVersion')) >= 14
   AND EXISTS (SELECT 1 FROM sys.all_columns
               WHERE object_id = OBJECT_ID('sys.dm_server_services')
                 AND name = 'instant_file_initialization_enabled')
BEGIN
    SELECT
        servicename,
        service_account,
        instant_file_initialization_enabled,
        CASE WHEN instant_file_initialization_enabled = 'Y'
             THEN 'IFI ENABLED (data files skip zeroing)'
             ELSE 'IFI DISABLED - grant "Perform Volume Maintenance Tasks" to the service account'
        END AS ifi_note
    FROM sys.dm_server_services
    WHERE servicename LIKE 'SQL Server (%';
END
ELSE
BEGIN
    SELECT 'IFI status column requires SQL Server 2017+ (14.x). On older builds verify via '
         + 'the "Perform Volume Maintenance Tasks" user-right / absence of trace flag 1806.' AS info_message;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Per-file I/O latency (since service start)
  Targets: log write < 5 ms; data read/write < 10-20 ms.
  Note: averages span all uptime; one-off startup/backup spikes skew them.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME(vfs.database_id)             AS database_name,
    mf.name                              AS logical_name,
    mf.type_desc,
    LEFT(mf.physical_name, 3)            AS volume,
    vfs.num_of_reads,
    vfs.num_of_writes,
    CASE WHEN vfs.num_of_reads  = 0 THEN 0
         ELSE vfs.io_stall_read_ms  / vfs.num_of_reads  END  AS avg_read_ms,
    CASE WHEN vfs.num_of_writes = 0 THEN 0
         ELSE vfs.io_stall_write_ms / vfs.num_of_writes END  AS avg_write_ms,
    (vfs.num_of_bytes_read  / 1024 / 1024)                   AS mb_read,
    (vfs.num_of_bytes_written / 1024 / 1024)                 AS mb_written,
    CASE
        WHEN mf.type_desc = 'LOG'
             AND vfs.num_of_writes > 0
             AND vfs.io_stall_write_ms / vfs.num_of_writes > 5
             THEN 'WARN - log write latency > 5 ms target'
        WHEN mf.type_desc = 'ROWS'
             AND ((vfs.num_of_reads  > 0 AND vfs.io_stall_read_ms  / vfs.num_of_reads  > 20)
               OR (vfs.num_of_writes > 0 AND vfs.io_stall_write_ms / vfs.num_of_writes > 20))
             THEN 'WARN - data latency > 20 ms target'
        ELSE 'ok / review'
    END                                                       AS latency_flag
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
  ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
ORDER BY avg_write_ms DESC, avg_read_ms DESC;
