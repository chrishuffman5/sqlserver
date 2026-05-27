/*******************************************************************************
 * SQL Server Operations - Index Fragmentation (Assessment Only)
 *
 * Purpose : Report index fragmentation for the CURRENT database, filtered by
 *           page count, with a recommended action (none / reorganize / rebuild)
 *           per the standard 10% / 30% thresholds. ASSESSMENT ONLY - it does
 *           not change any index.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box / Azure VM / MI / Azure SQL DB / RDS).
 *           Runs in the context of the current database.
 * Safety  : READ-ONLY. Uses sys.dm_db_index_physical_stats in LIMITED mode
 *           (cheapest scan). No ALTER INDEX is executed.
 *
 * Sections:
 *   1. Fragmentation By Index (with recommended action)
 *   2. Summary Counts By Recommended Action
 *
 * Notes  : Run this in EACH user database you care about (it scopes to DB_ID()).
 *          LIMITED mode reads only the level above the leaf - low overhead.
 *          Adjust @MinPageCount to taste (1000 pages ~ 8 MB; 8000 ~ 64 MB).
 ******************************************************************************/
SET NOCOUNT ON;

DECLARE @MinPageCount INT = 1000;     -- ignore indexes smaller than this (noise)
DECLARE @ReorgPct     FLOAT = 10.0;   -- 10-30% -> reorganize
DECLARE @RebuildPct   FLOAT = 30.0;   -- >30%   -> rebuild

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Fragmentation By Index (with recommended action)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME()                                           AS database_name,
    OBJECT_SCHEMA_NAME(ips.object_id)                   AS schema_name,
    OBJECT_NAME(ips.object_id)                          AS table_name,
    i.name                                              AS index_name,
    i.type_desc                                         AS index_type,
    ips.partition_number,
    CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS avg_frag_pct,
    CAST(ips.avg_page_space_used_in_percent AS DECIMAL(5,2)) AS page_density_pct,
    ips.page_count,
    CAST(ips.page_count * 8.0 / 1024 AS DECIMAL(18,2))  AS size_mb,
    ips.fragment_count,
    CASE
        WHEN ips.page_count < @MinPageCount THEN 'none (below page-count threshold)'
        WHEN ips.avg_fragmentation_in_percent < @ReorgPct THEN 'none'
        WHEN ips.avg_fragmentation_in_percent < @RebuildPct THEN 'reorganize'
        ELSE 'rebuild'
    END                                                 AS recommended_action
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
JOIN sys.indexes AS i
    ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.index_id > 0                  -- skip heaps (index_id = 0)
  AND i.is_disabled = 0
  AND OBJECTPROPERTY(ips.object_id, 'IsUserTable') = 1
ORDER BY ips.avg_fragmentation_in_percent DESC, ips.page_count DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Summary Counts By Recommended Action
──────────────────────────────────────────────────────────────────────────────*/
;WITH frag AS (
    SELECT
        ips.page_count,
        ips.avg_fragmentation_in_percent AS pct
    FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
    JOIN sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
    WHERE ips.index_id > 0 AND i.is_disabled = 0
      AND OBJECTPROPERTY(ips.object_id, 'IsUserTable') = 1
)
SELECT
    SUM(CASE WHEN page_count < @MinPageCount OR pct < @ReorgPct THEN 1 ELSE 0 END) AS action_none,
    SUM(CASE WHEN page_count >= @MinPageCount AND pct >= @ReorgPct AND pct < @RebuildPct THEN 1 ELSE 0 END) AS action_reorganize,
    SUM(CASE WHEN page_count >= @MinPageCount AND pct >= @RebuildPct THEN 1 ELSE 0 END) AS action_rebuild
FROM frag;

/*──────────────────────────────────────────────────────────────────────────────
  REMEDIATION TEMPLATES (commented out — assessment script does NOT execute):

  -- Reorganize (online, minimally logged, interruptible):
  -- ALTER INDEX [<index>] ON [<schema>].[<table>] REORGANIZE;

  -- Rebuild (offline). On Enterprise / 2019+/2022+ add ONLINE = ON.
  -- Add RESUMABLE = ON (2017+) for large indexes in short windows:
  -- ALTER INDEX [<index>] ON [<schema>].[<table>]
  --   REBUILD WITH (ONLINE = ON, RESUMABLE = ON, FILLFACTOR = 90, MAX_DURATION = 60 MINUTES);

  -- Or use Ola Hallengren IndexOptimize for fragmentation-aware maintenance.
──────────────────────────────────────────────────────────────────────────────*/
