/*******************************************************************************
 * SQL Server - Index Fragmentation Assessment
 *
 * Purpose : Assess logical fragmentation and page fullness per index, with a
 *           reorg/rebuild RECOMMENDATION column. ASSESSMENT ONLY.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x), Azure SQL DB / Managed Instance.
 * Safety  : READ-ONLY. Uses the LIMITED scan mode (cheap, leaf-level only).
 *           No REBUILD/REORGANIZE is performed - recommendations are text only.
 *
 * Sections:
 *   1. Fragmentation & page fullness (LIMITED) with action recommendation
 *
 * MAINTENANCE NOTE: This script only ASSESSES. The actual REBUILD/REORGANIZE,
 *   scheduling, ONLINE options, and FILLFACTOR tuning belong to
 *   sqlserver-operations. Conventional thresholds (heuristic, tune to your
 *   workload): < 5% none; 5-30% REORGANIZE; > 30% REBUILD; and ignore tiny
 *   indexes (< ~1000 pages / ~8 MB) where fragmentation rarely matters.
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Fragmentation & Page Fullness (LIMITED scan, current database)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(ips.object_id)                  AS table_name,
    i.name                                      AS index_name,
    i.type_desc                                 AS index_type,
    ips.partition_number,
    ips.page_count,
    CAST(ips.page_count * 8.0 / 1024 AS decimal(18,2)) AS size_mb,
    CAST(ips.avg_fragmentation_in_percent AS decimal(5,2)) AS avg_frag_pct,
    CAST(ips.avg_page_space_used_in_percent AS decimal(5,2)) AS avg_page_fullness_pct,
    ips.fragment_count,
    CASE
        WHEN ips.page_count < 1000
            THEN 'SKIP - too small (< ~8 MB); fragmentation rarely matters'
        WHEN ips.avg_fragmentation_in_percent > 30
            THEN 'CONSIDER REBUILD (frag > 30%) - see sqlserver-operations'
        WHEN ips.avg_fragmentation_in_percent >= 5
            THEN 'CONSIDER REORGANIZE (frag 5-30%) - see sqlserver-operations'
        ELSE 'OK - no action (frag < 5%)'
    END                                         AS recommendation
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
JOIN sys.indexes AS i
    ON  i.object_id = ips.object_id
    AND i.index_id  = ips.index_id
JOIN sys.objects AS o
    ON o.object_id = ips.object_id
WHERE o.is_ms_shipped = 0
  AND i.type > 0                                 -- skip heaps
  AND ips.index_level = 0                        -- leaf level only
ORDER BY ips.avg_fragmentation_in_percent DESC, size_mb DESC;
