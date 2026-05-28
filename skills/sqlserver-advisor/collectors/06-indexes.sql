/*******************************************************************************
 * SQL Server Advisor - Collector 06: Indexes (per database)
 *
 * Purpose : Capture one row per index (and heap) on every user table in the
 *           CURRENT database: type, unique/PK/constraint flags, disabled/filtered
 *           state, fill factor, and the ordered key + included column lists.
 *           Feeds Indexing analysis (duplicate/overlapping, wide, low-fill,
 *           disabled, unindexed-heap detection).
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025. Run in EACH user database context (looped).
 *           STRING_AGG is 2017+ (14.x); a FOR XML PATH fallback is used on 2016
 *           so the column lists build correctly on every supported build.
 * Safety  : READ-ONLY. Reads sys.indexes + sys.index_columns + sys.columns.
 *
 * Output columns (EXACT capture contract -> capture/indexes.csv):
 *   server_name, captured_at, database_name, schema_name, table_name, object_id,
 *   index_name, index_id, index_type_desc, is_unique, is_primary_key,
 *   is_unique_constraint, is_disabled, is_filtered, fill_factor,
 *   key_column_list, included_column_list
 *
 * Notes:
 *   - Heaps (index_id 0) are included so the advisor can flag heaps with no
 *     nonclustered support; their key/included lists are empty.
 *   - key_column_list preserves key ordinal order and marks DESC columns; this
 *     is the comparison key for duplicate/left-prefix detection downstream.
 *   - fill_factor 0 means the server default (treated as 100 in analysis).
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))  AS server_name,
    SYSUTCDATETIME()                                     AS captured_at,
    DB_NAME()                                            AS database_name,
    SCHEMA_NAME(t.schema_id)                             AS schema_name,
    t.name                                               AS table_name,
    i.object_id                                          AS object_id,
    i.name                                               AS index_name,   -- NULL for heaps
    i.index_id                                           AS index_id,
    i.type_desc                                          AS index_type_desc,
    i.is_unique                                          AS is_unique,
    i.is_primary_key                                     AS is_primary_key,
    i.is_unique_constraint                               AS is_unique_constraint,
    i.is_disabled                                        AS is_disabled,
    i.has_filter                                         AS is_filtered,
    i.fill_factor                                        AS fill_factor,
    -- Ordered key columns (key_ordinal > 0), DESC annotated. STRING_AGG 2017+;
    -- FOR XML PATH fallback keeps the list correct on SQL Server 2016.
    STUFF((
        SELECT ', ' + c.name
               + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE '' END
        FROM sys.index_columns AS ic
        JOIN sys.columns AS c
            ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = i.object_id
          AND ic.index_id  = i.index_id
          AND ic.key_ordinal > 0
        ORDER BY ic.key_ordinal
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '')
                                                         AS key_column_list,
    -- Included (non-key) columns, name order.
    STUFF((
        SELECT ', ' + c.name
        FROM sys.index_columns AS ic
        JOIN sys.columns AS c
            ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = i.object_id
          AND ic.index_id  = i.index_id
          AND ic.is_included_column = 1
        ORDER BY c.name
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '')
                                                         AS included_column_list
FROM sys.indexes AS i
JOIN sys.tables  AS t ON t.object_id = i.object_id
WHERE t.is_ms_shipped = 0
ORDER BY SCHEMA_NAME(t.schema_id), t.name, i.index_id;
