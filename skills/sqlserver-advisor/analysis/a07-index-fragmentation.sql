-- =====================================================================
-- a07-index-fragmentation.sql  —  dimension: Indexing
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS: fragmented indexes from index_physical (SAMPLED, page_count>=1000):
--        10-30% avg_fragmentation -> REORGANIZE; >30% -> REBUILD.
-- NOTE: ONLINE rebuild is Enterprise-only (Standard = OFFLINE, takes a
--   Sch-M lock). Index maintenance scheduling/automation lives in
--   sqlserver-operations — this is assessment only.
-- =====================================================================

SELECT
    'Indexing'                                              AS dimension,
    p.database_name,
    p.schema_name || '.' || p.table_name
        || '.' || COALESCE(p.index_name, '(heap)')
        || CASE WHEN p.partition_number > 1
                THEN ' [partition ' || p.partition_number || ']' ELSE '' END  AS object_name,
    CASE WHEN p.avg_fragmentation_in_percent > 30 AND p.page_count >= 100000 THEN 'High'
         WHEN p.avg_fragmentation_in_percent > 30                            THEN 'Medium'
         ELSE 'Low' END                                     AS severity,
    'frag=' || fmt_d(p.avg_fragmentation_in_percent, 1) || '%'
        || '; pages=' || fmt_n(p.page_count)
        || '; page_fullness=' || fmt_d(p.avg_page_space_used_in_percent, 1) || '%'  AS metric,
    CASE WHEN p.avg_fragmentation_in_percent > 30
         THEN 'High logical fragmentation.'
         ELSE 'Moderate logical fragmentation.'
    END                                                     AS finding,
    CASE WHEN p.avg_fragmentation_in_percent > 30
         THEN 'REBUILD the index (ONLINE = ON only on Enterprise/Azure; Standard rebuild is OFFLINE and takes a Sch-M lock). [INDEX MAINTENANCE] schedule in a window.'
         ELSE 'REORGANIZE the index (always online, resumable interruption) and UPDATE STATISTICS as needed. [INDEX MAINTENANCE]'
    END                                                     AS recommendation,
    CASE WHEN p.avg_fragmentation_in_percent > 30
         THEN 'Above ~30% fragmentation a rebuild restores contiguous pages and fill factor; consider whether fragmentation even matters on SSD/range-scan workloads first.'
         ELSE 'Between ~10-30% a reorganize defragments leaf pages cheaply without a full rebuild or a long lock.'
    END                                                     AS why,
    'sqlserver-operations'                                  AS consult_skill
FROM index_physical p
WHERE p.page_count >= 1000                    -- contract already samples >=1000; belt & suspenders
  AND p.avg_fragmentation_in_percent >= 10
;
