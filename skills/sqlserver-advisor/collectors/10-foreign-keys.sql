/*******************************************************************************
 * SQL Server Advisor - Collector 10: Foreign Keys (per database)
 *
 * Purpose : Capture one row per foreign key in the CURRENT database with its
 *           parent/referenced tables and column lists, trust state, disabled
 *           state, and referential actions. Feeds Table-design analysis
 *           (untrusted FKs that defeat the optimizer, disabled FKs that risk
 *           orphans, and FK columns lacking a supporting index).
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025. Run in EACH user database context (looped).
 * Safety  : READ-ONLY. Reads sys.foreign_keys + sys.foreign_key_columns +
 *           sys.tables/columns/schemas only.
 *
 * Output columns (EXACT capture contract -> capture/foreign_keys.csv):
 *   server_name, captured_at, database_name, schema_name, table_name, fk_name,
 *   referenced_schema, referenced_table, is_disabled, is_not_trusted,
 *   delete_referential_action_desc, update_referential_action_desc,
 *   parent_column_list, referenced_column_list
 *
 * Notes:
 *   - is_not_trusted = 1 means the FK was created/re-enabled WITH NOCHECK and
 *     not re-validated; the optimizer cannot rely on it. The advisor flags
 *     these because they both hurt plans and risk data-integrity gaps.
 *   - Column lists preserve the FK key ordinal so composite-key pairings line
 *     up parent-to-referenced.
 *   - STUFF/FOR XML PATH builds the lists portably on every 2016+ build.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))  AS server_name,
    SYSUTCDATETIME()                                     AS captured_at,
    DB_NAME()                                            AS database_name,
    SCHEMA_NAME(pt.schema_id)                            AS schema_name,
    pt.name                                              AS table_name,
    fk.name                                              AS fk_name,
    SCHEMA_NAME(rt.schema_id)                            AS referenced_schema,
    rt.name                                              AS referenced_table,
    fk.is_disabled                                       AS is_disabled,
    fk.is_not_trusted                                    AS is_not_trusted,
    fk.delete_referential_action_desc                    AS delete_referential_action_desc,
    fk.update_referential_action_desc                    AS update_referential_action_desc,
    STUFF((
        SELECT ', ' + pc.name
        FROM sys.foreign_key_columns AS fkc
        JOIN sys.columns AS pc
            ON pc.object_id = fkc.parent_object_id
           AND pc.column_id = fkc.parent_column_id
        WHERE fkc.constraint_object_id = fk.object_id
        ORDER BY fkc.constraint_column_id
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '')
                                                         AS parent_column_list,
    STUFF((
        SELECT ', ' + rc.name
        FROM sys.foreign_key_columns AS fkc
        JOIN sys.columns AS rc
            ON rc.object_id = fkc.referenced_object_id
           AND rc.column_id = fkc.referenced_column_id
        WHERE fkc.constraint_object_id = fk.object_id
        ORDER BY fkc.constraint_column_id
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '')
                                                         AS referenced_column_list
FROM sys.foreign_keys AS fk
JOIN sys.tables AS pt ON pt.object_id = fk.parent_object_id
JOIN sys.tables AS rt ON rt.object_id = fk.referenced_object_id
ORDER BY SCHEMA_NAME(pt.schema_id), pt.name, fk.name;
