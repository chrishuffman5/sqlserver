/*******************************************************************************
 * SQL Server Infrastructure - tempdb Configuration
 *
 * Purpose : Audit tempdb's data/log files (sizes, growth), check for uneven
 *           data-file sizing, compare the data-file count to the core-count
 *           recommendation, report memory-optimized tempdb metadata status
 *           (2019+), and check for live allocation-page contention.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x) on Windows/Linux. Box product.
 *           Memory-optimized tempdb metadata property guarded (2019+ / 15.x).
 * Safety  : READ-ONLY. No data or configuration is modified. Recommended
 *           changes are shown only as COMMENTED-OUT templates.
 *
 * Sections:
 *   1. tempdb files: size, growth, percent-growth flag
 *   2. Even-sizing check & file-count vs core recommendation
 *   3. Memory-optimized tempdb metadata status (2019+)
 *   4. Live allocation-page contention (PAGELATCH on 2:1:1 / 2:1:2 / 2:1:3)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: tempdb files
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    mf.file_id,
    mf.name                         AS logical_name,
    mf.type_desc,
    mf.size * 8 / 1024              AS size_mb,
    CASE WHEN mf.is_percent_growth = 1
         THEN CONCAT(mf.growth, ' %  <- change to fixed MB')
         ELSE CONCAT(mf.growth * 8 / 1024, ' MB') END AS autogrowth,
    mf.is_percent_growth,
    mf.physical_name
FROM sys.master_files AS mf
WHERE mf.database_id = DB_ID('tempdb')
ORDER BY mf.type_desc DESC, mf.file_id;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Even-sizing check & file-count recommendation
  Rule: data file count = min(logical cores, 8); all data files equal size/growth.
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @cores INT = (SELECT cpu_count FROM sys.dm_os_sys_info);
DECLARE @recommended_files INT = CASE WHEN @cores > 8 THEN 8 ELSE @cores END;

SELECT
    COUNT(*)                                            AS tempdb_data_files,
    @cores                                              AS logical_cores,
    @recommended_files                                  AS recommended_data_files,
    MIN(size * 8 / 1024)                                AS smallest_file_mb,
    MAX(size * 8 / 1024)                                AS largest_file_mb,
    COUNT(DISTINCT size)                                AS distinct_sizes,
    COUNT(DISTINCT CAST(growth AS BIGINT))              AS distinct_growths,
    COUNT(DISTINCT is_percent_growth)                   AS distinct_growth_types,
    CASE WHEN COUNT(DISTINCT size) > 1
         THEN 'DEVIATION - data files are NOT equally sized (breaks proportional fill)'
         ELSE 'ok - equal sizes' END                    AS sizing_flag,
    CASE WHEN COUNT(*) < @recommended_files
         THEN CONCAT('DEVIATION - only ', COUNT(*), ' data files; recommend ', @recommended_files)
         WHEN COUNT(*) > 8
         THEN 'REVIEW - more than 8 files; only add (in groups of 4) if contention persists'
         ELSE 'ok - file count matches recommendation' END AS file_count_flag,
    CASE WHEN MAX(CAST(is_percent_growth AS INT)) = 1
         THEN 'DEVIATION - one or more files use PERCENT growth; switch to fixed MB'
         ELSE 'ok - fixed-MB growth' END                AS growth_type_flag
FROM sys.master_files
WHERE database_id = DB_ID('tempdb')
  AND type_desc = 'ROWS';

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Memory-optimized tempdb metadata (2019+ / engine 15.x)
──────────────────────────────────────────────────────────────────────────────*/
IF CONVERT(INT, SERVERPROPERTY('ProductMajorVersion')) >= 15
BEGIN
    SELECT
        SERVERPROPERTY('IsTempdbMetadataMemoryOptimized') AS is_memopt_tempdb_metadata,  -- 1 = ON
        CASE WHEN SERVERPROPERTY('IsTempdbMetadataMemoryOptimized') = 1
             THEN 'Memory-optimized tempdb metadata is ON'
             ELSE 'OFF - consider enabling under heavy temp-object churn (restart required)'
        END AS memopt_metadata_note;
END
ELSE
BEGIN
    SELECT 'Memory-optimized tempdb metadata requires SQL Server 2019+ (15.x). Not available here.' AS info_message;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Live allocation-page contention
  PAGELATCH_UP/EX waits on 2:1:1 (PFS), 2:1:2 (GAM), 2:1:3 (SGAM) = tempdb
  allocation contention. (PAGEIOLATCH is I/O, not this; see sqlserver-monitoring.)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    r.session_id,
    r.wait_type,
    r.wait_resource,                                    -- look for 2:1:1, 2:1:2, 2:1:3
    r.wait_time                                          AS wait_time_ms,
    r.status,
    r.command,
    CASE
        WHEN r.wait_resource LIKE '2:1:1%' THEN 'PFS contention (2:1:1)'
        WHEN r.wait_resource LIKE '2:1:2%' THEN 'GAM contention (2:1:2)'
        WHEN r.wait_resource LIKE '2:1:3%' THEN 'SGAM contention (2:1:3)'
        ELSE 'other tempdb page latch'
    END                                                  AS contention_type
FROM sys.dm_exec_requests AS r
WHERE r.wait_type LIKE 'PAGELATCH%'
  AND r.wait_resource LIKE '2:1:%';

IF NOT EXISTS (SELECT 1 FROM sys.dm_exec_requests
              WHERE wait_type LIKE 'PAGELATCH%' AND wait_resource LIKE '2:1:%')
    SELECT 'No live tempdb allocation-page (PAGELATCH on 2:1:x) contention right now.' AS info_message;

/*──────────────────────────────────────────────────────────────────────────────
  Remediation template (COMMENTED OUT)
──────────────────────────────────────────────────────────────────────────────*/
/*
-- Equalize / add tempdb data files (sizes shown for illustration; pre-size to steady state):
-- ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev,  SIZE = 8192MB, FILEGROWTH = 512MB);
-- ALTER DATABASE tempdb ADD FILE   (NAME = tempdev2, FILENAME = 'T:\tempdb\tempdev2.ndf',
--                                   SIZE = 8192MB, FILEGROWTH = 512MB);
-- Enable memory-optimized tempdb metadata (2019+; restart required):
-- ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;
*/
