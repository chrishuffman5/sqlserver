/*******************************************************************************
 * SQL Server Advisor - Collector 16: Identity & Sequence Headroom (per database)
 *
 * Purpose : Capture one row per IDENTITY column and one row per SEQUENCE in the
 *           CURRENT database with the current value, the data type's maximum,
 *           and the percentage of the range consumed. Feeds the exhaustion
 *           analysis (a16-identity-exhaustion) - an int IDENTITY quietly
 *           running out of numbers is a full outage (error 8115 on every
 *           INSERT), and it is entirely predictable from this capture.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (all platforms - catalog views only).
 *           Run in EACH user database context (the capture guide loops it).
 * Safety  : READ-ONLY. Reads sys.identity_columns, sys.tables, sys.sequences.
 *
 * Output columns (EXACT capture contract -> capture/identity_columns.csv):
 *   server_name, captured_at, database_name, object_type, schema_name,
 *   table_name, column_name, data_type, seed_value, increment_value,
 *   last_value, max_value, is_cycling, pct_used
 *
 * Column semantics:
 *   - object_type is 'IDENTITY' or 'SEQUENCE'. For sequences, table_name is the
 *     sequence name and column_name is NULL; is_cycling reflects the CYCLE
 *     option (always 0 for identities).
 *   - last_value is NULL when the identity/sequence has never issued a value.
 *   - pct_used = last_value / max_value * 100 for ASCENDING (increment > 0)
 *     ranges; NULL for descending increments and never-used objects. A negative
 *     seed (e.g. int seeded at -2,147,483,648) doubles the usable range - the
 *     analysis notes reseeding into the negative range as one mitigation.
 *   - max_value: for identities, the type's maximum (decimal/numeric = 10^p - 1
 *     computed exactly via REPLICATE); for sequences, the declared MAXVALUE.
 *     Values are DECIMAL(38,0) so bigint/decimal(38) identities do not overflow.
 ******************************************************************************/
SET NOCOUNT ON;

WITH ident AS
(
    SELECT
        SCHEMA_NAME(t.schema_id)                           AS schema_name,
        t.name                                             AS table_name,
        ic.name                                            AS column_name,
        TYPE_NAME(ic.system_type_id)                       AS data_type,
        CONVERT(decimal(38,0), ic.seed_value)              AS seed_value,
        CONVERT(decimal(38,0), ic.increment_value)         AS increment_value,
        CONVERT(decimal(38,0), ic.last_value)              AS last_value,
        CASE TYPE_NAME(ic.system_type_id)
             WHEN 'tinyint'  THEN CONVERT(decimal(38,0), 255)
             WHEN 'smallint' THEN CONVERT(decimal(38,0), 32767)
             WHEN 'int'      THEN CONVERT(decimal(38,0), 2147483647)
             WHEN 'bigint'   THEN CONVERT(decimal(38,0), 9223372036854775807)
             ELSE CONVERT(decimal(38,0), REPLICATE('9', ic.precision))  -- decimal/numeric(p,0)
        END                                                AS max_value,
        CONVERT(bit, 0)                                    AS is_cycling
    FROM sys.identity_columns AS ic
    JOIN sys.tables           AS t  ON t.object_id = ic.object_id
    WHERE t.is_ms_shipped = 0
),
seqs AS
(
    SELECT
        SCHEMA_NAME(sq.schema_id)                          AS schema_name,
        sq.name                                            AS table_name,   -- sequence name
        CONVERT(sysname, NULL)                             AS column_name,
        TYPE_NAME(sq.system_type_id)                       AS data_type,
        CONVERT(decimal(38,0), sq.start_value)             AS seed_value,
        CONVERT(decimal(38,0), sq.increment)               AS increment_value,
        CONVERT(decimal(38,0), sq.last_used_value)         AS last_value,
        CONVERT(decimal(38,0), sq.maximum_value)           AS max_value,
        sq.is_cycling                                      AS is_cycling
    FROM sys.sequences AS sq
    WHERE sq.is_ms_shipped = 0
)
SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))    AS server_name,
    SYSUTCDATETIME()                                       AS captured_at,
    DB_NAME()                                              AS database_name,
    u.object_type,
    u.schema_name,
    u.table_name,
    u.column_name,
    u.data_type,
    u.seed_value,
    u.increment_value,
    u.last_value,
    u.max_value,
    u.is_cycling,
    CASE WHEN u.increment_value > 0 AND u.last_value IS NOT NULL AND u.max_value > 0
         THEN CAST(CONVERT(float, u.last_value) * 100.0
                   / CONVERT(float, u.max_value) AS DECIMAL(7,2))
         ELSE NULL END                                     AS pct_used
FROM
(
    SELECT 'IDENTITY' AS object_type, * FROM ident
    UNION ALL
    SELECT 'SEQUENCE' AS object_type, * FROM seqs
) AS u
ORDER BY pct_used DESC, u.schema_name, u.table_name;
