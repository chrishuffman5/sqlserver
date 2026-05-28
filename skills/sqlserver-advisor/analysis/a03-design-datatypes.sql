-- =====================================================================
-- a03-design-datatypes.sql  —  dimension: Table design
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS: (1) (N)VARCHAR(MAX)/VARBINARY(MAX) columns to review;
--        (2) deprecated text/ntext/image types;
--        (3) FK columns whose type/length differ parent vs referenced
--            (implicit-conversion / non-SARGable-join risk);
--        (4) tables whose summed max column width > 8060 bytes (row-overflow);
--        (5) tables with a very high nullable-column ratio.
-- Depth on data types, SARGability, computed columns: sqlserver-engineering.
-- =====================================================================

-- (1) LOB MAX columns — fine when truly needed, but often misused for short
--     strings; they force off-row storage paths and block online operations.
SELECT
    'Table design'                                          AS dimension,
    c.database_name,
    c.schema_name || '.' || c.table_name || '.' || c.column_name  AS object_name,
    'Low'                                                   AS severity,
    'type=' || c.data_type
        || '; max_length_bytes=' || c.max_length_bytes      AS metric,
    'LOB MAX column — verify it actually needs unbounded length.'  AS finding,
    'If real values are short/bounded, switch to a sized (N)VARCHAR(n)/VARBINARY(n); reserve MAX for genuine large objects.' AS recommendation,
    'MAX columns can store off-row, hurt scans, inflate memory grants, and block ONLINE index operations.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM columns c
WHERE regexp_matches(c.data_type, '(?i)varchar|nvarchar|varbinary')
  AND c.max_length_bytes = -1                 -- SQL Server stores MAX as length -1

UNION ALL

-- (2) Deprecated LOB types — text/ntext/image are removed-feature types.
SELECT
    'Table design'                                          AS dimension,
    c.database_name,
    c.schema_name || '.' || c.table_name || '.' || c.column_name  AS object_name,
    'Medium'                                                AS severity,
    'type=' || c.data_type                                  AS metric,
    'Deprecated legacy LOB type (text/ntext/image).'        AS finding,
    'Migrate to VARCHAR(MAX)/NVARCHAR(MAX)/VARBINARY(MAX); the legacy types are deprecated and lack modern string functions. [SCHEMA CHANGE]' AS recommendation,
    'text/ntext/image are slated for removal, behave poorly with many T-SQL functions, and complicate replication/AG.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM columns c
WHERE lower(c.data_type) IN ('text', 'ntext', 'image')

UNION ALL

-- (3) FK type mismatch — join FK parent/referenced column lists back to
--     columns. We compare the FIRST column of each side (covers the common
--     single-column FK; multi-column FKs surface on their leading column).
SELECT
    'Table design'                                          AS dimension,
    fk.database_name,
    fk.schema_name || '.' || fk.table_name || '.' || fk.fk_name  AS object_name,
    'High'                                                  AS severity,
    'parent=' || pc.column_name || ' ' || pc.data_type || '(' || pc.max_length_bytes || ')'
        || '  vs  referenced=' || rc.column_name || ' ' || rc.data_type || '(' || rc.max_length_bytes || ')'  AS metric,
    'Foreign-key column type/length differs from the referenced column.' AS finding,
    'Align the FK column''s data type and length with the referenced key; rebuild the FK after the column change. [SCHEMA CHANGE]' AS recommendation,
    'Mismatched join types inject CONVERT_IMPLICIT, make the FK join non-SARGable, and can defeat index seeks on lookups.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM foreign_keys fk
JOIN columns pc
      ON  pc.database_name = fk.database_name
      AND pc.schema_name   = fk.schema_name
      AND pc.table_name    = fk.table_name
      AND pc.column_name   = trim(split_part(fk.parent_column_list, ',', 1))
JOIN columns rc
      ON  rc.database_name = fk.database_name
      AND rc.schema_name   = fk.referenced_schema
      AND rc.table_name    = fk.referenced_table
      AND rc.column_name   = trim(split_part(fk.referenced_column_list, ',', 1))
WHERE lower(pc.data_type) <> lower(rc.data_type)
   OR pc.max_length_bytes <> rc.max_length_bytes

UNION ALL

-- (4) Potential row-overflow — sum of declared max byte widths > 8060.
--     Exclude MAX (-1) columns from the sum (they store off-row anyway);
--     a large in-row total means variable-length columns may push off-row.
SELECT
    'Table design'                                          AS dimension,
    w.database_name,
    w.schema_name || '.' || w.table_name                    AS object_name,
    'Medium'                                                AS severity,
    'summed_max_width_bytes=' || fmt_n(w.row_bytes)
        || '; columns=' || w.col_count                      AS metric,
    'Declared column widths sum beyond the 8060-byte in-row limit.' AS finding,
    'Review for over-wide (N)VARCHAR declarations; right-size column lengths; consider vertical split for rarely-used wide columns. [SCHEMA CHANGE]' AS recommendation,
    'When in-row data exceeds 8060 bytes, variable-length columns push off-row, adding pointer indirection and extra reads.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM (
    SELECT database_name, schema_name, table_name,
           SUM(CASE WHEN max_length_bytes > 0 THEN max_length_bytes ELSE 0 END) AS row_bytes,
           COUNT(*) AS col_count
    FROM columns
    GROUP BY database_name, schema_name, table_name
) w
WHERE w.row_bytes > 8060

UNION ALL

-- (5) High nullable-column ratio — often signals a wide "everything"
--     table or under-normalized design (sparse, optional attributes).
SELECT
    'Table design'                                          AS dimension,
    n.database_name,
    n.schema_name || '.' || n.table_name                    AS object_name,
    'Low'                                                   AS severity,
    'nullable=' || n.nullable_cols || '/' || n.col_count
        || ' (' || fmt_n(n.nullable_ratio * 100) || '%)'  AS metric,
    'Very high ratio of nullable columns.'                  AS finding,
    'Review whether optional attributes belong in a separate/related table; consider SPARSE columns for genuinely sparse data. [SCHEMA CHANGE]' AS recommendation,
    'A table that is mostly nullable columns often hides multiple entities or optional sub-types that normalize better apart.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM (
    SELECT database_name, schema_name, table_name,
           COUNT(*)                                        AS col_count,
           SUM(CASE WHEN is_nullable THEN 1 ELSE 0 END)    AS nullable_cols,
           SUM(CASE WHEN is_nullable THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS nullable_ratio
    FROM columns
    GROUP BY database_name, schema_name, table_name
) n
WHERE n.col_count >= 10
  AND n.nullable_ratio >= 0.8
;
