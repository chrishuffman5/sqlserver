/*******************************************************************************
 * SQL Server Advisor - Collector 15: Statistics Health (per database)
 *
 * Purpose : Capture one row per statistics object on user tables in the
 *           CURRENT database with freshness (last_updated), size (rows),
 *           sampling quality (rows_sampled), churn since the last update
 *           (modification_counter), and the NORECOMPUTE flag. Feeds the
 *           per-statistic staleness analysis (a15-statistics-health) - this is
 *           what upgrades the Statistics dimension from database-level switches
 *           (db_inventory) to per-object evidence.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box / Azure VM / Azure SQL DB / MI / RDS /
 *           Cloud SQL). sys.dm_db_stats_properties is available everywhere in
 *           that range. Run in EACH user database context (the capture guide
 *           loops it).
 * Safety  : READ-ONLY. Reads sys.stats + sys.tables + the
 *           sys.dm_db_stats_properties TVF only (metadata; no page reads).
 *
 * Output columns (EXACT capture contract -> capture/stats_health.csv):
 *   server_name, captured_at, database_name, schema_name, table_name,
 *   stats_name, stats_id, is_auto_created, is_user_created, no_recompute,
 *   has_filter, last_updated, rows, rows_sampled, sample_pct,
 *   modification_counter
 *
 * Filtering / caveats:
 *   - Bounded to statistics whose table rowset has >= 1000 rows: staleness on
 *     tiny tables is noise, and unbounded capture on a stats-heavy schema can
 *     be large. Raise/lower the threshold to taste.
 *   - INCREMENTAL statistics return no row from sys.dm_db_stats_properties
 *     (they need sys.dm_db_incremental_stats_properties, out of contract
 *     scope), so the CROSS APPLY silently skips them - by design.
 *   - modification_counter counts LEADING-column modifications since the last
 *     stats update. The engine's auto-update threshold on 2016+ (compat 130+)
 *     is approximately SQRT(1000 * rows) - the analysis compares against that.
 *   - Requires SELECT permission on the underlying columns (db_datareader
 *     covers it) - same read-only permission set as the other collectors.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))             AS server_name,
    SYSUTCDATETIME()                                                AS captured_at,
    DB_NAME()                                                       AS database_name,
    SCHEMA_NAME(t.schema_id)                                        AS schema_name,
    t.name                                                          AS table_name,
    s.name                                                          AS stats_name,
    s.stats_id                                                      AS stats_id,
    s.auto_created                                                  AS is_auto_created,
    s.user_created                                                  AS is_user_created,
    s.no_recompute                                                  AS no_recompute,
    s.has_filter                                                    AS has_filter,
    sp.last_updated                                                 AS last_updated,
    sp.rows                                                         AS rows,
    sp.rows_sampled                                                 AS rows_sampled,
    CAST(sp.rows_sampled * 100.0 / NULLIF(sp.rows, 0)
         AS DECIMAL(5,2))                                           AS sample_pct,
    sp.modification_counter                                         AS modification_counter
FROM sys.stats AS s
JOIN sys.tables AS t ON t.object_id = s.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE t.is_ms_shipped = 0
  AND sp.rows >= 1000
ORDER BY sp.modification_counter DESC, sp.rows DESC;
