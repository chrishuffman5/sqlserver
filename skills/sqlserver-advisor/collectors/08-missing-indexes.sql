/*******************************************************************************
 * SQL Server Advisor - Collector 08: Missing Indexes (per database)
 *
 * Purpose : Capture the optimizer's missing-index suggestions for the CURRENT
 *           database, with the standard improvement_measure ranking, so the
 *           advisor can surface high-value gaps. These are HINTS, not orders -
 *           the analysis layer flags them for review and consolidation.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025. Run in EACH user database context (looped).
 * Safety  : READ-ONLY. Reads the sys.dm_db_missing_index_* DMVs only. Emits no
 *           CREATE INDEX text (that lives in sqlserver-engineering scripts);
 *           this is a capture, not an action.
 *
 * Output columns (EXACT capture contract -> capture/missing_indexes.csv):
 *   server_name, captured_at, database_name, schema_name, table_name,
 *   equality_columns, inequality_columns, included_columns, unique_compiles,
 *   user_seeks, user_scans, avg_total_user_cost, avg_user_impact,
 *   improvement_measure
 *
 * improvement_measure (per contract) =
 *   avg_total_user_cost * (avg_user_impact / 100.0) * (user_seeks + user_scans)
 *
 * Interpretation note (carried downstream): the missing-index DMVs do NOT
 * consolidate overlapping suggestions, ignore existing indexes and write cost,
 * and reset on restart. Treat improvement_measure as a relative ranking only.
 *
 * Platform caveat:
 *   - The DMVs are database-scoped here via mid.database_id = DB_ID(). Available
 *     on box / MI / RDS / Cloud SQL. On Azure SQL Database they are present and
 *     scoped to the connected database.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))      AS server_name,
    SYSUTCDATETIME()                                         AS captured_at,
    DB_NAME()                                                AS database_name,
    SCHEMA_NAME(o.schema_id)                                 AS schema_name,
    OBJECT_NAME(mid.object_id, mid.database_id)              AS table_name,
    mid.equality_columns                                     AS equality_columns,
    mid.inequality_columns                                   AS inequality_columns,
    mid.included_columns                                     AS included_columns,
    migs.unique_compiles                                     AS unique_compiles,
    migs.user_seeks                                          AS user_seeks,
    migs.user_scans                                          AS user_scans,
    CAST(migs.avg_total_user_cost AS DECIMAL(18,4))          AS avg_total_user_cost,
    CAST(migs.avg_user_impact AS DECIMAL(9,2))               AS avg_user_impact,
    CAST(migs.avg_total_user_cost
         * (migs.avg_user_impact / 100.0)
         * (migs.user_seeks + migs.user_scans) AS DECIMAL(18,4)) AS improvement_measure
FROM sys.dm_db_missing_index_group_stats AS migs
JOIN sys.dm_db_missing_index_groups      AS mig
    ON mig.index_group_handle = migs.group_handle
JOIN sys.dm_db_missing_index_details     AS mid
    ON mid.index_handle = mig.index_handle
JOIN sys.objects                         AS o
    ON o.object_id = mid.object_id
WHERE mid.database_id = DB_ID()
ORDER BY improvement_measure DESC;
