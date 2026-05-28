-- =====================================================================
-- a99-recommendations.sql  —  the consolidated, prioritized recommendation set
-- ---------------------------------------------------------------------
-- PREREQUISITE: run analysis/00-load.sql first. This file is SELF-CONTAINED:
--   it re-issues the SELECT body of every analysis file a01..a10 (so you do
--   NOT need to .read the individual files), UNION ALLs them into the unified
--   findings shape, and emits:
--     RESULT 1 — all findings, ordered by severity (High>Medium>Low) then dimension;
--     RESULT 2 — a summary: counts by dimension x severity (+ totals).
--
-- Every recommendation is ADVISORY. Validate in a non-production copy, and
-- follow the cross-referenced sibling skill (consult_skill) for the "how".
-- Tags in recommendations: [SCHEMA CHANGE] / [INDEX MAINTENANCE] / [CONFIG
-- CHANGE] / [INVESTIGATE] — never run a mutating statement blind in prod.
--
-- The findings logic below is kept VERBATIM in sync with a01..a10; if you
-- edit an analysis file, mirror the change here (or just .read each file).
-- =====================================================================

-- ---------------------------------------------------------------------
-- RESULT 1: prioritized findings
-- ---------------------------------------------------------------------
WITH server_uptime AS (
    SELECT server_name,
           date_diff('day', sqlserver_start_time, captured_at) AS uptime_days
    FROM server_info
),
findings AS (

    -------------------------------------------------------------------
    -- a01: heaps, no-PK, forwarded records  (Table design)
    -------------------------------------------------------------------
    SELECT 'Table design' AS dimension, t.database_name,
        t.schema_name || '.' || t.table_name AS object_name,
        CASE WHEN t.row_count >= 1000000 THEN 'High'
             WHEN t.row_count >= 100000  THEN 'Medium' ELSE 'Low' END AS severity,
        'rows=' || fmt_n(t.row_count) || '; total=' || fmt_n(t.total_space_mb)
            || ' MB; partitions=' || t.partition_count AS metric,
        'Heap (no clustered index) holding a significant row count.' AS finding,
        'Add a narrow, unique, ever-increasing clustered index (or PK) unless this is a deliberate staging/bulk-load heap.' AS recommendation,
        'Heaps have no logical ordering; scans follow IAM/RID chains and forwarded records accrue, inflating reads.' AS why,
        'sqlserver-engineering' AS consult_skill
    FROM tables t WHERE t.is_heap = TRUE AND t.row_count >= 100000
    UNION ALL
    SELECT 'Table design', t.database_name, t.schema_name || '.' || t.table_name,
        CASE WHEN t.row_count >= 1000000 THEN 'High'
             WHEN t.row_count >= 10000 THEN 'Medium' ELSE 'Low' END,
        'rows=' || fmt_n(t.row_count) || '; is_heap=' || t.is_heap,
        'Table has no primary key.',
        'Define a primary key (and a clustered index unless intentionally a heap) to guarantee row identity and support FKs/replication.',
        'No PK means no enforced row identity; complicates dedup, referential integrity, change tracking, and many HA features.',
        'sqlserver-engineering'
    FROM tables t WHERE t.has_primary_key = FALSE
    UNION ALL
    SELECT 'Table design', p.database_name, p.schema_name || '.' || p.table_name,
        CASE WHEN p.forwarded_record_count >= 100000 THEN 'High'
             WHEN p.forwarded_record_count >= 1000 THEN 'Medium' ELSE 'Low' END,
        'forwarded_records=' || fmt_n(p.forwarded_record_count) || '; pages=' || fmt_n(p.page_count),
        'Heap accumulating forwarded records.',
        'Add a clustered index to eliminate forwarding, or (interim) ALTER TABLE ... REBUILD to clear forwarded rows. [SCHEMA CHANGE] validate in non-prod first.',
        'Each forwarded record costs an extra page read; this is pure overhead unique to heaps under UPDATE-driven row growth.',
        'sqlserver-engineering'
    FROM index_physical p WHERE p.index_id = 0 AND p.forwarded_record_count > 0

    UNION ALL
    -------------------------------------------------------------------
    -- a02: clustered-key smells  (Table design)
    -------------------------------------------------------------------
    SELECT 'Table design', i.database_name,
        i.schema_name || '.' || i.table_name || '.' || i.index_name,
        'Medium',
        'index_type=' || i.index_type_desc || '; is_unique=' || i.is_unique,
        'Clustered index is not unique.',
        'Make the clustered key unique (or base it on the PK). [SCHEMA CHANGE] validate in non-prod.',
        'Non-unique clustered keys get a hidden uniquifier that bloats the row locator copied into every nonclustered index.',
        'sqlserver-engineering'
    FROM indexes i WHERE i.index_type_desc = 'CLUSTERED' AND i.is_unique = FALSE
    UNION ALL
    SELECT 'Table design', i.database_name,
        i.schema_name || '.' || i.table_name || '.' || i.index_name,
        'High',
        'leading_key=' || c.column_name || ' (' || c.data_type || ')',
        'Clustered index leads on a uniqueidentifier/GUID column.',
        'Cluster on a sequential key (IDENTITY/SEQUENCE); if a GUID is required use NEWSEQUENTIALID() or a non-clustered GUID PK. [SCHEMA CHANGE]',
        'Random GUIDs insert in random key order, causing constant mid-page splits, fragmentation, and write amplification.',
        'sqlserver-engineering'
    FROM indexes i
    JOIN columns c ON c.database_name = i.database_name AND c.schema_name = i.schema_name
        AND c.table_name = i.table_name AND c.column_name = trim(split_part(i.key_column_list, ',', 1))
    WHERE i.index_type_desc = 'CLUSTERED' AND i.key_column_list IS NOT NULL
        AND regexp_matches(c.data_type, '(?i)uniqueidentifier|guid')
    UNION ALL
    SELECT 'Table design', k.database_name,
        k.schema_name || '.' || k.table_name || '.' || k.index_name,
        CASE WHEN k.key_bytes >= 200 THEN 'High' ELSE 'Medium' END,
        'clustered_key_bytes=' || fmt_n(k.key_bytes) || '; key_cols=' || k.key_column_list,
        'Clustered key is wide.',
        'Narrow the clustered key (consider a surrogate IDENTITY key); move wide columns out of the key. [SCHEMA CHANGE]',
        'Every nonclustered index stores the full clustered key as its row locator, so a wide key bloats all of them on disk and in memory.',
        'sqlserver-engineering'
    FROM (
        SELECT i.database_name, i.schema_name, i.table_name, i.index_name, i.key_column_list,
               SUM(c.max_length_bytes) AS key_bytes
        FROM indexes i
        JOIN columns c ON c.database_name = i.database_name AND c.schema_name = i.schema_name
            AND c.table_name = i.table_name
            AND (', ' || i.key_column_list || ', ') LIKE '%, ' || c.column_name || ', %'
        WHERE i.index_type_desc = 'CLUSTERED' AND i.key_column_list IS NOT NULL
        GROUP BY i.database_name, i.schema_name, i.table_name, i.index_name, i.key_column_list
    ) k WHERE k.key_bytes >= 100
    UNION ALL
    SELECT 'Table design', t.database_name, t.schema_name || '.' || t.table_name,
        'Medium',
        'rows=' || fmt_n(t.row_count) || '; total=' || fmt_n(t.total_space_mb) || ' MB',
        'Large table is a heap (no clustered index).',
        'Evaluate a clustered index on the primary access path; weigh against deliberate heap use (staging, bulk load). [SCHEMA CHANGE]',
        'A clustered index gives ordered access and avoids RID lookups/forwarded records; most OLTP tables benefit.',
        'sqlserver-engineering'
    FROM tables t WHERE t.is_heap = TRUE AND t.row_count >= 500000

    UNION ALL
    -------------------------------------------------------------------
    -- a03: data-type smells  (Table design)
    -------------------------------------------------------------------
    SELECT 'Table design', c.database_name,
        c.schema_name || '.' || c.table_name || '.' || c.column_name,
        'Low',
        'type=' || c.data_type || '; max_length_bytes=' || c.max_length_bytes,
        'LOB MAX column — verify it actually needs unbounded length.',
        'If real values are short/bounded, switch to a sized (N)VARCHAR(n)/VARBINARY(n); reserve MAX for genuine large objects.',
        'MAX columns can store off-row, hurt scans, inflate memory grants, and block ONLINE index operations.',
        'sqlserver-engineering'
    FROM columns c WHERE regexp_matches(c.data_type, '(?i)varchar|nvarchar|varbinary') AND c.max_length_bytes = -1
    UNION ALL
    SELECT 'Table design', c.database_name,
        c.schema_name || '.' || c.table_name || '.' || c.column_name,
        'Medium',
        'type=' || c.data_type,
        'Deprecated legacy LOB type (text/ntext/image).',
        'Migrate to VARCHAR(MAX)/NVARCHAR(MAX)/VARBINARY(MAX); the legacy types are deprecated and lack modern string functions. [SCHEMA CHANGE]',
        'text/ntext/image are slated for removal, behave poorly with many T-SQL functions, and complicate replication/AG.',
        'sqlserver-engineering'
    FROM columns c WHERE lower(c.data_type) IN ('text', 'ntext', 'image')
    UNION ALL
    SELECT 'Table design', fk.database_name,
        fk.schema_name || '.' || fk.table_name || '.' || fk.fk_name,
        'High',
        'parent=' || pc.column_name || ' ' || pc.data_type || '(' || pc.max_length_bytes || ')'
            || '  vs  referenced=' || rc.column_name || ' ' || rc.data_type || '(' || rc.max_length_bytes || ')',
        'Foreign-key column type/length differs from the referenced column.',
        'Align the FK column''s data type and length with the referenced key; rebuild the FK after the column change. [SCHEMA CHANGE]',
        'Mismatched join types inject CONVERT_IMPLICIT, make the FK join non-SARGable, and can defeat index seeks on lookups.',
        'sqlserver-engineering'
    FROM foreign_keys fk
    JOIN columns pc ON pc.database_name = fk.database_name AND pc.schema_name = fk.schema_name
        AND pc.table_name = fk.table_name AND pc.column_name = trim(split_part(fk.parent_column_list, ',', 1))
    JOIN columns rc ON rc.database_name = fk.database_name AND rc.schema_name = fk.referenced_schema
        AND rc.table_name = fk.referenced_table AND rc.column_name = trim(split_part(fk.referenced_column_list, ',', 1))
    WHERE lower(pc.data_type) <> lower(rc.data_type) OR pc.max_length_bytes <> rc.max_length_bytes
    UNION ALL
    SELECT 'Table design', w.database_name, w.schema_name || '.' || w.table_name,
        'Medium',
        'summed_max_width_bytes=' || fmt_n(w.row_bytes) || '; columns=' || w.col_count,
        'Declared column widths sum beyond the 8060-byte in-row limit.',
        'Review for over-wide (N)VARCHAR declarations; right-size column lengths; consider vertical split for rarely-used wide columns. [SCHEMA CHANGE]',
        'When in-row data exceeds 8060 bytes, variable-length columns push off-row, adding pointer indirection and extra reads.',
        'sqlserver-engineering'
    FROM (
        SELECT database_name, schema_name, table_name,
               SUM(CASE WHEN max_length_bytes > 0 THEN max_length_bytes ELSE 0 END) AS row_bytes,
               COUNT(*) AS col_count
        FROM columns GROUP BY database_name, schema_name, table_name
    ) w WHERE w.row_bytes > 8060
    UNION ALL
    SELECT 'Table design', n.database_name, n.schema_name || '.' || n.table_name,
        'Low',
        'nullable=' || n.nullable_cols || '/' || n.col_count
            || ' (' || fmt_n(n.nullable_ratio * 100) || '%)',
        'Very high ratio of nullable columns.',
        'Review whether optional attributes belong in a separate/related table; consider SPARSE columns for genuinely sparse data. [SCHEMA CHANGE]',
        'A table that is mostly nullable columns often hides multiple entities or optional sub-types that normalize better apart.',
        'sqlserver-engineering'
    FROM (
        SELECT database_name, schema_name, table_name,
               COUNT(*) AS col_count,
               SUM(CASE WHEN is_nullable THEN 1 ELSE 0 END) AS nullable_cols,
               SUM(CASE WHEN is_nullable THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS nullable_ratio
        FROM columns GROUP BY database_name, schema_name, table_name
    ) n WHERE n.col_count >= 10 AND n.nullable_ratio >= 0.8

    UNION ALL
    -------------------------------------------------------------------
    -- a04: unused / disabled indexes  (Indexing)
    -------------------------------------------------------------------
    SELECT 'Indexing', iu.database_name,
        iu.schema_name || '.' || iu.table_name || '.' || iu.index_name,
        CASE WHEN COALESCE(u.uptime_days,0) < 7 THEN 'Low'
             WHEN iu.user_updates >= 100000 THEN 'High'
             WHEN iu.user_updates >= 1000 THEN 'Medium' ELSE 'Low' END,
        'reads=' || (iu.user_seeks + iu.user_scans + iu.user_lookups)
            || ' (seeks=' || iu.user_seeks || ', scans=' || iu.user_scans || ', lookups=' || iu.user_lookups || ')'
            || '; writes=' || fmt_n(iu.user_updates) || '; uptime=' || COALESCE(u.uptime_days,0) || 'd',
        CASE WHEN (iu.user_seeks + iu.user_scans + iu.user_lookups) = 0
             THEN 'Nonclustered index is written but never read.'
             ELSE 'Nonclustered index is read far less than it is written (low read:write ratio).' END,
        'Confirm across a representative workload window, then consider dropping (or disabling) this index. [SCHEMA CHANGE] validate in non-prod.',
        CASE WHEN COALESCE(u.uptime_days,0) < 7
             THEN 'Index maintenance cost is paid on every write with little/no read benefit — but usage counters reset at restart and uptime is only '
                  || COALESCE(u.uptime_days,0) || ' day(s), so treat this as low-confidence until a fuller window is observed.'
             ELSE 'Index maintenance cost is paid on every write with little/no read benefit; dropping it reduces write amplification and storage.' END,
        'sqlserver-engineering'
    FROM index_usage iu
    JOIN indexes i ON i.database_name = iu.database_name AND i.schema_name = iu.schema_name
        AND i.table_name = iu.table_name AND i.index_id = iu.index_id
    LEFT JOIN server_uptime u ON u.server_name = iu.server_name
    WHERE i.index_type_desc = 'NONCLUSTERED' AND i.is_primary_key = FALSE
        AND i.is_unique_constraint = FALSE AND i.is_disabled = FALSE AND iu.user_updates > 0
        AND ( (iu.user_seeks + iu.user_scans + iu.user_lookups) = 0
              OR ( iu.user_updates >= 1000
                   AND (iu.user_seeks + iu.user_scans + iu.user_lookups) < iu.user_updates * 0.01 ) )
    UNION ALL
    SELECT 'Indexing', i.database_name,
        i.schema_name || '.' || i.table_name || '.' || i.index_name,
        'Medium',
        'index_type=' || i.index_type_desc || '; is_disabled=true',
        'Index is disabled.',
        'Decide deliberately: REBUILD to re-enable if it is needed, or DROP it if it is obsolete. [SCHEMA CHANGE]',
        'A disabled index helps no query yet lingers in metadata; a disabled clustered index also makes the whole table inaccessible.',
        'sqlserver-engineering'
    FROM indexes i WHERE i.is_disabled = TRUE

    UNION ALL
    -------------------------------------------------------------------
    -- a05: duplicate / overlapping indexes  (Indexing)
    -------------------------------------------------------------------
    SELECT 'Indexing', a.database_name,
        a.schema_name || '.' || a.table_name || '.' || a.index_name,
        'High',
        'duplicate_of=' || b.index_name || '; keys=(' || a.key_column_list || ')'
            || '; include=(' || COALESCE(a.included_column_list, '') || ')',
        'Exact-duplicate index (same keys and same included columns).',
        'Keep one (prefer the unique/PK or the one with the better name) and DROP the redundant copy. [SCHEMA CHANGE]',
        'Identical indexes double the write and storage cost while adding zero read capability the other does not already provide.',
        'sqlserver-engineering'
    FROM indexes a
    JOIN indexes b ON a.database_name = b.database_name AND a.schema_name = b.schema_name
        AND a.table_name = b.table_name AND a.object_id = b.object_id AND a.index_name < b.index_name
        AND a.key_column_list = b.key_column_list
        AND COALESCE(a.included_column_list,'') = COALESCE(b.included_column_list,'')
    WHERE a.index_type_desc IN ('NONCLUSTERED','CLUSTERED') AND a.key_column_list IS NOT NULL
    UNION ALL
    SELECT 'Indexing', narrow.database_name,
        narrow.schema_name || '.' || narrow.table_name || '.' || narrow.index_name,
        'Medium',
        'keys=(' || narrow.key_column_list || ') is a leading prefix of ' || wide.index_name
            || ' keys=(' || wide.key_column_list || ')',
        'Overlapping index: its key list is a leading prefix of a wider index.',
        'Consider dropping the narrower index if the wider one covers its workload (check seek patterns / included columns first). [SCHEMA CHANGE]',
        'A wider index whose leading keys match the narrower one can usually satisfy the same seeks, making the narrow index redundant.',
        'sqlserver-engineering'
    FROM indexes narrow
    JOIN indexes wide ON narrow.database_name = wide.database_name AND narrow.schema_name = wide.schema_name
        AND narrow.table_name = wide.table_name AND narrow.object_id = wide.object_id
        AND narrow.index_id <> wide.index_id
        AND length(narrow.key_column_list) < length(wide.key_column_list)
        AND (wide.key_column_list || ', ') LIKE (narrow.key_column_list || ', %')
    WHERE narrow.index_type_desc = 'NONCLUSTERED' AND wide.index_type_desc = 'NONCLUSTERED'
        AND narrow.key_column_list IS NOT NULL AND wide.key_column_list IS NOT NULL
        AND narrow.key_column_list <> wide.key_column_list

    UNION ALL
    -------------------------------------------------------------------
    -- a06: missing indexes  (Indexing)  — capped to top 25
    -------------------------------------------------------------------
    SELECT 'Indexing', r.database_name, r.schema_name || '.' || r.table_name,
        CASE WHEN r.improvement_measure >= 100000 THEN 'High'
             WHEN r.improvement_measure >= 10000 THEN 'Medium' ELSE 'Low' END,
        'improvement=' || fmt_n(r.improvement_measure)
            || '; seeks=' || r.user_seeks || '; scans=' || r.user_scans
            || '; avg_impact=' || fmt_n(r.avg_user_impact) || '%'
            || '; eq=(' || COALESCE(r.equality_columns,'') || ')'
            || '; ineq=(' || COALESCE(r.inequality_columns,'') || ')'
            || '; incl=(' || COALESCE(r.included_columns,'') || ')'
            || CASE WHEN COALESCE(w.table_user_updates,0) >= 100000
                    THEN '; table_writes=' || fmt_n(w.table_user_updates) || ' (write-heavy)' ELSE '' END,
        CASE WHEN COALESCE(w.table_user_updates,0) >= 100000
             THEN 'High-impact missing index on a WRITE-HEAVY table — consolidate, do not just add.'
             ELSE 'High-impact missing-index suggestion.' END,
        CASE WHEN COALESCE(w.table_user_updates,0) >= 100000
             THEN 'Merge this suggestion with existing indexes (dedupe keys, fold payload into INCLUDE) and weigh the added write cost before creating. [SCHEMA CHANGE]'
             ELSE 'Design a real index from this hint: order keys equality-then-range, cover the SELECT with INCLUDE, and check for overlap with existing indexes first. [SCHEMA CHANGE]' END,
        'Missing-index DMV suggestions ignore existing indexes and write cost and are not consolidated; apply them only after design review.',
        'sqlserver-engineering'
    FROM (
        SELECT mi.*, ROW_NUMBER() OVER (ORDER BY mi.improvement_measure DESC) AS rn FROM missing_indexes mi
    ) r
    LEFT JOIN (
        SELECT database_name, schema_name, table_name, SUM(user_updates) AS table_user_updates
        FROM index_usage GROUP BY database_name, schema_name, table_name
    ) w ON w.database_name = r.database_name AND w.schema_name = r.schema_name AND w.table_name = r.table_name
    WHERE r.rn <= 25

    UNION ALL
    -------------------------------------------------------------------
    -- a07: fragmentation  (Indexing)
    -------------------------------------------------------------------
    SELECT 'Indexing', p.database_name,
        p.schema_name || '.' || p.table_name || '.' || COALESCE(p.index_name, '(heap)')
            || CASE WHEN p.partition_number > 1 THEN ' [partition ' || p.partition_number || ']' ELSE '' END,
        CASE WHEN p.avg_fragmentation_in_percent > 30 AND p.page_count >= 100000 THEN 'High'
             WHEN p.avg_fragmentation_in_percent > 30 THEN 'Medium' ELSE 'Low' END,
        'frag=' || fmt_d(p.avg_fragmentation_in_percent, 1) || '%'
            || '; pages=' || fmt_n(p.page_count)
            || '; page_fullness=' || fmt_d(p.avg_page_space_used_in_percent, 1) || '%',
        CASE WHEN p.avg_fragmentation_in_percent > 30 THEN 'High logical fragmentation.'
             ELSE 'Moderate logical fragmentation.' END,
        CASE WHEN p.avg_fragmentation_in_percent > 30
             THEN 'REBUILD the index (ONLINE = ON only on Enterprise/Azure; Standard rebuild is OFFLINE and takes a Sch-M lock). [INDEX MAINTENANCE] schedule in a window.'
             ELSE 'REORGANIZE the index (always online, resumable interruption) and UPDATE STATISTICS as needed. [INDEX MAINTENANCE]' END,
        CASE WHEN p.avg_fragmentation_in_percent > 30
             THEN 'Above ~30% fragmentation a rebuild restores contiguous pages and fill factor; consider whether fragmentation even matters on SSD/range-scan workloads first.'
             ELSE 'Between ~10-30% a reorganize defragments leaf pages cheaply without a full rebuild or a long lock.' END,
        'sqlserver-operations'
    FROM index_physical p WHERE p.page_count >= 1000 AND p.avg_fragmentation_in_percent >= 10

    UNION ALL
    -------------------------------------------------------------------
    -- a08: sizing & capacity  (Sizing & capacity)
    -------------------------------------------------------------------
    SELECT 'Sizing & capacity', b.database_name, b.schema_name || '.' || b.table_name,
        CASE WHEN b.total_space_mb >= 51200 THEN 'High'
             WHEN b.total_space_mb >= 10240 THEN 'Medium' ELSE 'Low' END,
        'total=' || fmt_n(b.total_space_mb) || ' MB; rows=' || fmt_n(b.row_count)
            || '; data=' || fmt_n(b.data_space_mb) || ' MB; index=' || fmt_n(b.index_space_mb) || ' MB',
        'One of the largest tables by footprint.',
        'Track growth over time (trend successive captures), confirm backup/restore/maintenance windows still fit, and review retention/archival.',
        'Largest tables drive backup duration, restore RTO, maintenance time, and storage cost — they deserve explicit capacity planning.',
        'sqlserver-operations'
    FROM (SELECT *, ROW_NUMBER() OVER (ORDER BY total_space_mb DESC) AS rn FROM tables) b WHERE b.rn <= 20
    UNION ALL
    SELECT 'Sizing & capacity', t.database_name, t.schema_name || '.' || t.table_name,
        CASE WHEN t.unused_space_mb >= 10240 THEN 'High'
             WHEN t.unused_space_mb >= 1024 THEN 'Medium' ELSE 'Low' END,
        'unused=' || fmt_n(t.unused_space_mb) || ' MB of total=' || fmt_n(t.total_space_mb) || ' MB'
            || ' (' || fmt_n(t.unused_space_mb / NULLIF(t.total_space_mb,0) * 100) || '%)',
        'Large amount of allocated-but-unused space.',
        'Investigate the cause (post-delete heap bloat, dropped LOB); an index REBUILD reclaims most of it. Avoid routine shrinks. [INDEX MAINTENANCE]',
        'Allocated-but-unused pages still occupy disk and get backed up/scanned; reclaiming them shrinks backups and improves scan density.',
        'sqlserver-operations'
    FROM tables t WHERE t.unused_space_mb >= 1024 AND t.unused_space_mb > t.total_space_mb * 0.20
    UNION ALL
    SELECT 'Sizing & capacity', t.database_name, t.schema_name || '.' || t.table_name,
        CASE WHEN t.total_space_mb >= 10240 THEN 'Medium' ELSE 'Low' END,
        'compression=' || COALESCE(t.data_compression_desc,'NONE') || '; total=' || fmt_n(t.total_space_mb)
            || ' MB; rows=' || fmt_n(t.row_count),
        'Large table stored without data compression.',
        'Evaluate ROW or PAGE compression (PAGE for scan-heavy/low-churn; ROW for write-heavy); columnstore for analytic fact tables. [SCHEMA CHANGE]',
        'Compression cuts pages on disk and in the buffer pool, reducing I/O and memory pressure at a modest CPU cost.',
        'sqlserver-engineering'
    FROM tables t WHERE COALESCE(t.data_compression_desc,'NONE') = 'NONE' AND t.total_space_mb >= 1024
    UNION ALL
    SELECT 'Sizing & capacity', t.database_name, t.schema_name || '.' || t.table_name,
        'Medium',
        'total=' || fmt_n(t.total_space_mb) || ' MB; rows=' || fmt_n(t.row_count)
            || '; partitions=' || t.partition_count,
        'Very large table with few/no partitions.',
        'Evaluate table partitioning for data-lifecycle management (fast SWITCH, piecemeal index maintenance) — not as a generic speed fix. [SCHEMA CHANGE]',
        'Partitioning helps manage and age out very large tables and enables partition elimination on aligned predicates; it is a manageability lever.',
        'sqlserver-engineering'
    FROM tables t WHERE t.total_space_mb >= 51200 AND t.partition_count <= 1
    UNION ALL
    SELECT 'Sizing & capacity', t.database_name, t.schema_name || '.' || t.table_name,
        CASE WHEN t.index_space_mb >= 10240 THEN 'Medium' ELSE 'Low' END,
        'index=' || fmt_n(t.index_space_mb) || ' MB vs data=' || fmt_n(t.data_space_mb) || ' MB'
            || ' (ratio ' || fmt_d(t.index_space_mb / NULLIF(t.data_space_mb,0), 1) || 'x)',
        'Index space substantially exceeds data space (likely over-indexed).',
        'Cross-check with a04 (unused) and a05 (duplicate/overlapping) and consolidate/drop redundant indexes. [SCHEMA CHANGE]',
        'When indexes outweigh the data, write amplification and storage cost are likely paying for redundant or unused indexes.',
        'sqlserver-engineering'
    FROM tables t WHERE t.data_space_mb >= 100 AND t.index_space_mb > t.data_space_mb * 2

    UNION ALL
    -------------------------------------------------------------------
    -- a09: query hotspots  (Query hotspots)
    -------------------------------------------------------------------
    SELECT 'Query hotspots', COALESCE(q.database_name,'(unknown)'), 'query_hash ' || q.query_hash,
        CASE WHEN q.rn <= 3 THEN 'High' WHEN q.rn <= 8 THEN 'Medium' ELSE 'Low' END,
        'total_cpu=' || fmt_n(q.total_worker_time_ms) || ' ms; execs=' || fmt_n(q.execution_count)
            || '; avg_cpu=' || fmt_d(q.avg_worker_time_ms, 1) || ' ms; text=' || left(COALESCE(q.sample_query_text,''), 120),
        'Top CPU-consuming query in the plan cache.',
        'Capture the actual plan; check SARGability, cardinality estimates, and missing-index hints (see a06) before tuning. [INVESTIGATE]',
        'High aggregate CPU is where tuning effort pays back most; total worker time ranks the biggest CPU burners across the workload.',
        'sqlserver-engineering'
    FROM (SELECT *, ROW_NUMBER() OVER (ORDER BY total_worker_time_ms DESC) AS rn FROM query_stats) q WHERE q.rn <= 15
    UNION ALL
    SELECT 'Query hotspots', COALESCE(q.database_name,'(unknown)'), 'query_hash ' || q.query_hash,
        CASE WHEN q.rn <= 3 THEN 'High' WHEN q.rn <= 8 THEN 'Medium' ELSE 'Low' END,
        'total_reads=' || fmt_n(q.total_logical_reads) || '; execs=' || fmt_n(q.execution_count)
            || '; avg_reads=' || fmt_n(q.avg_logical_reads) || '; text=' || left(COALESCE(q.sample_query_text,''), 120),
        'Top logical-read (I/O) query in the plan cache.',
        'Look for scans that should be seeks and missing covering indexes (cross-reference a06 for this database). [INVESTIGATE]',
        'High logical reads drive buffer-pool churn and I/O waits; an index or rewrite often collapses the read count dramatically.',
        'sqlserver-engineering'
    FROM (SELECT *, ROW_NUMBER() OVER (ORDER BY total_logical_reads DESC) AS rn FROM query_stats) q WHERE q.rn <= 15
    UNION ALL
    SELECT 'Query hotspots', COALESCE(q.database_name,'(unknown)'), 'query_hash ' || q.query_hash,
        'High',
        'avg_elapsed=' || fmt_d(q.avg_elapsed_time_ms, 1) || ' ms; execs=' || fmt_n(q.execution_count)
            || '; avg_reads=' || fmt_n(q.avg_logical_reads) || '; grant_kb=' || fmt_n(q.total_grant_kb)
            || '; text=' || left(COALESCE(q.sample_query_text,''), 120),
        'Query is both expensive per call and executed frequently.',
        'Prioritise this for tuning — per-call cost multiplies by frequency; verify it is not row-by-row (RBAR) from the app. [INVESTIGATE]',
        'Cost x frequency is the true workload burden; a query that is slow AND hot dominates total resource use even if neither metric is extreme alone.',
        'sqlserver-engineering'
    FROM query_stats q WHERE q.avg_elapsed_time_ms >= 100 AND q.execution_count >= 1000

    UNION ALL
    -------------------------------------------------------------------
    -- a10: configuration  (Configuration)
    -------------------------------------------------------------------
    SELECT 'Configuration', NULL, '(instance)', 'Medium',
        'cost threshold for parallelism = ' || c.value_in_use,
        'Cost threshold for parallelism is at the default of 5.',
        'Raise it (commonly 25-50) so only genuinely expensive plans go parallel; tune with observed CXPACKET/CXCONSUMER. [CONFIG CHANGE]',
        'A threshold of 5 sends trivial queries parallel, wasting workers and producing CXPACKET noise on OLTP workloads.',
        'sqlserver-infrastructure'
    FROM config c WHERE c.config_name = 'cost threshold for parallelism' AND c.value_in_use = 5
    UNION ALL
    SELECT 'Configuration', NULL, '(instance)',
        CASE WHEN s.host_cpu_count >= 16 THEN 'High' ELSE 'Medium' END,
        'max degree of parallelism = 0; host_cpu_count = ' || s.host_cpu_count,
        'MAXDOP is 0 (unlimited) on a multi-core host.',
        'Set MAXDOP to a bounded value (Microsoft guidance: typically up to 8, or the cores per NUMA node, whichever is lower). [CONFIG CHANGE]',
        'MAXDOP 0 lets a single query consume every core, starving concurrent requests and amplifying parallelism waits.',
        'sqlserver-infrastructure'
    FROM config c CROSS JOIN server_info s
    WHERE c.config_name = 'max degree of parallelism' AND c.value_in_use = 0 AND s.host_cpu_count > 1
    UNION ALL
    SELECT 'Configuration', NULL, '(instance)', 'Low',
        'optimize for ad hoc workloads = ' || c.value_in_use,
        'Optimize for ad hoc workloads is disabled.',
        'Enable it so first-time ad-hoc batches cache only a small plan stub, reducing plan-cache bloat from single-use queries. [CONFIG CHANGE]',
        'Without it, every one-off ad-hoc query caches a full plan, wasting plan-cache memory on plans reused exactly once.',
        'sqlserver-infrastructure'
    FROM config c WHERE c.config_name = 'optimize for ad hoc workloads' AND c.value_in_use = 0
    UNION ALL
    SELECT 'Configuration', NULL, '(instance)', 'Low',
        'backup compression default = ' || c.value_in_use,
        'Backup compression is not on by default.',
        'Enable backup compression default (or set COMPRESSION per backup) to shrink backup size and shorten backup/restore time. [CONFIG CHANGE]',
        'Compressed backups are typically far smaller and faster to write/restore for a modest CPU cost — a near-universal win.',
        'sqlserver-infrastructure'
    FROM config c WHERE c.config_name = 'backup compression default' AND c.value_in_use = 0

    UNION ALL
    -------------------------------------------------------------------
    -- a11: database-level statistics & configuration hygiene  (Statistics / Configuration)
    -------------------------------------------------------------------
    SELECT 'Statistics', d.database_name, '(database) ' || d.database_name, 'Medium',
        'is_auto_update_stats_on=' || d.is_auto_update_stats_on,
        'Auto-update statistics is disabled.',
        'Enable AUTO_UPDATE_STATISTICS unless a controlled manual-stats regime fully covers it. [CONFIG CHANGE]',
        'With auto-update off, the optimizer estimates from stale cardinality and produces worse plans as data drifts.',
        'sqlserver-operations'
    FROM db_inventory d WHERE d.database_id > 4 AND d.is_auto_update_stats_on = FALSE
    UNION ALL
    SELECT 'Statistics', d.database_name, '(database) ' || d.database_name, 'Medium',
        'is_auto_create_stats_on=' || d.is_auto_create_stats_on,
        'Auto-create statistics is disabled.',
        'Enable AUTO_CREATE_STATISTICS so the optimizer can build the single-column stats it needs. [CONFIG CHANGE]',
        'Without auto-create, predicates on un-stat''d columns get guessed selectivity, risking bad joins/scans.',
        'sqlserver-operations'
    FROM db_inventory d WHERE d.database_id > 4 AND d.is_auto_create_stats_on = FALSE
    UNION ALL
    SELECT 'Statistics', d.database_name, '(database) ' || d.database_name, 'Low',
        'async_update=' || d.is_auto_update_stats_async_on || '; size=' || fmt_n(d.total_size_mb) || ' MB',
        'Auto-update statistics is synchronous (async disabled) on a sizable database.',
        'Consider AUTO_UPDATE_STATISTICS_ASYNC = ON for OLTP so a stats refresh does not stall the triggering query. [CONFIG CHANGE]',
        'Synchronous auto-update makes the unlucky query wait for the rebuild; async runs it in the background on the old stats.',
        'sqlserver-operations'
    FROM db_inventory d WHERE d.database_id > 4 AND d.is_auto_update_stats_on = TRUE AND d.is_auto_update_stats_async_on = FALSE AND d.total_size_mb >= 10240
    UNION ALL
    SELECT 'Configuration', d.database_name, '(database) ' || d.database_name, 'Medium',
        'page_verify=' || COALESCE(d.page_verify_option_desc,'NONE'),
        'PAGE_VERIFY is not CHECKSUM.',
        'Set PAGE_VERIFY CHECKSUM so torn/bit-rot pages are detected on read; pair with regular DBCC CHECKDB. [CONFIG CHANGE]',
        'TORN_PAGE_DETECTION/NONE miss most I/O corruption; CHECKSUM is the modern default and cheapest early warning.',
        'sqlserver-operations'
    FROM db_inventory d WHERE d.database_id > 4 AND COALESCE(d.page_verify_option_desc,'NONE') <> 'CHECKSUM'
    UNION ALL
    SELECT 'Configuration', d.database_name, '(database) ' || d.database_name, 'Low',
        'is_read_committed_snapshot_on=' || d.is_read_committed_snapshot_on,
        'READ_COMMITTED_SNAPSHOT (RCSI) is disabled.',
        'For read-heavy OLTP, evaluate enabling RCSI to cut reader/writer blocking (size tempdb version store first; needs exclusive DB access). [CONFIG CHANGE]',
        'Default READ COMMITTED takes shared locks that block under write contention; RCSI serves a row version instead — a deliberate trade for tempdb pressure.',
        'sqlserver-engineering'
    FROM db_inventory d WHERE d.database_id > 4 AND d.is_read_committed_snapshot_on = FALSE
    UNION ALL
    SELECT 'Configuration', d.database_name, '(database) ' || d.database_name, 'Low',
        'compatibility_level=' || d.compatibility_level,
        'Database is on an older compatibility level.',
        'Plan an upgrade to a current compatibility level behind Query Store (baseline, watch for regressions); do not bump blind. [CONFIG CHANGE]',
        'Old compat levels lock out newer optimizer/IQP behavior, but raising it can shift plans — Query Store + staged testing is the safe path.',
        'sqlserver-engineering'
    FROM db_inventory d WHERE d.database_id > 4 AND d.compatibility_level < 150
)
SELECT
    dimension, database_name, object_name, severity,
    metric, finding, recommendation, why, consult_skill
FROM findings
ORDER BY
    CASE severity WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END,
    dimension,
    database_name NULLS FIRST,
    object_name;

-- ---------------------------------------------------------------------
-- RESULT 2: summary — counts by dimension x severity (+ row totals).
-- Re-derives the same findings set via a temp view so the counts always
-- match RESULT 1. (Build the view once; it persists for the session.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW advisor_findings AS
WITH server_uptime AS (
    SELECT server_name, date_diff('day', sqlserver_start_time, captured_at) AS uptime_days
    FROM server_info
)
SELECT 'Table design' AS dimension, t.database_name,
    t.schema_name || '.' || t.table_name AS object_name,
    CASE WHEN t.row_count >= 1000000 THEN 'High'
         WHEN t.row_count >= 100000 THEN 'Medium' ELSE 'Low' END AS severity
FROM tables t WHERE t.is_heap = TRUE AND t.row_count >= 100000
UNION ALL
SELECT 'Table design', t.database_name, t.schema_name || '.' || t.table_name,
    CASE WHEN t.row_count >= 1000000 THEN 'High'
         WHEN t.row_count >= 10000 THEN 'Medium' ELSE 'Low' END
FROM tables t WHERE t.has_primary_key = FALSE
UNION ALL
SELECT 'Table design', p.database_name, p.schema_name || '.' || p.table_name,
    CASE WHEN p.forwarded_record_count >= 100000 THEN 'High'
         WHEN p.forwarded_record_count >= 1000 THEN 'Medium' ELSE 'Low' END
FROM index_physical p WHERE p.index_id = 0 AND p.forwarded_record_count > 0
UNION ALL
SELECT 'Table design', i.database_name, i.schema_name || '.' || i.table_name || '.' || i.index_name, 'Medium'
FROM indexes i WHERE i.index_type_desc = 'CLUSTERED' AND i.is_unique = FALSE
UNION ALL
SELECT 'Table design', i.database_name, i.schema_name || '.' || i.table_name || '.' || i.index_name, 'High'
FROM indexes i
JOIN columns c ON c.database_name = i.database_name AND c.schema_name = i.schema_name
    AND c.table_name = i.table_name AND c.column_name = trim(split_part(i.key_column_list, ',', 1))
WHERE i.index_type_desc = 'CLUSTERED' AND i.key_column_list IS NOT NULL
    AND regexp_matches(c.data_type, '(?i)uniqueidentifier|guid')
UNION ALL
SELECT 'Table design', k.database_name, k.schema_name || '.' || k.table_name || '.' || k.index_name,
    CASE WHEN k.key_bytes >= 200 THEN 'High' ELSE 'Medium' END
FROM (
    SELECT i.database_name, i.schema_name, i.table_name, i.index_name, SUM(c.max_length_bytes) AS key_bytes
    FROM indexes i
    JOIN columns c ON c.database_name = i.database_name AND c.schema_name = i.schema_name
        AND c.table_name = i.table_name
        AND (', ' || i.key_column_list || ', ') LIKE '%, ' || c.column_name || ', %'
    WHERE i.index_type_desc = 'CLUSTERED' AND i.key_column_list IS NOT NULL
    GROUP BY i.database_name, i.schema_name, i.table_name, i.index_name
) k WHERE k.key_bytes >= 100
UNION ALL
SELECT 'Table design', t.database_name, t.schema_name || '.' || t.table_name, 'Medium'
FROM tables t WHERE t.is_heap = TRUE AND t.row_count >= 500000
UNION ALL
SELECT 'Table design', c.database_name, c.schema_name || '.' || c.table_name || '.' || c.column_name, 'Low'
FROM columns c WHERE regexp_matches(c.data_type, '(?i)varchar|nvarchar|varbinary') AND c.max_length_bytes = -1
UNION ALL
SELECT 'Table design', c.database_name, c.schema_name || '.' || c.table_name || '.' || c.column_name, 'Medium'
FROM columns c WHERE lower(c.data_type) IN ('text','ntext','image')
UNION ALL
SELECT 'Table design', fk.database_name, fk.schema_name || '.' || fk.table_name || '.' || fk.fk_name, 'High'
FROM foreign_keys fk
JOIN columns pc ON pc.database_name = fk.database_name AND pc.schema_name = fk.schema_name
    AND pc.table_name = fk.table_name AND pc.column_name = trim(split_part(fk.parent_column_list, ',', 1))
JOIN columns rc ON rc.database_name = fk.database_name AND rc.schema_name = fk.referenced_schema
    AND rc.table_name = fk.referenced_table AND rc.column_name = trim(split_part(fk.referenced_column_list, ',', 1))
WHERE lower(pc.data_type) <> lower(rc.data_type) OR pc.max_length_bytes <> rc.max_length_bytes
UNION ALL
SELECT 'Table design', w.database_name, w.schema_name || '.' || w.table_name, 'Medium'
FROM (
    SELECT database_name, schema_name, table_name,
           SUM(CASE WHEN max_length_bytes > 0 THEN max_length_bytes ELSE 0 END) AS row_bytes
    FROM columns GROUP BY database_name, schema_name, table_name
) w WHERE w.row_bytes > 8060
UNION ALL
SELECT 'Table design', n.database_name, n.schema_name || '.' || n.table_name, 'Low'
FROM (
    SELECT database_name, schema_name, table_name, COUNT(*) AS col_count,
           SUM(CASE WHEN is_nullable THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS nullable_ratio
    FROM columns GROUP BY database_name, schema_name, table_name
) n WHERE n.col_count >= 10 AND n.nullable_ratio >= 0.8
UNION ALL
SELECT 'Indexing', iu.database_name, iu.schema_name || '.' || iu.table_name || '.' || iu.index_name,
    CASE WHEN COALESCE(u.uptime_days,0) < 7 THEN 'Low'
         WHEN iu.user_updates >= 100000 THEN 'High'
         WHEN iu.user_updates >= 1000 THEN 'Medium' ELSE 'Low' END
FROM index_usage iu
JOIN indexes i ON i.database_name = iu.database_name AND i.schema_name = iu.schema_name
    AND i.table_name = iu.table_name AND i.index_id = iu.index_id
LEFT JOIN server_uptime u ON u.server_name = iu.server_name
WHERE i.index_type_desc = 'NONCLUSTERED' AND i.is_primary_key = FALSE
    AND i.is_unique_constraint = FALSE AND i.is_disabled = FALSE AND iu.user_updates > 0
    AND ( (iu.user_seeks + iu.user_scans + iu.user_lookups) = 0
          OR ( iu.user_updates >= 1000
               AND (iu.user_seeks + iu.user_scans + iu.user_lookups) < iu.user_updates * 0.01 ) )
UNION ALL
SELECT 'Indexing', i.database_name, i.schema_name || '.' || i.table_name || '.' || i.index_name, 'Medium'
FROM indexes i WHERE i.is_disabled = TRUE
UNION ALL
SELECT 'Indexing', a.database_name, a.schema_name || '.' || a.table_name || '.' || a.index_name, 'High'
FROM indexes a
JOIN indexes b ON a.database_name = b.database_name AND a.schema_name = b.schema_name
    AND a.table_name = b.table_name AND a.object_id = b.object_id AND a.index_name < b.index_name
    AND a.key_column_list = b.key_column_list
    AND COALESCE(a.included_column_list,'') = COALESCE(b.included_column_list,'')
WHERE a.index_type_desc IN ('NONCLUSTERED','CLUSTERED') AND a.key_column_list IS NOT NULL
UNION ALL
SELECT 'Indexing', narrow.database_name, narrow.schema_name || '.' || narrow.table_name || '.' || narrow.index_name, 'Medium'
FROM indexes narrow
JOIN indexes wide ON narrow.database_name = wide.database_name AND narrow.schema_name = wide.schema_name
    AND narrow.table_name = wide.table_name AND narrow.object_id = wide.object_id
    AND narrow.index_id <> wide.index_id
    AND length(narrow.key_column_list) < length(wide.key_column_list)
    AND (wide.key_column_list || ', ') LIKE (narrow.key_column_list || ', %')
WHERE narrow.index_type_desc = 'NONCLUSTERED' AND wide.index_type_desc = 'NONCLUSTERED'
    AND narrow.key_column_list IS NOT NULL AND wide.key_column_list IS NOT NULL
    AND narrow.key_column_list <> wide.key_column_list
UNION ALL
SELECT 'Indexing', r.database_name, r.schema_name || '.' || r.table_name,
    CASE WHEN r.improvement_measure >= 100000 THEN 'High'
         WHEN r.improvement_measure >= 10000 THEN 'Medium' ELSE 'Low' END
FROM (SELECT mi.*, ROW_NUMBER() OVER (ORDER BY mi.improvement_measure DESC) AS rn FROM missing_indexes mi) r
WHERE r.rn <= 25
UNION ALL
SELECT 'Indexing', p.database_name,
    p.schema_name || '.' || p.table_name || '.' || COALESCE(p.index_name,'(heap)'),
    CASE WHEN p.avg_fragmentation_in_percent > 30 AND p.page_count >= 100000 THEN 'High'
         WHEN p.avg_fragmentation_in_percent > 30 THEN 'Medium' ELSE 'Low' END
FROM index_physical p WHERE p.page_count >= 1000 AND p.avg_fragmentation_in_percent >= 10
UNION ALL
SELECT 'Sizing & capacity', b.database_name, b.schema_name || '.' || b.table_name,
    CASE WHEN b.total_space_mb >= 51200 THEN 'High'
         WHEN b.total_space_mb >= 10240 THEN 'Medium' ELSE 'Low' END
FROM (SELECT *, ROW_NUMBER() OVER (ORDER BY total_space_mb DESC) AS rn FROM tables) b WHERE b.rn <= 20
UNION ALL
SELECT 'Sizing & capacity', t.database_name, t.schema_name || '.' || t.table_name,
    CASE WHEN t.unused_space_mb >= 10240 THEN 'High'
         WHEN t.unused_space_mb >= 1024 THEN 'Medium' ELSE 'Low' END
FROM tables t WHERE t.unused_space_mb >= 1024 AND t.unused_space_mb > t.total_space_mb * 0.20
UNION ALL
SELECT 'Sizing & capacity', t.database_name, t.schema_name || '.' || t.table_name,
    CASE WHEN t.total_space_mb >= 10240 THEN 'Medium' ELSE 'Low' END
FROM tables t WHERE COALESCE(t.data_compression_desc,'NONE') = 'NONE' AND t.total_space_mb >= 1024
UNION ALL
SELECT 'Sizing & capacity', t.database_name, t.schema_name || '.' || t.table_name, 'Medium'
FROM tables t WHERE t.total_space_mb >= 51200 AND t.partition_count <= 1
UNION ALL
SELECT 'Sizing & capacity', t.database_name, t.schema_name || '.' || t.table_name,
    CASE WHEN t.index_space_mb >= 10240 THEN 'Medium' ELSE 'Low' END
FROM tables t WHERE t.data_space_mb >= 100 AND t.index_space_mb > t.data_space_mb * 2
UNION ALL
SELECT 'Query hotspots', COALESCE(q.database_name,'(unknown)'), 'query_hash ' || q.query_hash,
    CASE WHEN q.rn <= 3 THEN 'High' WHEN q.rn <= 8 THEN 'Medium' ELSE 'Low' END
FROM (SELECT *, ROW_NUMBER() OVER (ORDER BY total_worker_time_ms DESC) AS rn FROM query_stats) q WHERE q.rn <= 15
UNION ALL
SELECT 'Query hotspots', COALESCE(q.database_name,'(unknown)'), 'query_hash ' || q.query_hash,
    CASE WHEN q.rn <= 3 THEN 'High' WHEN q.rn <= 8 THEN 'Medium' ELSE 'Low' END
FROM (SELECT *, ROW_NUMBER() OVER (ORDER BY total_logical_reads DESC) AS rn FROM query_stats) q WHERE q.rn <= 15
UNION ALL
SELECT 'Query hotspots', COALESCE(q.database_name,'(unknown)'), 'query_hash ' || q.query_hash, 'High'
FROM query_stats q WHERE q.avg_elapsed_time_ms >= 100 AND q.execution_count >= 1000
UNION ALL
SELECT 'Configuration', NULL, '(instance)', 'Medium'
FROM config c WHERE c.config_name = 'cost threshold for parallelism' AND c.value_in_use = 5
UNION ALL
SELECT 'Configuration', NULL, '(instance)', CASE WHEN s.host_cpu_count >= 16 THEN 'High' ELSE 'Medium' END
FROM config c CROSS JOIN server_info s
WHERE c.config_name = 'max degree of parallelism' AND c.value_in_use = 0 AND s.host_cpu_count > 1
UNION ALL
SELECT 'Configuration', NULL, '(instance)', 'Low'
FROM config c WHERE c.config_name = 'optimize for ad hoc workloads' AND c.value_in_use = 0
UNION ALL
SELECT 'Configuration', NULL, '(instance)', 'Low'
FROM config c WHERE c.config_name = 'backup compression default' AND c.value_in_use = 0
UNION ALL
SELECT 'Statistics', d.database_name, '(database) ' || d.database_name, 'Medium'
FROM db_inventory d WHERE d.database_id > 4 AND d.is_auto_update_stats_on = FALSE
UNION ALL
SELECT 'Statistics', d.database_name, '(database) ' || d.database_name, 'Medium'
FROM db_inventory d WHERE d.database_id > 4 AND d.is_auto_create_stats_on = FALSE
UNION ALL
SELECT 'Statistics', d.database_name, '(database) ' || d.database_name, 'Low'
FROM db_inventory d WHERE d.database_id > 4 AND d.is_auto_update_stats_on = TRUE AND d.is_auto_update_stats_async_on = FALSE AND d.total_size_mb >= 10240
UNION ALL
SELECT 'Configuration', d.database_name, '(database) ' || d.database_name, 'Medium'
FROM db_inventory d WHERE d.database_id > 4 AND COALESCE(d.page_verify_option_desc,'NONE') <> 'CHECKSUM'
UNION ALL
SELECT 'Configuration', d.database_name, '(database) ' || d.database_name, 'Low'
FROM db_inventory d WHERE d.database_id > 4 AND d.is_read_committed_snapshot_on = FALSE
UNION ALL
SELECT 'Configuration', d.database_name, '(database) ' || d.database_name, 'Low'
FROM db_inventory d WHERE d.database_id > 4 AND d.compatibility_level < 150;

-- counts by dimension x severity, with a ROLLUP-style total row per dimension
-- and a grand total. (GROUPING SETS keeps it standard + portable.)
SELECT
    COALESCE(dimension, 'ALL DIMENSIONS')         AS dimension,
    COALESCE(severity,  'ALL')                    AS severity,
    COUNT(*)                                      AS finding_count
FROM advisor_findings
GROUP BY GROUPING SETS ( (dimension, severity), (dimension), () )
ORDER BY
    (dimension IS NULL),                          -- grand total last
    dimension,
    CASE severity WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 9 END;
