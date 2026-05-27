/*******************************************************************************
 * SQL Server - Statistics Health
 *
 * Purpose : Report statistics freshness, sampling rate, modification activity,
 *           and origin (auto vs user) so you can spot stale/under-sampled stats
 *           and columns lacking stats - the root of bad cardinality estimates.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x), Azure SQL DB / Managed Instance.
 * Safety  : READ-ONLY. No UPDATE STATISTICS is run - recommendations are text.
 *
 * Sections:
 *   1. Statistics detail: last_updated, rows vs rows_sampled, mod counter
 *   2. Stale / under-sampled statistics (heuristic flags)
 *   3. Predicate columns with NO statistics (potential blind spots)
 *
 * NOTE: 2016+ (compat 130+) uses a dynamic sublinear auto-update threshold
 *       (~SQRT(1000 * rows)). UPDATE STATISTICS ... WITH FULLSCAN and the
 *       scheduling of stats maintenance belong to sqlserver-operations.
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Statistics Detail (current database)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(s.object_id)                    AS table_name,
    s.name                                      AS stats_name,
    s.auto_created,
    s.user_created,
    s.has_filter,
    s.filter_definition,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    CASE WHEN sp.rows > 0
         THEN CAST(sp.rows_sampled * 100.0 / sp.rows AS decimal(5,2))
         ELSE NULL END                          AS sampled_pct,
    sp.modification_counter,
    sp.steps                                    AS histogram_steps
FROM sys.stats AS s
JOIN sys.objects AS o
    ON o.object_id = s.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE o.is_ms_shipped = 0
  AND o.type = 'U'
ORDER BY sp.modification_counter DESC, sp.last_updated ASC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: STALE / UNDER-SAMPLED Statistics (heuristic)
  Flags: low sampling rate on a large table, OR heavy modifications since
  last update relative to the dynamic threshold ~SQRT(1000 * rows).
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(s.object_id)                    AS table_name,
    s.name                                      AS stats_name,
    sp.rows,
    sp.rows_sampled,
    CASE WHEN sp.rows > 0
         THEN CAST(sp.rows_sampled * 100.0 / sp.rows AS decimal(5,2))
         ELSE NULL END                          AS sampled_pct,
    sp.modification_counter,
    CAST(SQRT(1000.0 * sp.rows) AS bigint)      AS approx_autoupdate_threshold,
    sp.last_updated,
    CASE
        WHEN sp.modification_counter > CAST(SQRT(1000.0 * sp.rows) AS bigint)
            THEN 'STALE: modifications exceed the ~SQRT(1000*rows) threshold - '
               + 'consider UPDATE STATISTICS (see sqlserver-operations).'
        WHEN sp.rows > 1000000
         AND sp.rows_sampled * 100.0 / NULLIF(sp.rows,0) < 20
            THEN 'UNDER-SAMPLED on a large table - consider WITH FULLSCAN '
               + 'if histogram quality matters (skewed data).'
        ELSE 'OK'
    END                                         AS recommendation
FROM sys.stats AS s
JOIN sys.objects AS o
    ON o.object_id = s.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE o.is_ms_shipped = 0
  AND o.type = 'U'
  AND sp.rows > 0
  AND (
        sp.modification_counter > CAST(SQRT(1000.0 * sp.rows) AS bigint)
        OR (sp.rows > 1000000
            AND sp.rows_sampled * 100.0 / NULLIF(sp.rows,0) < 20)
      )
ORDER BY sp.modification_counter DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Columns With NO Statistics (potential estimation blind spots)
  Columns not covered by any index-leading stat or auto-created column stat.
  (Auto-create normally fills these on first predicate use; persistent gaps
   can appear if AUTO_CREATE_STATISTICS is OFF.)
──────────────────────────────────────────────────────────────────────────────*/
-- Surface the database-level auto-stats settings for context
SELECT name AS database_name, is_auto_create_stats_on, is_auto_update_stats_on,
       is_auto_update_stats_async_on
FROM sys.databases
WHERE database_id = DB_ID();

SELECT
    SCHEMA_NAME(o.schema_id)                    AS schema_name,
    OBJECT_NAME(c.object_id)                    AS table_name,
    c.name                                      AS column_name,
    t.name                                      AS data_type,
    'No statistics object references this column as its leading column - '
        + 'if it is used in predicates and auto-create is OFF, estimates may '
        + 'be poor.'                            AS note
FROM sys.columns AS c
JOIN sys.objects AS o
    ON o.object_id = c.object_id
JOIN sys.types   AS t
    ON t.user_type_id = c.user_type_id
WHERE o.is_ms_shipped = 0
  AND o.type = 'U'
  AND NOT EXISTS (
        SELECT 1
        FROM sys.stats_columns AS sc
        WHERE sc.object_id    = c.object_id
          AND sc.column_id    = c.column_id
          AND sc.stats_column_id = 1            -- leading column of some stat
      )
  -- exclude LOB/other types that aren't useful predicate columns
  AND t.name NOT IN (N'text', N'ntext', N'image', N'xml',
                     N'geometry', N'geography', N'hierarchyid')
ORDER BY schema_name, table_name, column_name;
