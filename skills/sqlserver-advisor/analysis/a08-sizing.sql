-- =====================================================================
-- a08-sizing.sql  —  dimension: Sizing & capacity
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS: (1) largest tables by total_space_mb (capacity awareness);
--        (2) high allocated-but-UNUSED space (shrink/rebuild candidate);
--        (3) large UNCOMPRESSED tables (ROW/PAGE compression candidates);
--        (4) very large tables (partitioning candidates);
--        (5) tables where index_space_mb >> data_space_mb (over-indexed).
-- Depth: sizing/maintenance -> sqlserver-operations; compression/partitioning
--        design -> sqlserver-engineering.
-- =====================================================================

-- (1) Largest tables — top 20 by total footprint. Pure awareness/capacity.
WITH biggest AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_space_mb DESC) AS rn
    FROM tables
)
SELECT
    'Sizing & capacity'                                     AS dimension,
    b.database_name,
    b.schema_name || '.' || b.table_name                    AS object_name,
    CASE WHEN b.total_space_mb >= 51200 THEN 'High'         -- >= 50 GB
         WHEN b.total_space_mb >= 10240 THEN 'Medium'       -- >= 10 GB
         ELSE 'Low' END                                     AS severity,
    'total=' || fmt_n(b.total_space_mb) || ' MB'
        || '; rows=' || fmt_n(b.row_count)
        || '; data=' || fmt_n(b.data_space_mb) || ' MB'
        || '; index=' || fmt_n(b.index_space_mb) || ' MB'  AS metric,
    'One of the largest tables by footprint.'               AS finding,
    'Track growth over time (trend successive captures), confirm backup/restore/maintenance windows still fit, and review retention/archival.' AS recommendation,
    'Largest tables drive backup duration, restore RTO, maintenance time, and storage cost — they deserve explicit capacity planning.' AS why,
    'sqlserver-operations'                                  AS consult_skill
FROM biggest b
WHERE b.rn <= 20

UNION ALL

-- (2) High allocated-but-unused space — pages allocated to the table but not
--     holding data (often after large deletes or heap churn).
SELECT
    'Sizing & capacity'                                     AS dimension,
    t.database_name,
    t.schema_name || '.' || t.table_name                    AS object_name,
    CASE WHEN t.unused_space_mb >= 10240 THEN 'High'
         WHEN t.unused_space_mb >= 1024  THEN 'Medium'
         ELSE 'Low' END                                     AS severity,
    'unused=' || fmt_n(t.unused_space_mb) || ' MB'
        || ' of total=' || fmt_n(t.total_space_mb) || ' MB'
        || ' (' || fmt_n(t.unused_space_mb / NULLIF(t.total_space_mb,0) * 100) || '%)'  AS metric,
    'Large amount of allocated-but-unused space.'           AS finding,
    'Investigate the cause (post-delete heap bloat, dropped LOB); an index REBUILD reclaims most of it. Avoid routine shrinks. [INDEX MAINTENANCE]' AS recommendation,
    'Allocated-but-unused pages still occupy disk and get backed up/scanned; reclaiming them shrinks backups and improves scan density.' AS why,
    'sqlserver-operations'                                  AS consult_skill
FROM tables t
WHERE t.unused_space_mb >= 1024
  AND t.unused_space_mb > t.total_space_mb * 0.20           -- >20% wasted

UNION ALL

-- (3) Large uncompressed tables — ROW/PAGE compression trades CPU for I/O
--     and memory footprint; usually a clear win on large, scan-heavy tables.
SELECT
    'Sizing & capacity'                                     AS dimension,
    t.database_name,
    t.schema_name || '.' || t.table_name                    AS object_name,
    CASE WHEN t.total_space_mb >= 10240 THEN 'Medium' ELSE 'Low' END  AS severity,
    'compression=' || COALESCE(t.data_compression_desc, 'NONE')
        || '; total=' || fmt_n(t.total_space_mb) || ' MB'
        || '; rows=' || fmt_n(t.row_count)         AS metric,
    'Large table stored without data compression.'          AS finding,
    'Evaluate ROW or PAGE compression (PAGE for scan-heavy/low-churn; ROW for write-heavy); columnstore for analytic fact tables. [SCHEMA CHANGE]' AS recommendation,
    'Compression cuts pages on disk and in the buffer pool, reducing I/O and memory pressure at a modest CPU cost.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM tables t
WHERE COALESCE(t.data_compression_desc, 'NONE') = 'NONE'
  AND t.total_space_mb >= 1024

UNION ALL

-- (4) Very large tables — partitioning candidates (manageability: sliding
--     window, piecemeal maintenance, partition elimination on aligned keys).
SELECT
    'Sizing & capacity'                                     AS dimension,
    t.database_name,
    t.schema_name || '.' || t.table_name                    AS object_name,
    'Medium'                                                AS severity,
    'total=' || fmt_n(t.total_space_mb) || ' MB'
        || '; rows=' || fmt_n(t.row_count)
        || '; partitions=' || t.partition_count             AS metric,
    'Very large table with few/no partitions.'              AS finding,
    'Evaluate table partitioning for data-lifecycle management (fast SWITCH, piecemeal index maintenance) — not as a generic speed fix. [SCHEMA CHANGE]' AS recommendation,
    'Partitioning helps manage and age out very large tables and enables partition elimination on aligned predicates; it is a manageability lever.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM tables t
WHERE t.total_space_mb >= 51200                            -- >= 50 GB
  AND t.partition_count <= 1

UNION ALL

-- (5) Over-indexed tables — nonclustered index space dwarfs the data itself.
SELECT
    'Sizing & capacity'                                     AS dimension,
    t.database_name,
    t.schema_name || '.' || t.table_name                    AS object_name,
    CASE WHEN t.index_space_mb >= 10240 THEN 'Medium' ELSE 'Low' END  AS severity,
    'index=' || fmt_n(t.index_space_mb) || ' MB'
        || ' vs data=' || fmt_n(t.data_space_mb) || ' MB'
        || ' (ratio ' || fmt_d(t.index_space_mb / NULLIF(t.data_space_mb,0), 1) || 'x)'  AS metric,
    'Index space substantially exceeds data space (likely over-indexed).' AS finding,
    'Cross-check with a04 (unused) and a05 (duplicate/overlapping) and consolidate/drop redundant indexes. [SCHEMA CHANGE]' AS recommendation,
    'When indexes outweigh the data, write amplification and storage cost are likely paying for redundant or unused indexes.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM tables t
WHERE t.data_space_mb >= 100
  AND t.index_space_mb > t.data_space_mb * 2                -- indexes > 2x data
;
