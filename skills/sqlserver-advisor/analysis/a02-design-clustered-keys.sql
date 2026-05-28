-- =====================================================================
-- a02-design-clustered-keys.sql  —  dimension: Table design
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS: (1) non-unique clustered indexes (hidden 4-byte uniquifier);
--        (2) clustered key LEADING on a uniqueidentifier/GUID (split/frag risk);
--        (3) very WIDE clustered keys (bloat every nonclustered index);
--        (4) large tables that are heaps (missing a clustered index entirely).
-- Depth on clustered-key choice: sqlserver-engineering ("narrow, unique,
-- static, ever-increasing").
-- =====================================================================

-- (1) Non-unique clustered index — SQL Server appends a hidden 4-byte
--     uniquifier per duplicate key, which also widens every NCI row locator.
SELECT
    'Table design'                                          AS dimension,
    i.database_name,
    i.schema_name || '.' || i.table_name || '.' || i.index_name  AS object_name,
    'Medium'                                                AS severity,
    'index_type=' || i.index_type_desc || '; is_unique=' || i.is_unique  AS metric,
    'Clustered index is not unique.'                        AS finding,
    'Make the clustered key unique (or base it on the PK). [SCHEMA CHANGE] validate in non-prod.' AS recommendation,
    'Non-unique clustered keys get a hidden uniquifier that bloats the row locator copied into every nonclustered index.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM indexes i
WHERE i.index_type_desc = 'CLUSTERED'
  AND i.is_unique = FALSE

UNION ALL

-- (2) Clustered key leading on a GUID/uniqueidentifier — random inserts
--     cause page splits + fragmentation. Join the leading key column back
--     to columns to read its data type.
SELECT
    'Table design'                                          AS dimension,
    i.database_name,
    i.schema_name || '.' || i.table_name || '.' || i.index_name  AS object_name,
    'High'                                                  AS severity,
    'leading_key=' || c.column_name || ' (' || c.data_type || ')'  AS metric,
    'Clustered index leads on a uniqueidentifier/GUID column.'     AS finding,
    'Cluster on a sequential key (IDENTITY/SEQUENCE); if a GUID is required use NEWSEQUENTIALID() or a non-clustered GUID PK. [SCHEMA CHANGE]' AS recommendation,
    'Random GUIDs insert in random key order, causing constant mid-page splits, fragmentation, and write amplification.'                       AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM indexes i
JOIN columns c
      ON  c.database_name = i.database_name
      AND c.schema_name   = i.schema_name
      AND c.table_name    = i.table_name
      AND c.column_name   = trim(split_part(i.key_column_list, ',', 1))
WHERE i.index_type_desc = 'CLUSTERED'
  AND i.key_column_list IS NOT NULL
  AND regexp_matches(c.data_type, '(?i)uniqueidentifier|guid')

UNION ALL

-- (3) Very wide clustered key — sum the byte width of all key columns.
--     The clustered key is duplicated into every NCI, so width is paid
--     everywhere. > ~100 bytes is a smell.
SELECT
    'Table design'                                          AS dimension,
    k.database_name,
    k.schema_name || '.' || k.table_name || '.' || k.index_name  AS object_name,
    CASE WHEN k.key_bytes >= 200 THEN 'High' ELSE 'Medium' END    AS severity,
    'clustered_key_bytes=' || fmt_n(k.key_bytes)
        || '; key_cols=' || k.key_column_list               AS metric,
    'Clustered key is wide.'                                AS finding,
    'Narrow the clustered key (consider a surrogate IDENTITY key); move wide columns out of the key. [SCHEMA CHANGE]' AS recommendation,
    'Every nonclustered index stores the full clustered key as its row locator, so a wide key bloats all of them on disk and in memory.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM (
    SELECT
        i.database_name, i.schema_name, i.table_name, i.index_name, i.key_column_list,
        SUM(c.max_length_bytes) AS key_bytes
    FROM indexes i
    JOIN columns c
          ON  c.database_name = i.database_name
          AND c.schema_name   = i.schema_name
          AND c.table_name    = i.table_name
          -- whole-token match of the column name inside the comma-list:
          -- pad both sides with ', ' so 'Id' never matches inside 'OrderId'.
          AND (', ' || i.key_column_list || ', ') LIKE '%, ' || c.column_name || ', %'
    WHERE i.index_type_desc = 'CLUSTERED'
      AND i.key_column_list IS NOT NULL
    GROUP BY i.database_name, i.schema_name, i.table_name, i.index_name, i.key_column_list
) k
WHERE k.key_bytes >= 100

UNION ALL

-- (4) Large heaps — a heap is the absence of a clustered index. Surfaced
--     here from the clustered-key angle (a01 also reports heaps from the
--     heap angle); kept distinct so a sizing/design review sees both.
SELECT
    'Table design'                                          AS dimension,
    t.database_name,
    t.schema_name || '.' || t.table_name                    AS object_name,
    'Medium'                                                AS severity,
    'rows=' || fmt_n(t.row_count)
        || '; total=' || fmt_n(t.total_space_mb) || ' MB'  AS metric,
    'Large table is a heap (no clustered index).'           AS finding,
    'Evaluate a clustered index on the primary access path; weigh against deliberate heap use (staging, bulk load). [SCHEMA CHANGE]' AS recommendation,
    'A clustered index gives ordered access and avoids RID lookups/forwarded records; most OLTP tables benefit.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM tables t
WHERE t.is_heap = TRUE
  AND t.row_count >= 500000
;
