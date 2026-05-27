/*******************************************************************************
 * SQL Server - Columnstore Rowgroup Health
 *
 * Purpose : Assess columnstore rowgroup quality - state distribution, rows per
 *           rowgroup vs. the ideal ~1,048,576, deleted-rows ratio, and trim
 *           reasons - to guide REORGANIZE/REBUILD decisions.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x), Azure SQL DB / Managed Instance.
 * Safety  : READ-ONLY. No REORGANIZE/REBUILD is performed - text only.
 *
 * Sections:
 *   1. Rowgroup state summary per columnstore index (OPEN/CLOSED/COMPRESSED)
 *   2. Compressed rowgroup quality (rows vs ideal, deleted ratio, trim reason)
 *   3. Per-index health recommendation (REORGANIZE / REBUILD as comment)
 *
 * NOTE: Ideal compressed rowgroup ~ 1,048,576 (2^20) rows. Bulk loads of
 *       >= ~102,400 rows/batch bypass the delta store. The tuple mover
 *       compresses CLOSED delta rowgroups in the background. Executing the
 *       maintenance belongs to sqlserver-operations.
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Rowgroup State Summary per Columnstore Index
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(rg.object_id)                   AS table_name,
    i.name                                      AS index_name,
    i.type_desc                                 AS index_type,
    rg.state_desc                               AS rowgroup_state,   -- OPEN/CLOSED/COMPRESSED/TOMBSTONE
    COUNT(*)                                    AS rowgroup_count,
    SUM(rg.total_rows)                          AS total_rows,
    SUM(rg.deleted_rows)                        AS deleted_rows
FROM sys.dm_db_column_store_row_group_physical_stats AS rg
JOIN sys.indexes AS i
    ON  i.object_id = rg.object_id
    AND i.index_id  = rg.index_id
JOIN sys.objects AS o
    ON o.object_id = rg.object_id
WHERE o.is_ms_shipped = 0
GROUP BY SCHEMA_NAME(o.schema_id), OBJECT_NAME(rg.object_id),
         i.name, i.type_desc, rg.state_desc
ORDER BY schema_name, table_name, index_name, rowgroup_state;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Compressed Rowgroup Quality
  Small (trimmed) rowgroups and high deleted ratios hurt batch-mode efficiency.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(rg.object_id)                   AS table_name,
    i.name                                      AS index_name,
    rg.partition_number,
    rg.row_group_id,
    rg.total_rows,
    rg.deleted_rows,
    CASE WHEN rg.total_rows > 0
         THEN CAST(rg.deleted_rows * 100.0 / rg.total_rows AS decimal(5,2))
         ELSE 0 END                             AS deleted_pct,
    CAST(rg.total_rows * 100.0 / 1048576 AS decimal(5,2)) AS pct_of_ideal_fill,
    rg.trim_reason_desc                         AS trim_reason,      -- why < ideal size
    rg.size_in_bytes / 1024                      AS size_kb
FROM sys.dm_db_column_store_row_group_physical_stats AS rg
JOIN sys.indexes AS i
    ON  i.object_id = rg.object_id
    AND i.index_id  = rg.index_id
JOIN sys.objects AS o
    ON o.object_id = rg.object_id
WHERE o.is_ms_shipped = 0
  AND rg.state_desc = 'COMPRESSED'
  AND (rg.total_rows < 100000                                  -- under-full rowgroup
       OR rg.deleted_rows * 1.0 / NULLIF(rg.total_rows,0) > 0.10) -- >10% deleted
ORDER BY deleted_pct DESC, pct_of_ideal_fill ASC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Per-Index Health Recommendation
──────────────────────────────────────────────────────────────────────────────*/
;WITH agg AS (
    SELECT
        rg.object_id,
        rg.index_id,
        SUM(CASE WHEN rg.state_desc = 'COMPRESSED' THEN 1 ELSE 0 END) AS compressed_rgs,
        SUM(CASE WHEN rg.state_desc IN ('OPEN','CLOSED') THEN 1 ELSE 0 END) AS delta_rgs,
        SUM(rg.total_rows)    AS total_rows,
        SUM(rg.deleted_rows)  AS deleted_rows,
        AVG(CASE WHEN rg.state_desc = 'COMPRESSED'
                 THEN CAST(rg.total_rows AS bigint) END) AS avg_compressed_rg_rows
    FROM sys.dm_db_column_store_row_group_physical_stats AS rg
    GROUP BY rg.object_id, rg.index_id
)
SELECT
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(a.object_id)                    AS table_name,
    i.name                                      AS index_name,
    a.compressed_rgs,
    a.delta_rgs,
    a.avg_compressed_rg_rows,
    CASE WHEN a.total_rows > 0
         THEN CAST(a.deleted_rows * 100.0 / a.total_rows AS decimal(5,2))
         ELSE 0 END                             AS overall_deleted_pct,
    CASE
        WHEN a.total_rows > 0
         AND a.deleted_rows * 1.0 / a.total_rows > 0.10
            THEN 'CONSIDER REBUILD: >10% deleted rows (deletes are logical until '
               + 'rebuild) - see sqlserver-operations.'
        WHEN a.avg_compressed_rg_rows < 100000 OR a.delta_rgs > 1
            THEN 'CONSIDER REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON): small/'
               + 'fragmented rowgroups or lingering delta stores.'
        ELSE 'OK - rowgroup quality looks healthy.'
    END                                         AS recommendation
FROM agg AS a
JOIN sys.indexes AS i
    ON  i.object_id = a.object_id
    AND i.index_id  = a.index_id
JOIN sys.objects AS o
    ON o.object_id = a.object_id
WHERE o.is_ms_shipped = 0
ORDER BY overall_deleted_pct DESC, table_name;
