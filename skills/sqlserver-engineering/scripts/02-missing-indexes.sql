/*******************************************************************************
 * SQL Server - Missing Index Analysis
 *
 * Purpose : Surface the optimizer's missing-index suggestions ranked by an
 *           improvement measure, with a generated CREATE INDEX string for
 *           review. These are HINTS, not orders.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x), Azure SQL DB / Managed Instance.
 * Safety  : READ-ONLY. The CREATE INDEX text is emitted as a STRING column
 *           only - nothing is created or altered by this script.
 *
 * Sections:
 *   1. Missing index suggestions (current DB) with improvement_measure
 *   2. Generated CREATE INDEX statements (REVIEW & CONSOLIDATE before use)
 *
 * CRITICAL REVIEW NOTES (read before creating ANY suggested index):
 *   - The DMVs do NOT consolidate overlapping suggestions. You will see
 *     near-duplicates differing only by an INCLUDE column. MERGE them into
 *     one index (equality keys first in selectivity order, the rest INCLUDE).
 *   - They ignore EXISTING indexes and WRITE cost. Check sys.indexes and
 *     script 01 (index usage) before adding. Every index slows every write.
 *   - improvement_measure is a relative ranking heuristic, not a guarantee.
 *   - Counters RESET on restart (see sqlserver_start_time below).
 ******************************************************************************/
SET NOCOUNT ON;

SELECT sqlserver_start_time,
       DATEDIFF(HOUR, sqlserver_start_time, SYSDATETIME()) AS hours_of_stats
FROM sys.dm_os_sys_info;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Missing Index Suggestions (current database), ranked
  improvement_measure ~ avg_total_user_cost * avg_user_impact * (seeks+scans)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME(mid.database_id)                    AS database_name,
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(mid.object_id, mid.database_id) AS table_name,
    CONVERT(decimal(18,2),
        migs.avg_total_user_cost
        * migs.avg_user_impact
        * (migs.user_seeks + migs.user_scans)
        / 100.0)                                AS improvement_measure,
    migs.user_seeks,
    migs.user_scans,
    migs.avg_user_impact                        AS avg_pct_improvement,
    migs.avg_total_user_cost,
    migs.last_user_seek,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns
FROM sys.dm_db_missing_index_groups        AS mig
JOIN sys.dm_db_missing_index_group_stats   AS migs
    ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details       AS mid
    ON mig.index_handle = mid.index_handle
JOIN sys.objects                           AS o
    ON o.object_id = mid.object_id
WHERE mid.database_id = DB_ID()
ORDER BY improvement_measure DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Generated CREATE INDEX statements (REVIEW & CONSOLIDATE)
  The index_name is a suggestion; rename per your naming convention and
  MERGE overlapping rows from Section 1 into a single index before creating.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    CONVERT(decimal(18,2),
        migs.avg_total_user_cost
        * migs.avg_user_impact
        * (migs.user_seeks + migs.user_scans)
        / 100.0)                                AS improvement_measure,
    'REVIEW/CONSOLIDATE BEFORE CREATING -- '    AS warning,
    'CREATE NONCLUSTERED INDEX '
        + QUOTENAME('IX_'
            + OBJECT_NAME(mid.object_id, mid.database_id)
            + '_' + REPLACE(REPLACE(REPLACE(REPLACE(
                ISNULL(mid.equality_columns, mid.inequality_columns),
                '[', ''), ']', ''), ', ', '_'), ' ', ''))
        + ' ON '
        + QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.'
        + QUOTENAME(OBJECT_NAME(mid.object_id, mid.database_id))
        + ' ('
        + ISNULL(mid.equality_columns, '')
        + CASE
            WHEN mid.equality_columns IS NOT NULL
             AND mid.inequality_columns IS NOT NULL THEN ', '
            ELSE ''
          END
        + ISNULL(mid.inequality_columns, '')
        + ')'
        + ISNULL(' INCLUDE (' + mid.included_columns + ')', '')
        + ';'                                   AS create_index_statement
FROM sys.dm_db_missing_index_groups        AS mig
JOIN sys.dm_db_missing_index_group_stats   AS migs
    ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details       AS mid
    ON mig.index_handle = mid.index_handle
JOIN sys.objects                           AS o
    ON o.object_id = mid.object_id
WHERE mid.database_id = DB_ID()
ORDER BY improvement_measure DESC;
