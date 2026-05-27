/*******************************************************************************
 * SQL Server Operations - Statistics Health
 *
 * Purpose : Report statistics freshness for the CURRENT database: last_updated,
 *           row counts, rows sampled, modification counter since last update,
 *           and a stale-statistics flag. ASSESSMENT ONLY.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box / Azure VM / MI / Azure SQL DB / RDS).
 *           sys.dm_db_stats_properties is available 2012 SP1+ / 2014+.
 *           Runs in the context of the current database.
 * Safety  : READ-ONLY. No UPDATE STATISTICS is executed.
 *
 * Sections:
 *   1. Database AUTO Stats Settings (context)
 *   2. Statistics Detail (freshness, sampling, modification counter, stale flag)
 *   3. Stale Statistics Summary
 *
 * Notes  : "Stale" here = many modifications relative to row count OR not
 *          updated in N days. Tune @StaleDays / @ModRatio for your workload.
 ******************************************************************************/
SET NOCOUNT ON;

DECLARE @StaleDays INT   = 7;       -- not updated in this many days
DECLARE @ModRatio  FLOAT = 0.20;    -- modifications >= 20% of rows

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Database AUTO Stats Settings (context)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    name                                                AS database_name,
    is_auto_create_stats_on                             AS auto_create_stats,
    is_auto_update_stats_on                             AS auto_update_stats,
    is_auto_update_stats_async_on                       AS auto_update_stats_async
FROM sys.databases
WHERE database_id = DB_ID();

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Statistics Detail (freshness, sampling, modification counter)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    OBJECT_SCHEMA_NAME(s.object_id)                     AS schema_name,
    OBJECT_NAME(s.object_id)                            AS table_name,
    s.name                                              AS stats_name,
    CASE WHEN s.auto_created = 1 THEN 'auto'
         WHEN s.user_created = 1 THEN 'user'
         ELSE 'index' END                               AS stats_origin,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    CASE WHEN sp.rows > 0
         THEN CAST(100.0 * sp.rows_sampled / sp.rows AS DECIMAL(5,2))
         ELSE NULL END                                  AS sampled_pct,
    sp.modification_counter                             AS mods_since_update,
    CASE WHEN sp.rows > 0
         THEN CAST(100.0 * sp.modification_counter / sp.rows AS DECIMAL(7,2))
         ELSE NULL END                                  AS mod_pct_of_rows,
    DATEDIFF(DAY, sp.last_updated, GETDATE())           AS days_since_update,
    CASE
        WHEN sp.last_updated IS NULL THEN 'never updated'
        WHEN sp.rows > 0 AND sp.modification_counter >= sp.rows * @ModRatio
             THEN 'STALE (high modifications)'
        WHEN sp.last_updated < DATEADD(DAY, -@StaleDays, GETDATE())
             THEN 'STALE (older than threshold)'
        ELSE 'ok'
    END                                                 AS stale_flag
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
ORDER BY
    CASE WHEN sp.rows > 0 AND sp.modification_counter >= sp.rows * @ModRatio THEN 0 ELSE 1 END,
    sp.modification_counter DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Stale Statistics Summary (counts)
──────────────────────────────────────────────────────────────────────────────*/
;WITH props AS (
    SELECT sp.rows, sp.modification_counter, sp.last_updated
    FROM sys.stats s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
    WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
)
SELECT
    COUNT(*)                                            AS total_statistics,
    SUM(CASE WHEN last_updated IS NULL THEN 1 ELSE 0 END) AS never_updated,
    SUM(CASE WHEN rows > 0 AND modification_counter >= rows * @ModRatio THEN 1 ELSE 0 END) AS stale_high_mods,
    SUM(CASE WHEN last_updated < DATEADD(DAY, -@StaleDays, GETDATE()) THEN 1 ELSE 0 END) AS stale_by_age
FROM props;

/*──────────────────────────────────────────────────────────────────────────────
  REMEDIATION TEMPLATES (commented out — assessment script does NOT execute):

  -- Update a specific statistic with a full scan (most accurate):
  -- UPDATE STATISTICS [<schema>].[<table>] [<stats_name>] WITH FULLSCAN;

  -- Update all stats on a table:
  -- UPDATE STATISTICS [<schema>].[<table>] WITH FULLSCAN;

  -- Enable async auto-update for OLTP (avoids stall-on-update):
  -- ALTER DATABASE [<db>] SET AUTO_UPDATE_STATISTICS_ASYNC ON;

  -- Prefer Ola Hallengren IndexOptimize @UpdateStatistics='ALL',
  -- @OnlyModifiedStatistics='Y' for modification-aware updates.
──────────────────────────────────────────────────────────────────────────────*/
