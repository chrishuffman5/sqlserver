/*******************************************************************************
 * SQL Server Advisor - Collector 07: Index Usage (per database)
 *
 * Purpose : Capture read (seek/scan/lookup) vs. write (update) activity per
 *           index in the CURRENT database. LEFT JOINed from sys.indexes so that
 *           UNUSED indexes (no usage-stats row) still appear with 0 / NULL,
 *           which is exactly what the unused-index analysis needs.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025. Run in EACH user database context (looped).
 * Safety  : READ-ONLY. Reads sys.indexes + sys.dm_db_index_usage_stats.
 *
 * Output columns (EXACT capture contract -> capture/index_usage.csv):
 *   server_name, captured_at, database_name, schema_name, table_name,
 *   index_name, index_id, user_seeks, user_scans, user_lookups, user_updates,
 *   last_user_seek, last_user_scan, last_user_lookup, last_user_update
 *
 * CRITICAL interpretation note (carried into the DuckDB analysis):
 *   sys.dm_db_index_usage_stats counters RESET on instance restart, and a row
 *   is REMOVED when the database goes offline / detaches; historically a row
 *   was also reset on index REBUILD. So "no row" (-> 0 reads here) only means
 *   "unused" when correlated against a representative uptime window
 *   (server_info.sqlserver_start_time). Heaps (index_id 0) are included.
 *
 * Platform caveat:
 *   - On Azure SQL Database the DMV is database-scoped (only the current DB);
 *     this is already the per-DB scope we want. Behavior is otherwise identical
 *     on MI / RDS / Cloud SQL.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))  AS server_name,
    SYSUTCDATETIME()                                     AS captured_at,
    DB_NAME()                                            AS database_name,
    SCHEMA_NAME(t.schema_id)                             AS schema_name,
    t.name                                               AS table_name,
    i.name                                               AS index_name,   -- NULL for heaps
    i.index_id                                           AS index_id,
    ISNULL(us.user_seeks,   0)                           AS user_seeks,
    ISNULL(us.user_scans,   0)                           AS user_scans,
    ISNULL(us.user_lookups, 0)                           AS user_lookups,
    ISNULL(us.user_updates, 0)                           AS user_updates,
    us.last_user_seek                                    AS last_user_seek,
    us.last_user_scan                                    AS last_user_scan,
    us.last_user_lookup                                  AS last_user_lookup,
    us.last_user_update                                  AS last_user_update
FROM sys.indexes AS i
JOIN sys.tables  AS t ON t.object_id = i.object_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON  us.object_id   = i.object_id
    AND us.index_id    = i.index_id
    AND us.database_id = DB_ID()
WHERE t.is_ms_shipped = 0
ORDER BY SCHEMA_NAME(t.schema_id), t.name, i.index_id;
