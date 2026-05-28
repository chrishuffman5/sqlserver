/*******************************************************************************
 * SQL Server Advisor - Collector 09: Index Physical Stats (per database)
 *
 * Purpose : Capture fragmentation, page density, and forwarded-record evidence
 *           per index partition in the CURRENT database, restricted to indexes
 *           large enough to matter (page_count >= 1000 ~= 8 MB). Feeds the
 *           Indexing analysis (rebuild/reorg candidates, low page density,
 *           heap forwarded-record bloat).
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025. Run in EACH user database context (looped).
 *
 * !! HEAVIER COLLECTOR - READ BEFORE RUNNING !!
 *   sys.dm_db_index_physical_stats in 'SAMPLED' mode reads ~1% of pages (and
 *   ALWAYS reads every page for tables < ~10000 pages). It still drives real
 *   I/O against the source. RUN OFF-PEAK. If even SAMPLED is too heavy on a
 *   very large or busy system, switch the final argument to 'LIMITED' (reads
 *   only the upper b-tree level / PFS pages - cheapest, but no
 *   avg_page_space_used_in_percent and no forwarded_record_count). The
 *   page_count >= 1000 filter keeps the row set focused on indexes worth acting
 *   on. This is the one collector you may choose to skip on a sensitive box.
 *
 * Safety  : READ-ONLY. The DMF only reads allocation/physical metadata; it
 *           performs NO writes and holds no long-term locks in SAMPLED/LIMITED.
 *
 * Output columns (EXACT capture contract -> capture/index_physical.csv):
 *   server_name, captured_at, database_name, schema_name, table_name,
 *   index_name, index_id, partition_number, index_type_desc,
 *   avg_fragmentation_in_percent, page_count, avg_page_space_used_in_percent,
 *   fragment_count, forwarded_record_count
 *
 * Platform caveat:
 *   - DB_ID() scopes the scan to the current database. Available on box / MI /
 *     RDS / Cloud SQL. On Azure SQL Database it is supported for the connected
 *     database. forwarded_record_count is populated for HEAPS only (NULL for
 *     b-tree indexes) and is NULL under 'LIMITED' mode.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))  AS server_name,
    SYSUTCDATETIME()                                     AS captured_at,
    DB_NAME()                                            AS database_name,
    SCHEMA_NAME(t.schema_id)                             AS schema_name,
    t.name                                               AS table_name,
    i.name                                               AS index_name,   -- NULL for heaps
    ips.index_id                                         AS index_id,
    ips.partition_number                                 AS partition_number,
    ips.index_type_desc                                  AS index_type_desc,
    CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS avg_fragmentation_in_percent,
    ips.page_count                                       AS page_count,
    CAST(ips.avg_page_space_used_in_percent AS DECIMAL(5,2)) AS avg_page_space_used_in_percent,
    ips.fragment_count                                   AS fragment_count,
    ips.forwarded_record_count                           AS forwarded_record_count
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') AS ips
JOIN sys.tables  AS t ON t.object_id = ips.object_id
JOIN sys.indexes AS i
    ON  i.object_id = ips.object_id
    AND i.index_id  = ips.index_id
WHERE t.is_ms_shipped = 0
  AND ips.page_count >= 1000          -- focus on indexes large enough to matter (~8 MB+)
ORDER BY ips.avg_fragmentation_in_percent DESC, ips.page_count DESC;
