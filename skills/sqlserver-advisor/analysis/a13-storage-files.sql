-- =====================================================================
-- a13-storage-files.sql  —  dimensions: Configuration / Sizing & capacity
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS file-layout and autogrowth smells from the db_files capture:
--   (1) percent autogrowth — growth events get progressively larger/slower
--       (and log growths always zero-fill);
--   (2) tiny fixed autogrowth on a sizable file (the 1 MB era default);
--   (3) autogrowth DISABLED — the file hard-stops when full;
--   (4) file at/near its MAXSIZE cap — imminent out-of-space error;
--   (5) high VLF count on the log — slows recovery, restores, log ops;
--   (6) tempdb data-file count vs. CPUs — allocation-page contention.
-- Depth: sqlserver-infrastructure (files/tempdb) / sqlserver-operations (capacity).
-- NOTE: on Azure SQL DB file layout is platform-managed (this capture is
--   skipped there); on RDS/Cloud SQL tempdb layout is provider-managed —
--   treat rule (6) as informational on managed platforms.
-- =====================================================================

-- (1) Percent autogrowth
SELECT
    'Configuration'                                         AS dimension,
    f.database_name                                         AS database_name,
    f.database_name || '.' || f.logical_name                AS object_name,
    'Medium'                                                AS severity,
    'growth=' || f.growth_value || '%; type=' || f.file_type_desc
        || '; size=' || fmt_n(f.size_mb) || ' MB'           AS metric,
    'File uses PERCENT autogrowth.'                         AS finding,
    'Switch to a fixed-MB growth increment sized for the file (commonly 256-1024 MB); pre-size the file so growth is the exception. [CONFIG CHANGE]' AS recommendation,
    'Percent growth compounds — each event is bigger and slower than the last, and log growths zero-fill synchronously, stalling every writer mid-transaction.' AS why,
    'sqlserver-infrastructure'                              AS consult_skill
FROM db_files f
WHERE f.is_percent_growth = TRUE AND f.growth_value > 0

UNION ALL
-- (2) Tiny fixed autogrowth on a sizable file
SELECT
    'Configuration', f.database_name,
    f.database_name || '.' || f.logical_name,
    'Medium',
    'growth=' || fmt_n(f.growth_value) || ' MB; type=' || f.file_type_desc
        || '; size=' || fmt_n(f.size_mb) || ' MB',
    'Sizable file grows in very small fixed increments.',
    'Raise the growth increment (commonly 256-1024 MB for data, 256-512 MB for log) and pre-size to expected volume; enable instant file initialization for data files. [CONFIG CHANGE]',
    'A 1-10 MB increment on a multi-GB file means constant micro-growth events — each one interrupts writers and (for logs) adds more tiny VLFs.',
    'sqlserver-infrastructure'
FROM db_files f
WHERE f.is_percent_growth = FALSE AND f.growth_value > 0 AND f.growth_value < 64
  AND f.size_mb >= 1024

UNION ALL
-- (3) Autogrowth disabled
SELECT
    'Sizing & capacity', f.database_name,
    f.database_name || '.' || f.logical_name,
    'Medium',
    'growth=0 (disabled); type=' || f.file_type_desc || '; size=' || fmt_n(f.size_mb) || ' MB',
    'Autogrowth is DISABLED for this file.',
    'Confirm this is deliberate (fixed-size provisioning with monitoring); otherwise enable a sane fixed-MB growth as the safety net. [CONFIG CHANGE]',
    'With growth off, the file hard-stops at its current size — inserts fail (data) or the database halts (log) the moment it fills.',
    'sqlserver-operations'
FROM db_files f
WHERE f.growth_value = 0

UNION ALL
-- (4) File at/near its MAXSIZE cap
SELECT
    'Sizing & capacity', f.database_name,
    f.database_name || '.' || f.logical_name,
    CASE WHEN f.size_mb >= f.max_size_mb * 0.95 THEN 'High' ELSE 'Medium' END,
    'size=' || fmt_n(f.size_mb) || ' MB of max=' || fmt_n(f.max_size_mb) || ' MB ('
        || fmt_d(f.size_mb * 100.0 / NULLIF(f.max_size_mb, 0), 1) || '%); type=' || f.file_type_desc,
    'File is at or near its MAXSIZE cap.',
    'Raise or remove the cap (or archive/purge data) before it is hit; alert on file-full headroom, not after the error. [CONFIG CHANGE]',
    'When the cap is reached the database throws 1105/9002 errors — data modifications stop until a human intervenes.',
    'sqlserver-operations'
FROM db_files f
WHERE f.max_size_mb IS NOT NULL AND f.max_size_mb > 0
  AND f.size_mb >= f.max_size_mb * 0.80
  AND f.growth_value <> 0     -- growth-disabled files are already flagged by rule (3)

UNION ALL
-- (5) High VLF count on the transaction log
SELECT
    'Configuration', f.database_name,
    f.database_name || '.' || f.logical_name,
    CASE WHEN f.vlf_count >= 1000 THEN 'High' ELSE 'Medium' END,
    'vlf_count=' || fmt_n(f.vlf_count) || '; log_size=' || fmt_n(f.size_mb) || ' MB',
    'Transaction log has a high VLF count.',
    'Shrink the log once to near-zero in a quiet window, then re-grow it in a few large fixed increments to its working size (this is the one legitimate shrink). [CONFIG CHANGE]',
    'Thousands of tiny VLFs — the fingerprint of years of micro-growth — slow crash recovery, restores, replication, and log backups.',
    'sqlserver-operations'
FROM db_files f
WHERE f.vlf_count >= 300

UNION ALL
-- (6) tempdb data-file count vs. CPUs (allocation-page contention)
SELECT
    'Configuration', 'tempdb',
    '(instance) tempdb',
    CASE WHEN td.data_file_count = 1 THEN 'High' ELSE 'Medium' END,
    'tempdb_data_files=' || td.data_file_count || '; host_cpu_count=' || s.host_cpu_count,
    CASE WHEN td.data_file_count = 1
         THEN 'tempdb has a single data file on a multi-core host.'
         ELSE 'tempdb has fewer data files than the guideline for this core count.' END,
    'Use one tempdb data file per logical CPU up to 8 (equal size, equal growth); check PAGELATCH_% waits on tempdb allocation pages to confirm pressure. [CONFIG CHANGE]',
    'Concurrent tempdb allocations serialize on per-file allocation pages (PFS/GAM/SGAM); multiple equal files spread that contention.',
    'sqlserver-infrastructure'
FROM (
    SELECT COUNT(*) AS data_file_count
    FROM db_files
    WHERE database_name = 'tempdb' AND file_type_desc = 'ROWS'
) td
CROSS JOIN server_info s
WHERE s.host_cpu_count > 1
  AND td.data_file_count > 0
  AND td.data_file_count < LEAST(8, s.host_cpu_count);
