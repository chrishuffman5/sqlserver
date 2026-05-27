/*******************************************************************************
 * SQL Server - Index Usage Analysis
 *
 * Purpose : Report read vs. write activity per index to find unused indexes
 *           (write-only overhead) and rarely-used wide indexes worth reviewing.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x), Azure SQL DB / Managed Instance.
 * Safety  : READ-ONLY. No data, schema, or configuration changes. All
 *           recommendations are emitted as comment/text columns only.
 *
 * Sections:
 *   1. Index usage detail (seeks / scans / lookups / updates per index)
 *   2. Unused indexes (no reads, has writes) - drop candidates (REVIEW)
 *   3. Rarely-used wide indexes (high key/include count, few reads)
 *
 * NOTE: sys.dm_db_index_usage_stats counters RESET on instance restart
 *       (and historically on index REBUILD). Interpret only over a
 *       representative uptime window: SELECT sqlserver_start_time below.
 *       Maintenance/DROP execution belongs to sqlserver-operations.
 ******************************************************************************/
SET NOCOUNT ON;

-- Context: how long have the counters been accumulating?
SELECT sqlserver_start_time,
       DATEDIFF(HOUR, sqlserver_start_time, SYSDATETIME()) AS hours_of_stats
FROM sys.dm_os_sys_info;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Index Usage Detail (current database)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(i.object_id)                    AS table_name,
    i.name                                      AS index_name,
    i.type_desc                                 AS index_type,
    i.is_unique,
    i.is_primary_key,
    ISNULL(us.user_seeks,   0)                  AS user_seeks,
    ISNULL(us.user_scans,   0)                  AS user_scans,
    ISNULL(us.user_lookups, 0)                  AS user_lookups,
    ISNULL(us.user_seeks,0) + ISNULL(us.user_scans,0)
        + ISNULL(us.user_lookups,0)             AS total_reads,
    ISNULL(us.user_updates, 0)                  AS user_updates,    -- write maintenance cost
    us.last_user_seek,
    us.last_user_scan,
    us.last_user_lookup,
    us.last_user_update
FROM sys.indexes AS i
JOIN sys.objects AS o
    ON i.object_id = o.object_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON  us.object_id = i.object_id
    AND us.index_id  = i.index_id
    AND us.database_id = DB_ID()
WHERE o.is_ms_shipped = 0
  AND i.type > 0                                 -- skip heaps (index_id 0)
ORDER BY user_updates DESC, total_reads ASC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Unused Indexes - DROP CANDIDATES (REVIEW before acting)
  Zero reads but nonzero writes = pure write/maintenance overhead.
  Excludes PK/unique (may enforce integrity) - review those separately.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(i.object_id)                    AS table_name,
    i.name                                      AS index_name,
    i.type_desc                                 AS index_type,
    ISNULL(us.user_updates, 0)                  AS writes_no_reads,
    'REVIEW: 0 reads since '
        + CONVERT(varchar(20), si.sqlserver_start_time, 120)
        + ' - candidate to DROP if window is representative. '
        + '/* DROP INDEX ' + QUOTENAME(i.name) + ' ON '
        + QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.'
        + QUOTENAME(OBJECT_NAME(i.object_id)) + '; */'
                                                AS recommendation
FROM sys.indexes AS i
JOIN sys.objects AS o
    ON i.object_id = o.object_id
CROSS JOIN sys.dm_os_sys_info AS si
LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON  us.object_id = i.object_id
    AND us.index_id  = i.index_id
    AND us.database_id = DB_ID()
WHERE o.is_ms_shipped = 0
  AND i.type_desc IN (N'NONCLUSTERED', N'NONCLUSTERED COLUMNSTORE')
  AND i.is_primary_key = 0
  AND i.is_unique      = 0
  AND ISNULL(us.user_seeks,0) + ISNULL(us.user_scans,0)
      + ISNULL(us.user_lookups,0) = 0
  AND ISNULL(us.user_updates,0) > 0
ORDER BY writes_no_reads DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Rarely-Used WIDE Indexes (many columns, very few reads)
  Wide indexes cost the most to maintain; low read benefit = review target.
──────────────────────────────────────────────────────────────────────────────*/
WITH idx_width AS (
    SELECT
        ic.object_id,
        ic.index_id,
        SUM(CASE WHEN ic.is_included_column = 0 THEN 1 ELSE 0 END) AS key_cols,
        SUM(CASE WHEN ic.is_included_column = 1 THEN 1 ELSE 0 END) AS include_cols,
        COUNT(*)                                                  AS total_cols
    FROM sys.index_columns AS ic
    GROUP BY ic.object_id, ic.index_id
)
SELECT
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(i.object_id)                    AS table_name,
    i.name                                      AS index_name,
    w.key_cols,
    w.include_cols,
    w.total_cols,
    ISNULL(us.user_seeks,0) + ISNULL(us.user_scans,0)
        + ISNULL(us.user_lookups,0)             AS total_reads,
    ISNULL(us.user_updates, 0)                  AS user_updates,
    'REVIEW: wide index ('
        + CAST(w.total_cols AS varchar(10)) + ' cols) with few reads - '
        + 'verify it earns its maintenance cost.'
                                                AS recommendation
FROM sys.indexes AS i
JOIN sys.objects AS o
    ON i.object_id = o.object_id
JOIN idx_width AS w
    ON  w.object_id = i.object_id
    AND w.index_id  = i.index_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON  us.object_id = i.object_id
    AND us.index_id  = i.index_id
    AND us.database_id = DB_ID()
WHERE o.is_ms_shipped = 0
  AND i.type_desc = N'NONCLUSTERED'
  AND w.total_cols >= 5
  AND (ISNULL(us.user_seeks,0) + ISNULL(us.user_scans,0)
       + ISNULL(us.user_lookups,0)) < ISNULL(us.user_updates,0)
ORDER BY w.total_cols DESC, total_reads ASC;
