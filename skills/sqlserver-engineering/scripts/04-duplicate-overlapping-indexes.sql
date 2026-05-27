/*******************************************************************************
 * SQL Server - Duplicate & Overlapping Index Detection
 *
 * Purpose : Detect exact-duplicate indexes and left-prefix overlapping indexes
 *           by comparing ordered key-column lists per table.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x), Azure SQL DB / Managed Instance.
 * Safety  : READ-ONLY. No indexes are dropped or altered - findings only.
 *
 * Sections:
 *   1. Ordered key/include column lists per index (raw inventory)
 *   2. Exact duplicates (identical key column list & order) - DROP one (REVIEW)
 *   3. Left-prefix overlaps (one key list is a leading prefix of another)
 *
 * REVIEW NOTES:
 *   - Keep the more GENERAL index (wider key / better INCLUDE coverage); the
 *     narrower left-prefix is often redundant. Confirm with usage (script 01).
 *   - NEVER drop an index backing a PK / UNIQUE constraint or a FK's support
 *     without checking integrity & cascade/join dependencies.
 *   - INCLUDE lists differ between "duplicates"; verify covering needs first.
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Build an ordered key-column list and include-column list per index.
  STRING_AGG (2017+) used for compact lists; ordered by key_ordinal.
──────────────────────────────────────────────────────────────────────────────*/
;WITH key_cols AS (
    SELECT
        ic.object_id,
        ic.index_id,
        STRING_AGG(
            CONVERT(varchar(max),
                COL_NAME(ic.object_id, ic.column_id)
                + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE '' END),
            ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_list
    FROM sys.index_columns AS ic
    WHERE ic.is_included_column = 0
      AND ic.key_ordinal > 0
    GROUP BY ic.object_id, ic.index_id
),
inc_cols AS (
    SELECT
        ic.object_id,
        ic.index_id,
        STRING_AGG(
            CONVERT(varchar(max), COL_NAME(ic.object_id, ic.column_id)),
            ', ') WITHIN GROUP (ORDER BY COL_NAME(ic.object_id, ic.column_id)) AS include_list
    FROM sys.index_columns AS ic
    WHERE ic.is_included_column = 1
    GROUP BY ic.object_id, ic.index_id
),
idx AS (
    SELECT
        i.object_id,
        i.index_id,
        SCHEMA_NAME(o.schema_id)    AS schema_name,
        OBJECT_NAME(i.object_id)    AS table_name,
        i.name                      AS index_name,
        i.type_desc                 AS index_type,
        i.is_primary_key,
        i.is_unique_constraint,
        i.is_unique,
        k.key_list,
        ISNULL(c.include_list, '')  AS include_list
    FROM sys.indexes AS i
    JOIN sys.objects AS o   ON o.object_id = i.object_id
    JOIN key_cols   AS k    ON k.object_id = i.object_id AND k.index_id = i.index_id
    LEFT JOIN inc_cols AS c ON c.object_id = i.object_id AND c.index_id = i.index_id
    WHERE o.is_ms_shipped = 0
      AND i.type IN (1, 2)          -- clustered / nonclustered rowstore
)
/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Raw inventory (review the key/include lists)
──────────────────────────────────────────────────────────────────────────────*/
SELECT schema_name, table_name, index_name, index_type,
       is_primary_key, is_unique, is_unique_constraint,
       key_list, include_list
INTO #idx
FROM idx;

SELECT * FROM #idx ORDER BY schema_name, table_name, key_list;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: EXACT DUPLICATES (same table, identical key column list & order)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    a.schema_name,
    a.table_name,
    a.key_list                                  AS shared_key_list,
    a.index_name                                AS index_a,
    a.include_list                              AS include_a,
    b.index_name                                AS index_b,
    b.include_list                              AS include_b,
    'EXACT DUPLICATE keys - keep the better-covering one, DROP the other '
        + '(verify usage via script 01; never drop a PK/UNIQUE/FK support).'
                                                AS recommendation
FROM #idx AS a
JOIN #idx AS b
    ON  a.object_id = b.object_id
    AND a.key_list  = b.key_list
    AND a.index_id  < b.index_id                -- each pair once
ORDER BY a.schema_name, a.table_name, a.key_list;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: LEFT-PREFIX OVERLAPS (one key list is a leading prefix of another)
  e.g. key (A) is redundant with key (A, B) for most seek purposes.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    a.schema_name,
    a.table_name,
    a.index_name                                AS narrower_index,
    a.key_list                                  AS narrower_key_list,
    b.index_name                                AS wider_index,
    b.key_list                                  AS wider_key_list,
    'LEFT-PREFIX overlap - narrower index may be redundant with the wider '
        + 'one. REVIEW usage & covering needs before dropping.'
                                                AS recommendation
FROM #idx AS a
JOIN #idx AS b
    ON  a.object_id = b.object_id
    AND a.index_id <> b.index_id
    AND a.key_list <> b.key_list
    AND b.key_list LIKE a.key_list + ', %'      -- a's keys are a leading prefix of b's
ORDER BY a.schema_name, a.table_name, a.key_list;

DROP TABLE #idx;
