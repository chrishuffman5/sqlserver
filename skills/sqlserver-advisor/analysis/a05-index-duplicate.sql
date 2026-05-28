-- =====================================================================
-- a05-index-duplicate.sql  —  dimension: Indexing
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS: (1) EXACT-DUPLICATE indexes (same table, identical key list AND
--            identical included-column list); (2) OVERLAPPING indexes where
--            one index's key list is a leading PREFIX of another's.
-- Both are consolidation opportunities. Depth: sqlserver-engineering.
-- =====================================================================

-- (1) Exact duplicates — identical key_column_list AND included_column_list.
--     a.index_name < b.index_name makes each pair appear once. Treat NULL
--     include lists as equal via COALESCE to ''.
SELECT
    'Indexing'                                              AS dimension,
    a.database_name,
    a.schema_name || '.' || a.table_name || '.' || a.index_name  AS object_name,
    'High'                                                  AS severity,
    'duplicate_of=' || b.index_name
        || '; keys=(' || a.key_column_list || ')'
        || '; include=(' || COALESCE(a.included_column_list, '') || ')'  AS metric,
    'Exact-duplicate index (same keys and same included columns).' AS finding,
    'Keep one (prefer the unique/PK or the one with the better name) and DROP the redundant copy. [SCHEMA CHANGE]' AS recommendation,
    'Identical indexes double the write and storage cost while adding zero read capability the other does not already provide.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM indexes a
JOIN indexes b
      ON  a.database_name = b.database_name
      AND a.schema_name   = b.schema_name
      AND a.table_name    = b.table_name
      AND a.object_id     = b.object_id
      AND a.index_name    < b.index_name
      AND a.key_column_list                  = b.key_column_list
      AND COALESCE(a.included_column_list,'') = COALESCE(b.included_column_list,'')
WHERE a.index_type_desc IN ('NONCLUSTERED', 'CLUSTERED')
  AND a.key_column_list IS NOT NULL

UNION ALL

-- (2) Overlapping indexes — one key list is a strict leading prefix of the
--     other (e.g. (A) is a prefix of (A, B); (A, B) of (A, B, C)). The
--     narrower index is usually redundant: the wider one can serve its
--     seeks. We pad with ', ' so 'Col' is not matched inside 'Column'.
SELECT
    'Indexing'                                              AS dimension,
    narrow.database_name,
    narrow.schema_name || '.' || narrow.table_name || '.' || narrow.index_name  AS object_name,
    'Medium'                                                AS severity,
    'keys=(' || narrow.key_column_list || ')'
        || ' is a leading prefix of ' || wide.index_name
        || ' keys=(' || wide.key_column_list || ')'         AS metric,
    'Overlapping index: its key list is a leading prefix of a wider index.' AS finding,
    'Consider dropping the narrower index if the wider one covers its workload (check seek patterns / included columns first). [SCHEMA CHANGE]' AS recommendation,
    'A wider index whose leading keys match the narrower one can usually satisfy the same seeks, making the narrow index redundant.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM indexes narrow
JOIN indexes wide
      ON  narrow.database_name = wide.database_name
      AND narrow.schema_name   = wide.schema_name
      AND narrow.table_name    = wide.table_name
      AND narrow.object_id     = wide.object_id
      AND narrow.index_id     <> wide.index_id
      AND length(narrow.key_column_list) < length(wide.key_column_list)
      -- strict leading-prefix test (token-safe): wide starts with narrow + ', '
      AND (wide.key_column_list || ', ') LIKE (narrow.key_column_list || ', %')
WHERE narrow.index_type_desc = 'NONCLUSTERED'
  AND wide.index_type_desc   = 'NONCLUSTERED'
  AND narrow.key_column_list IS NOT NULL
  AND wide.key_column_list   IS NOT NULL
  -- don't double-report the exact-duplicate pairs handled above
  AND narrow.key_column_list <> wide.key_column_list
;
