/*******************************************************************************
 * SQL Server Advisor - Collector 04: Tables (per database)
 *
 * Purpose : Capture one row per user table in the CURRENT database with row
 *           count, space breakdown (total / used / data / index / unused MB),
 *           heap vs. clustered status, PK presence, clustered-columnstore flag,
 *           partition count, and the dominant data-compression setting. Feeds
 *           the Table-design and Sizing-&-capacity analyses.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025. Run in EACH user database context (the
 *           capture guide loops it). Uses DB_NAME() + current-DB catalog views.
 * Safety  : READ-ONLY. Reads catalog views + sys.dm_db_partition_stats only.
 *
 * Space math mirrors the standard sp_spaceused allocation model:
 *   reserved = reserved_page_count, used = used_page_count,
 *   data     = in_row_data + lob_used + row_overflow_used pages,
 *   index    = used - data, unused = reserved - used. (8 KB pages -> MB.)
 *
 * Output columns (EXACT capture contract -> capture/tables.csv):
 *   server_name, captured_at, database_name, schema_name, table_name, object_id,
 *   is_heap, has_primary_key, has_clustered_columnstore, row_count,
 *   total_space_mb, used_space_mb, data_space_mb, index_space_mb,
 *   unused_space_mb, partition_count, data_compression_desc
 *
 * Version / platform guards:
 *   - has_clustered_columnstore checks sys.indexes.type = 5 (CLUSTERED
 *     COLUMNSTORE, 2014+). The type-code test is safe on every 2016+ build with
 *     no need for a TRY block; it simply yields 0 where the feature is unused.
 *   - data_compression_desc reads sys.partitions.data_compression_desc (2008+).
 *     Values: NONE / ROW / PAGE / COLUMNSTORE / COLUMNSTORE_ARCHIVE. We report
 *     the MAX across partitions (so a partly-compressed table shows the highest
 *     level present) - a per-partition breakdown is out of contract scope.
 *   - row_count uses index_id IN (0,1) partitions (heap or clustered) to avoid
 *     double counting nonclustered indexes.
 ******************************************************************************/
SET NOCOUNT ON;

WITH ps AS
(
    -- Allocation rollup per table from sys.dm_db_partition_stats (all indexes).
    SELECT
        p.object_id,
        SUM(p.reserved_page_count)                                       AS reserved_pages,
        SUM(p.used_page_count)                                           AS used_pages,
        SUM(p.in_row_data_page_count
            + p.lob_used_page_count
            + p.row_overflow_used_page_count)                            AS data_pages
    FROM sys.dm_db_partition_stats AS p
    GROUP BY p.object_id
),
rc AS
(
    -- Row count from the base rowset only (heap index_id 0 or clustered 1).
    SELECT
        p.object_id,
        SUM(p.row_count) AS row_count
    FROM sys.dm_db_partition_stats AS p
    WHERE p.index_id IN (0, 1)
    GROUP BY p.object_id
),
pc AS
(
    -- Partition count = max partitions across the table's heap/clustered rowset.
    SELECT
        pt.object_id,
        MAX(pt.partition_number) AS partition_count
    FROM sys.partitions AS pt
    WHERE pt.index_id IN (0, 1)
    GROUP BY pt.object_id
),
comp AS
(
    -- Highest compression level present across all partitions/indexes.
    SELECT
        pt.object_id,
        MAX(pt.data_compression_desc) AS data_compression_desc
    FROM sys.partitions AS pt
    GROUP BY pt.object_id
)
SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))             AS server_name,
    SYSUTCDATETIME()                                                AS captured_at,
    DB_NAME()                                                       AS database_name,
    SCHEMA_NAME(t.schema_id)                                        AS schema_name,
    t.name                                                          AS table_name,
    t.object_id                                                     AS object_id,
    CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i
                      WHERE i.object_id = t.object_id AND i.index_id = 0)
         THEN 1 ELSE 0 END                                          AS is_heap,
    CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i
                      WHERE i.object_id = t.object_id AND i.is_primary_key = 1)
         THEN 1 ELSE 0 END                                          AS has_primary_key,
    CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i
                      WHERE i.object_id = t.object_id AND i.type = 5)
         THEN 1 ELSE 0 END                                          AS has_clustered_columnstore,
    ISNULL(rc.row_count, 0)                                         AS row_count,
    CAST(ISNULL(ps.reserved_pages, 0) * 8.0 / 1024 AS DECIMAL(18,2)) AS total_space_mb,
    CAST(ISNULL(ps.used_pages, 0)     * 8.0 / 1024 AS DECIMAL(18,2)) AS used_space_mb,
    CAST(ISNULL(ps.data_pages, 0)     * 8.0 / 1024 AS DECIMAL(18,2)) AS data_space_mb,
    CAST((ISNULL(ps.used_pages, 0) - ISNULL(ps.data_pages, 0))
         * 8.0 / 1024 AS DECIMAL(18,2))                             AS index_space_mb,
    CAST((ISNULL(ps.reserved_pages, 0) - ISNULL(ps.used_pages, 0))
         * 8.0 / 1024 AS DECIMAL(18,2))                             AS unused_space_mb,
    ISNULL(pc.partition_count, 1)                                  AS partition_count,
    ISNULL(comp.data_compression_desc, 'NONE')                     AS data_compression_desc
FROM sys.tables AS t
LEFT JOIN ps   ON ps.object_id   = t.object_id
LEFT JOIN rc   ON rc.object_id   = t.object_id
LEFT JOIN pc   ON pc.object_id   = t.object_id
LEFT JOIN comp ON comp.object_id = t.object_id
WHERE t.is_ms_shipped = 0
ORDER BY total_space_mb DESC;
