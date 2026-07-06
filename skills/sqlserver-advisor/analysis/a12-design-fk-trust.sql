-- =====================================================================
-- a12-design-fk-trust.sql  —  dimension: Table design (referential integrity)
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS foreign-key integrity smells from the foreign_keys capture:
--   (1) untrusted (WITH NOCHECK) but enabled FKs — the optimizer cannot use
--       them for join elimination and violations may already be hiding;
--   (2) disabled FKs — enforcing nothing, orphan rows can accumulate;
--   (3) cascading actions on large child tables — big lock-heavy blast radius;
--   (4) FK columns with no supporting index — scans on joins and slow,
--       lock-escalating cascading deletes from the parent.
-- Depth: sqlserver-engineering (schema-design.md — constraints; indexing.md).
-- NOTE: re-validating an untrusted FK (WITH CHECK CHECK CONSTRAINT) scans the
--   child table — a size-of-data operation; NOCHECK may be intentional during
--   bulk loads/migrations. Confirm it is not transient before flagging loudly.
-- =====================================================================

-- (1) Untrusted (but enabled) foreign key
SELECT
    'Table design'                                          AS dimension,
    fk.database_name                                        AS database_name,
    fk.schema_name || '.' || fk.table_name || '.' || fk.fk_name  AS object_name,
    CASE WHEN COALESCE(t.row_count, 0) >= 1000000 THEN 'High' ELSE 'Medium' END  AS severity,
    'is_not_trusted=true; child_rows=' || fmt_n(COALESCE(t.row_count, 0))
        || '; references ' || fk.referenced_schema || '.' || fk.referenced_table  AS metric,
    'Foreign key is enabled but NOT TRUSTED (created/re-enabled WITH NOCHECK).' AS finding,
    'Re-validate it: ALTER TABLE ... WITH CHECK CHECK CONSTRAINT — after checking for existing violations; this scans the child table, so schedule it. [SCHEMA CHANGE]' AS recommendation,
    'An untrusted FK cannot be used by the optimizer for join elimination or cardinality, and rows violating it may already exist unnoticed.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM foreign_keys fk
LEFT JOIN tables t ON t.database_name = fk.database_name AND t.schema_name = fk.schema_name
    AND t.table_name = fk.table_name
WHERE fk.is_not_trusted = TRUE AND fk.is_disabled = FALSE

UNION ALL
-- (2) Disabled foreign key
SELECT
    'Table design', fk.database_name,
    fk.schema_name || '.' || fk.table_name || '.' || fk.fk_name,
    CASE WHEN COALESCE(t.row_count, 0) >= 1000000 THEN 'High' ELSE 'Medium' END,
    'is_disabled=true; child_rows=' || fmt_n(COALESCE(t.row_count, 0))
        || '; references ' || fk.referenced_schema || '.' || fk.referenced_table,
    'Foreign key is DISABLED — it enforces nothing.',
    'Decide deliberately: re-enable WITH CHECK (validates existing rows, size-of-data scan) or drop it and document why integrity is enforced elsewhere. [SCHEMA CHANGE]',
    'A disabled FK is silently allowing orphan rows; every day it stays off, cleanup gets harder and the constraint gets less re-enableable.',
    'sqlserver-engineering'
FROM foreign_keys fk
LEFT JOIN tables t ON t.database_name = fk.database_name AND t.schema_name = fk.schema_name
    AND t.table_name = fk.table_name
WHERE fk.is_disabled = TRUE

UNION ALL
-- (3) Cascading referential action on a large child table
SELECT
    'Table design', fk.database_name,
    fk.schema_name || '.' || fk.table_name || '.' || fk.fk_name,
    'Low',
    'on_delete=' || fk.delete_referential_action_desc
        || '; on_update=' || fk.update_referential_action_desc
        || '; child_rows=' || fmt_n(COALESCE(t.row_count, 0)),
    'Cascading referential action on a large child table.',
    'Review the blast radius: a single parent DELETE/UPDATE fans out into the child under one transaction. Consider application-managed or batched cleanup for very large children. [INVESTIGATE]',
    'Cascades on big tables produce large, lock-heavy, log-heavy modifications that can escalate locks and block the system from one innocent-looking parent statement.',
    'sqlserver-engineering'
FROM foreign_keys fk
JOIN tables t ON t.database_name = fk.database_name AND t.schema_name = fk.schema_name
    AND t.table_name = fk.table_name
WHERE (fk.delete_referential_action_desc <> 'NO_ACTION' OR fk.update_referential_action_desc <> 'NO_ACTION')
  AND t.row_count >= 1000000

UNION ALL
-- (4) FK column with no supporting index (leading key match on the child)
SELECT
    'Table design', fk.database_name,
    fk.schema_name || '.' || fk.table_name || '.' || fk.fk_name,
    CASE WHEN COALESCE(t.row_count, 0) >= 100000 THEN 'Medium' ELSE 'Low' END,
    'fk_columns=(' || fk.parent_column_list || '); child_rows=' || fmt_n(COALESCE(t.row_count, 0))
        || '; no index leads on ' || trim(split_part(fk.parent_column_list, ',', 1)),
    'Foreign-key column has no supporting index on the child table.',
    'If the FK column is joined/filtered, or the parent sees DELETEs/UPDATEs, add a nonclustered index leading on the FK column(s) — do not add it reflexively otherwise. [SCHEMA CHANGE]',
    'Unindexed FKs force child-table scans on parent deletes (and on FK joins), causing slow, lock-escalating referential checks.',
    'sqlserver-engineering'
FROM foreign_keys fk
LEFT JOIN tables t ON t.database_name = fk.database_name AND t.schema_name = fk.schema_name
    AND t.table_name = fk.table_name
WHERE fk.is_disabled = FALSE
  AND NOT EXISTS (
      SELECT 1 FROM indexes i
      WHERE i.database_name = fk.database_name AND i.schema_name = fk.schema_name
        AND i.table_name = fk.table_name AND i.key_column_list IS NOT NULL
        AND trim(split_part(i.key_column_list, ',', 1)) = trim(split_part(fk.parent_column_list, ',', 1))
  );
