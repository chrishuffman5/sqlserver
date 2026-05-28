-- =====================================================================
-- a01-design-heaps-no-pk.sql  —  dimension: Table design
-- PREREQUISITE: run analysis/00-load.sql first (loads the capture tables).
-- FINDS: (1) large HEAPS (no clustered index) over a row threshold;
--        (2) tables with NO primary key;
--        (3) heaps suffering forwarded records (a heap-specific read tax).
-- Depth on clustered-key choice / heap remediation: sqlserver-engineering.
-- =====================================================================

-- (1) Large heaps — a heap has no clustered index, so range scans and
--     point lookups read via the RID/IAM chain and tend to fragment.
SELECT
    'Table design'                                          AS dimension,
    t.database_name,
    t.schema_name || '.' || t.table_name                    AS object_name,
    CASE WHEN t.row_count >= 1000000 THEN 'High'
         WHEN t.row_count >= 100000  THEN 'Medium'
         ELSE 'Low' END                                     AS severity,
    'rows=' || fmt_n(t.row_count)
        || '; total=' || fmt_n(t.total_space_mb) || ' MB'
        || '; partitions=' || t.partition_count             AS metric,
    'Heap (no clustered index) holding a significant row count.'  AS finding,
    'Add a narrow, unique, ever-increasing clustered index (or PK) unless this is a deliberate staging/bulk-load heap.' AS recommendation,
    'Heaps have no logical ordering; scans follow IAM/RID chains and forwarded records accrue, inflating reads.'        AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM tables t
WHERE t.is_heap = TRUE
  AND t.row_count >= 100000

UNION ALL

-- (2) No primary key — a data-integrity and (usually) a design smell.
SELECT
    'Table design'                                          AS dimension,
    t.database_name,
    t.schema_name || '.' || t.table_name                    AS object_name,
    CASE WHEN t.row_count >= 1000000 THEN 'High'
         WHEN t.row_count >= 10000   THEN 'Medium'
         ELSE 'Low' END                                     AS severity,
    'rows=' || fmt_n(t.row_count)
        || '; is_heap=' || t.is_heap                        AS metric,
    'Table has no primary key.'                             AS finding,
    'Define a primary key (and a clustered index unless intentionally a heap) to guarantee row identity and support FKs/replication.' AS recommendation,
    'No PK means no enforced row identity; complicates dedup, referential integrity, change tracking, and many HA features.'         AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM tables t
WHERE t.has_primary_key = FALSE

UNION ALL

-- (3) Heaps with forwarded records — forwarded rows force an extra pointer
--     hop on every read; only heaps have them. index_physical is SAMPLED
--     and only covers indexes with page_count >= 1000.
SELECT
    'Table design'                                          AS dimension,
    p.database_name,
    p.schema_name || '.' || p.table_name                    AS object_name,
    CASE WHEN p.forwarded_record_count >= 100000 THEN 'High'
         WHEN p.forwarded_record_count >= 1000   THEN 'Medium'
         ELSE 'Low' END                                     AS severity,
    'forwarded_records=' || fmt_n(p.forwarded_record_count)
        || '; pages=' || fmt_n(p.page_count)       AS metric,
    'Heap accumulating forwarded records.'                  AS finding,
    'Add a clustered index to eliminate forwarding, or (interim) ALTER TABLE ... REBUILD to clear forwarded rows. [SCHEMA CHANGE] validate in non-prod first.' AS recommendation,
    'Each forwarded record costs an extra page read; this is pure overhead unique to heaps under UPDATE-driven row growth.'                                     AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM index_physical p
WHERE p.index_id = 0                       -- heap
  AND p.forwarded_record_count > 0
;
