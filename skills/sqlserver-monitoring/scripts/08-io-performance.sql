/*******************************************************************************
 * SQL Server Monitoring - I/O Performance (per file)
 *
 * Purpose : Per-file read/write latency and throughput from
 *           sys.dm_io_virtual_file_stats joined to sys.master_files. Use when
 *           waits show PAGEIOLATCH_* / WRITELOG / IO_COMPLETION to confirm
 *           whether storage latency is the problem.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box), Managed Instance, Azure SQL Database
 *           (DB-scoped there).
 * Safety  : Read-only. No modifications.
 *
 * Notes   : Values are CUMULATIVE since restart. For a current-window view,
 *           run Section 3 which samples a short interval and computes deltas.
 *           Rough targets: data files < ~10-20 ms, log files < ~5 ms.
 *
 * Sections:
 *   1. Per-File Latency & Throughput (cumulative since restart)
 *   2. Aggregated Latency by File Type
 *   3. Short-Interval Sampled Latency (current window)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Per-File Latency & Throughput (cumulative since restart)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME(vfs.database_id)                            AS database_name,
    mf.name                                             AS logical_file,
    mf.type_desc                                        AS file_type,
    mf.physical_name,
    vfs.num_of_reads,
    vfs.num_of_writes,
    CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS DECIMAL(18,2)) AS avg_read_latency_ms,
    CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS DECIMAL(18,2)) AS avg_write_latency_ms,
    CAST(vfs.io_stall * 1.0
         / NULLIF(vfs.num_of_reads + vfs.num_of_writes, 0) AS DECIMAL(18,2))         AS avg_overall_latency_ms,
    vfs.num_of_bytes_read    / 1024 / 1024              AS mb_read,
    vfs.num_of_bytes_written / 1024 / 1024              AS mb_written,
    vfs.size_on_disk_bytes   / 1024 / 1024              AS size_on_disk_mb
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
    ON vfs.database_id = mf.database_id
   AND vfs.file_id     = mf.file_id
ORDER BY vfs.io_stall DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Aggregated Latency by File Type
  Quick split of data vs log latency across the instance.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    mf.type_desc                                        AS file_type,
    SUM(vfs.num_of_reads)                               AS total_reads,
    SUM(vfs.num_of_writes)                              AS total_writes,
    CAST(SUM(vfs.io_stall_read_ms)  * 1.0
         / NULLIF(SUM(vfs.num_of_reads), 0)  AS DECIMAL(18,2)) AS avg_read_latency_ms,
    CAST(SUM(vfs.io_stall_write_ms) * 1.0
         / NULLIF(SUM(vfs.num_of_writes), 0) AS DECIMAL(18,2)) AS avg_write_latency_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
    ON vfs.database_id = mf.database_id
   AND vfs.file_id     = mf.file_id
GROUP BY mf.type_desc
ORDER BY mf.type_desc;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Short-Interval Sampled Latency (current window)
  Snapshots, waits 10s, then computes per-file latency over JUST that interval -
  far more useful than since-restart numbers for a live investigation.
  WAITFOR DELAY is used only as the sampling gap; this remains read-only.
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID(N'tempdb..#io_t0') IS NOT NULL DROP TABLE #io_t0;

SELECT database_id, file_id,
       num_of_reads, num_of_writes,
       io_stall_read_ms, io_stall_write_ms
INTO #io_t0
FROM sys.dm_io_virtual_file_stats(NULL, NULL);

WAITFOR DELAY '00:00:10';

SELECT
    DB_NAME(t1.database_id)                             AS database_name,
    mf.name                                             AS logical_file,
    mf.type_desc                                        AS file_type,
    (t1.num_of_reads  - t0.num_of_reads)                AS reads_in_window,
    (t1.num_of_writes - t0.num_of_writes)               AS writes_in_window,
    CAST((t1.io_stall_read_ms  - t0.io_stall_read_ms) * 1.0
         / NULLIF(t1.num_of_reads  - t0.num_of_reads, 0)  AS DECIMAL(18,2)) AS window_avg_read_ms,
    CAST((t1.io_stall_write_ms - t0.io_stall_write_ms) * 1.0
         / NULLIF(t1.num_of_writes - t0.num_of_writes, 0) AS DECIMAL(18,2)) AS window_avg_write_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS t1
JOIN #io_t0 AS t0
    ON t1.database_id = t0.database_id
   AND t1.file_id     = t0.file_id
JOIN sys.master_files AS mf
    ON t1.database_id = mf.database_id
   AND t1.file_id     = mf.file_id
WHERE (t1.num_of_reads - t0.num_of_reads) + (t1.num_of_writes - t0.num_of_writes) > 0
ORDER BY (t1.io_stall_read_ms - t0.io_stall_read_ms)
       + (t1.io_stall_write_ms - t0.io_stall_write_ms) DESC;

DROP TABLE #io_t0;
