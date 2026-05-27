/*******************************************************************************
 * SQL Server Infrastructure - Database-Scoped Configuration Audit
 *
 * Purpose : Report sys.database_scoped_configurations for every online user
 *           database, highlighting values that differ from the SQL default
 *           (per-DB MAXDOP, LEGACY_CARDINALITY_ESTIMATION, PARAMETER_SNIFFING,
 *           QUERY_OPTIMIZER_HOTFIXES, OPTIMIZE_FOR_AD_HOC_WORKLOADS, etc.) and
 *           any difference between primary and secondary-replica values.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x) on Windows/Linux. Box product.
 *           sys.database_scoped_configurations introduced in 2016 (13.x).
 * Safety  : READ-ONLY. No data or configuration is modified. Recommended
 *           changes are shown only as COMMENTED-OUT templates.
 *
 * Sections:
 *   1. Per-database scoped configuration (loops user DBs, flags non-defaults)
 *   2. Database compatibility level (governs optimizer behavior)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Per-database scoped configurations
  sys.database_scoped_configurations is per-database, so loop over online user
  DBs and run it in each database's context, collecting into a results table.
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('tempdb..#dsc') IS NOT NULL DROP TABLE #dsc;
CREATE TABLE #dsc
(
    database_name        SYSNAME,
    configuration_id     INT,
    name                 NVARCHAR(128),
    value                SQL_VARIANT,
    value_for_secondary  SQL_VARIANT,
    is_value_default     BIT NULL
);

DECLARE @db SYSNAME, @sql NVARCHAR(MAX);
DECLARE @has_default_col BIT =
    CASE WHEN EXISTS (SELECT 1 FROM sys.all_columns
                      WHERE object_id = OBJECT_ID('sys.database_scoped_configurations')
                        AND name = 'is_value_default') THEN 1 ELSE 0 END;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE database_id > 4            -- skip master/model/msdb/tempdb
      AND state_desc = 'ONLINE'
      AND source_database_id IS NULL -- skip snapshots
    ORDER BY name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'USE ' + QUOTENAME(@db) + N';
        INSERT INTO #dsc (database_name, configuration_id, name, value, value_for_secondary, is_value_default)
        SELECT ' + QUOTENAME(@db, '''') + N', configuration_id, name, value, value_for_secondary, '
        + CASE WHEN @has_default_col = 1 THEN N'is_value_default' ELSE N'CAST(NULL AS BIT)' END
        + N'
        FROM sys.database_scoped_configurations;';
    BEGIN TRY
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        -- e.g. a database in a state that prevents USE; skip and continue
        INSERT INTO #dsc (database_name, name, value)
        VALUES (@db, '(could not read - ' + ERROR_MESSAGE() + ')', NULL);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @db;
END;
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Show NON-DEFAULT settings first (the interesting ones), then the rest.
SELECT
    database_name,
    name                                 AS setting,
    value                                AS primary_value,
    value_for_secondary                  AS secondary_value,
    is_value_default,
    CASE WHEN is_value_default = 0 THEN 'NON-DEFAULT - review'
         WHEN is_value_default IS NULL THEN 'unknown (older build / read error)'
         ELSE 'default' END              AS flag
FROM #dsc
ORDER BY CASE WHEN is_value_default = 0 THEN 0 ELSE 1 END,
         database_name, setting;

DROP TABLE #dsc;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Compatibility level (NOT a scoped config; lives in sys.databases)
  Governs optimizer/CE behavior independently of engine version.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    name                AS database_name,
    compatibility_level,
    CASE compatibility_level
        WHEN 130 THEN 'SQL Server 2016'
        WHEN 140 THEN 'SQL Server 2017'
        WHEN 150 THEN 'SQL Server 2019'
        WHEN 160 THEN 'SQL Server 2022'
        WHEN 170 THEN 'SQL Server 2025'
        ELSE 'older than 2016'
    END                 AS compat_target
FROM sys.databases
WHERE database_id > 4 AND state_desc = 'ONLINE' AND source_database_id IS NULL
ORDER BY name;

/*──────────────────────────────────────────────────────────────────────────────
  Remediation template (COMMENTED OUT - run in the target database's context)
──────────────────────────────────────────────────────────────────────────────*/
/*
-- USE [YourDatabase];
-- ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 4;
-- ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET MAXDOP = 8;          -- readable secondary
-- ALTER DATABASE SCOPED CONFIGURATION SET QUERY_OPTIMIZER_HOTFIXES = ON;     -- per-DB TF 4199
-- ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = ON;-- regressed DB only
-- ALTER DATABASE [YourDatabase] SET COMPATIBILITY_LEVEL = 160;               -- engineering decision
*/
