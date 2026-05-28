/*******************************************************************************
 * SQL Server Advisor - Collector 05: Columns (per database)
 *
 * Purpose : Capture one row per column on every user table in the CURRENT
 *           database: declared type, length/precision/scale, nullability, and
 *           computed/identity flags. Feeds Table-design analysis (oversized
 *           types, MAX-everywhere, nullable-key smells, GUID clustered keys).
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025. Run in EACH user database context (looped by
 *           the capture guide). Uses DB_NAME() + current-DB catalog views.
 * Safety  : READ-ONLY. Reads sys.columns + sys.types only.
 *
 * Output columns (EXACT capture contract -> capture/columns.csv):
 *   server_name, captured_at, database_name, schema_name, table_name,
 *   column_name, column_id, data_type, max_length_bytes, precision, scale,
 *   is_nullable, is_computed, is_identity, collation_name
 *
 * Notes:
 *   - max_length_bytes is sys.columns.max_length verbatim (BYTES; for nvarchar
 *     this is 2x the character count, and -1 denotes a MAX/LOB type). DuckDB-side
 *     analysis interprets -1 as MAX.
 *   - data_type resolves the user-or-system type name via sys.types matched on
 *     user_type_id so aliased/CLR types report their own name.
 *   - is_identity comes from sys.columns (present on the column row itself in
 *     2012+); no join to sys.identity_columns required.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))  AS server_name,
    SYSUTCDATETIME()                                     AS captured_at,
    DB_NAME()                                            AS database_name,
    SCHEMA_NAME(t.schema_id)                             AS schema_name,
    t.name                                               AS table_name,
    c.name                                               AS column_name,
    c.column_id                                          AS column_id,
    ty.name                                              AS data_type,
    c.max_length                                         AS max_length_bytes,
    c.precision                                          AS precision,
    c.scale                                              AS scale,
    c.is_nullable                                        AS is_nullable,
    c.is_computed                                        AS is_computed,
    c.is_identity                                        AS is_identity,
    c.collation_name                                     AS collation_name
FROM sys.columns AS c
JOIN sys.tables  AS t  ON t.object_id   = c.object_id
JOIN sys.types   AS ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
ORDER BY SCHEMA_NAME(t.schema_id), t.name, c.column_id;
