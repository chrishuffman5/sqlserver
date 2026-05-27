/*******************************************************************************
 * SQL Server Operations - Database Space Usage
 *
 * Purpose : Report per-file size / used / free space, autogrowth settings,
 *           Instant File Initialization status, VLF count per database, and
 *           transaction-log space used. Capacity-planning snapshot.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box / Azure VM / MI / RDS).
 *           sys.dm_db_log_info and sys.dm_db_log_space_usage are guarded:
 *           dm_db_log_info (per-VLF) is 2016 SP2 / 2017+; on older builds the
 *           DBCC LOGINFO fallback is documented. dm_db_log_space_usage is 2012+.
 * Safety  : READ-ONLY. Reads sys.master_files, sys.database_files, DMVs.
 *           No file is grown, shrunk, or modified.
 *
 * Sections:
 *   1. Per-File Size / Used / Free (current database) + autogrowth
 *   2. Autogrowth Audit Across All Databases (percent-growth / tiny-growth flags)
 *   3. Instant File Initialization Status (instance)
 *   4. Transaction Log Space Used (current database)
 *   5. VLF Count Per Database (2016 SP2 / 2017+) with fallback note
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Per-File Size / Used / Free (current database) + autogrowth
  FILEPROPERTY('SpaceUsed') is per-file and database-scoped.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME()                                           AS database_name,
    f.name                                              AS logical_name,
    f.type_desc                                         AS file_type,
    f.physical_name,
    CAST(f.size * 8.0 / 1024 AS DECIMAL(18,2))          AS allocated_mb,
    CAST(FILEPROPERTY(f.name, 'SpaceUsed') * 8.0 / 1024 AS DECIMAL(18,2)) AS used_mb,
    CAST((f.size - FILEPROPERTY(f.name, 'SpaceUsed')) * 8.0 / 1024 AS DECIMAL(18,2)) AS free_mb,
    CASE WHEN f.size > 0
         THEN CAST(100.0 * FILEPROPERTY(f.name, 'SpaceUsed') / f.size AS DECIMAL(5,2))
         ELSE NULL END                                  AS used_pct,
    CASE WHEN f.is_percent_growth = 1
         THEN CAST(f.growth AS VARCHAR(10)) + ' %'
         ELSE CAST(f.growth * 8 / 1024 AS VARCHAR(10)) + ' MB' END AS autogrowth,
    CASE WHEN f.max_size = -1 THEN 'unlimited'
         WHEN f.max_size = 268435456 THEN 'unlimited (log 2TB cap)'
         ELSE CAST(f.max_size * 8 / 1024 AS VARCHAR(20)) + ' MB' END AS max_size
FROM sys.database_files AS f
ORDER BY f.type_desc, f.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Autogrowth Audit Across All Databases
  Flags percentage growth and very small fixed-MB growth (both cause problems).
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME(mf.database_id)                             AS database_name,
    mf.name                                             AS logical_name,
    mf.type_desc                                        AS file_type,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2))         AS size_mb,
    CASE WHEN mf.is_percent_growth = 1
         THEN CAST(mf.growth AS VARCHAR(10)) + ' %'
         ELSE CAST(mf.growth * 8 / 1024 AS VARCHAR(10)) + ' MB' END AS autogrowth,
    CASE
        WHEN mf.growth = 0 THEN 'WARNING: autogrowth disabled (file cannot grow)'
        WHEN mf.is_percent_growth = 1 THEN 'REVIEW: percentage growth - use fixed MB instead'
        WHEN mf.is_percent_growth = 0 AND (mf.growth * 8 / 1024) < 64 THEN 'REVIEW: very small fixed growth'
        ELSE 'ok'
    END                                                 AS growth_assessment
FROM sys.master_files AS mf
WHERE mf.database_id > 4         -- focus on user databases (1-4 are system)
ORDER BY DB_NAME(mf.database_id), mf.type_desc, mf.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Instant File Initialization Status (instance)
  IFI speeds data-file growth/restore (log files are always zeroed). 2016+.
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('sys.dm_server_services') IS NOT NULL
BEGIN
    SELECT
        servicename,
        instant_file_initialization_enabled            AS ifi_enabled,
        CASE WHEN instant_file_initialization_enabled = 'Y'
             THEN 'ok: data-file growth/restore skips zeroing'
             ELSE 'REVIEW: grant "Perform Volume Maintenance Tasks" to enable IFI' END AS note
    FROM sys.dm_server_services
    WHERE servicename LIKE N'SQL Server (%';
END
ELSE
BEGIN
    SELECT 'sys.dm_server_services unavailable on this build/platform; '
         + 'verify IFI via the service account holding "Perform Volume Maintenance Tasks".' AS ifi_note;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Transaction Log Space Used (current database)
  sys.dm_db_log_space_usage is 2012+. All-version fallback: DBCC SQLPERF(LOGSPACE).
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('sys.dm_db_log_space_usage') IS NOT NULL
BEGIN
    SELECT
        DB_NAME(database_id)                            AS database_name,
        CAST(total_log_size_in_bytes / 1024.0 / 1024 AS DECIMAL(18,2)) AS total_log_mb,
        CAST(used_log_space_in_bytes  / 1024.0 / 1024 AS DECIMAL(18,2)) AS used_log_mb,
        CAST(used_log_space_in_percent AS DECIMAL(5,2)) AS used_log_pct
    FROM sys.dm_db_log_space_usage;
END
ELSE
BEGIN
    SELECT 'sys.dm_db_log_space_usage unavailable; use DBCC SQLPERF(LOGSPACE).' AS log_space_note;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: VLF Count Per Database
  sys.dm_db_log_info is 2016 SP2 / 2017+. Too many small VLFs slow recovery,
  log backups, and AG redo. Fallback on older builds: DBCC LOGINFO('<db>').
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('sys.dm_db_log_info') IS NOT NULL
BEGIN
    -- NULL = current database only (cross-DB requires iterating; kept safe/single-DB)
    SELECT
        DB_NAME()                                       AS database_name,
        COUNT(*)                                        AS vlf_count,
        CASE
            WHEN COUNT(*) > 1000 THEN 'WARNING: very high VLF count - consider right-sizing the log'
            WHEN COUNT(*) > 300  THEN 'REVIEW: elevated VLF count'
            ELSE 'ok'
        END                                             AS vlf_assessment
    FROM sys.dm_db_log_info(DB_ID());
END
ELSE
BEGIN
    SELECT 'sys.dm_db_log_info unavailable on this build; '
         + 'use DBCC LOGINFO(''<db>'') and count the returned rows (= VLF count).' AS vlf_note;
END;

/*──────────────────────────────────────────────────────────────────────────────
  REMEDIATION TEMPLATES (commented out — assessment script does NOT execute):

  -- Set sensible fixed autogrowth (example: 512 MB):
  -- ALTER DATABASE [<db>] MODIFY FILE (NAME = N'<logical>', FILEGROWTH = 512MB);

  -- Right-size a bloated VLF count: back up log, shrink, then grow in chunks.
  -- (Shrink is otherwise discouraged - see references/capacity-management.md.)
  -- BACKUP LOG [<db>] TO DISK = N'...trn';
  -- DBCC SHRINKFILE (N'<log_logical>', 256);
  -- ALTER DATABASE [<db>] MODIFY FILE (NAME=N'<log_logical>', SIZE=8192MB);  -- grow in ~8GB chunks
──────────────────────────────────────────────────────────────────────────────*/
