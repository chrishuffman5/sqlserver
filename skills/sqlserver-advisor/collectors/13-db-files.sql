/*******************************************************************************
 * SQL Server Advisor - Collector 13: Database Files & Log Health
 *
 * Purpose : Capture one row per database file (data and log, ALL databases
 *           including tempdb and the system DBs) with size, growth settings,
 *           max-size cap, and — for log files — the VLF count. Feeds the
 *           storage/autogrowth/tempdb-layout and log-health analyses
 *           (a13-storage-files): percent growth, tiny fixed growth, growth
 *           disabled, files near their max-size cap, high VLF counts, and
 *           tempdb data-file count vs. CPU count.
 * Version : 1.0.0
 * Targets : SQL Server 2016 SP2 - 2025 (box / Azure VM / MI / RDS / Cloud SQL).
 *           sys.dm_db_log_stats (VLF count) requires 2016 SP2+; on an older
 *           build, delete the OUTER APPLY and select NULL AS vlf_count.
 * Safety  : READ-ONLY. Reads sys.master_files + sys.databases +
 *           sys.dm_db_log_stats only. No writes, no DDL, no config changes.
 *
 * Output columns (EXACT capture contract -> capture/db_files.csv):
 *   server_name, captured_at, database_name, database_id, file_id,
 *   file_type_desc, logical_name, physical_name, state_desc, size_mb,
 *   max_size_mb, is_percent_growth, growth_value, vlf_count
 *
 * Column semantics:
 *   - size_mb / max_size_mb are 8 KB pages converted to MB. max_size_mb is
 *     NULL when the file is set to unlimited growth (max_size = -1); when
 *     max_size = 0 the file CANNOT grow and max_size_mb equals size_mb.
 *   - growth_value is a PERCENTAGE when is_percent_growth = 1, otherwise MB.
 *     growth_value = 0 means autogrowth is DISABLED for the file.
 *   - vlf_count is populated for ONLINE databases' log files only (NULL for
 *     data files and for offline/restoring databases).
 *
 * Platform / DMV caveats:
 *   - Azure SQL Database (EngineEdition 5): sys.master_files is NOT available.
 *     Skip this collector there, or capture per database with the fallback:
 *       SELECT ...same columns... FROM sys.database_files
 *     (sys.database_files has no database_id column - use DB_ID()/DB_NAME() -
 *     and file placement/growth is largely platform-managed anyway).
 *   - AWS RDS / Cloud SQL: rows return, but physical_name reflects the managed
 *     host's paths and tempdb layout is provider-managed - treat tempdb-file
 *     findings as informational there.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))             AS server_name,
    SYSUTCDATETIME()                                                AS captured_at,
    d.name                                                          AS database_name,
    d.database_id                                                   AS database_id,
    mf.file_id                                                      AS file_id,
    mf.type_desc                                                    AS file_type_desc,
    mf.name                                                         AS logical_name,
    mf.physical_name                                                AS physical_name,
    mf.state_desc                                                   AS state_desc,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2))                     AS size_mb,
    CASE WHEN mf.max_size = -1 THEN NULL                            -- unlimited
         WHEN mf.max_size = 0  THEN CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2))  -- no growth allowed
         ELSE CAST(mf.max_size * 8.0 / 1024 AS DECIMAL(18,2)) END   AS max_size_mb,
    mf.is_percent_growth                                            AS is_percent_growth,
    CASE WHEN mf.is_percent_growth = 1 THEN mf.growth               -- percent
         ELSE CAST(mf.growth * 8.0 / 1024 AS DECIMAL(18,2)) END     AS growth_value,
    ls.total_vlf_count                                              AS vlf_count
FROM sys.master_files AS mf
JOIN sys.databases    AS d  ON d.database_id = mf.database_id
OUTER APPLY
(
    -- VLF count for ONLINE databases' log files only (2016 SP2+).
    SELECT s.total_vlf_count
    FROM sys.dm_db_log_stats(mf.database_id) AS s
    WHERE mf.type = 1 AND d.state = 0
) AS ls
ORDER BY d.name, mf.file_id;
