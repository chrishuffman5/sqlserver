/*******************************************************************************
 * SQL Server Monitoring - Memory Pressure Analysis
 *
 * Purpose : Assess buffer-pool / memory health: page life expectancy per NUMA
 *           node, buffer cache hit ratio, top memory clerks, and memory-grant
 *           pressure. Use when waits show RESOURCE_SEMAPHORE / PAGEIOLATCH or
 *           PLE has dropped below baseline.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box) and Managed Instance. Some clerk/NUMA
 *           detail is limited on Azure SQL Database (see sqlserver-cloud).
 * Safety  : Read-only. No modifications.
 *
 * Sections:
 *   1. Process & OS Memory State
 *   2. Page Life Expectancy per NUMA Node
 *   3. Buffer Cache Hit Ratio (ratio/base counter pattern)
 *   4. Top Memory Clerks
 *   5. Buffer Pool Occupancy by Database
 *   6. Memory Grants - Pending & Outstanding (live)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Process & OS Memory State
  process_physical_memory_low = 1 indicates EXTERNAL (OS) memory pressure.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    physical_memory_in_use_kb / 1024                    AS sql_working_set_mb,
    locked_page_allocations_kb / 1024                   AS locked_pages_mb,
    large_page_allocations_kb / 1024                    AS large_pages_mb,
    memory_utilization_percentage,
    process_physical_memory_low                         AS external_memory_pressure,
    process_virtual_memory_low                          AS virtual_memory_pressure
FROM sys.dm_os_process_memory;

SELECT
    total_physical_memory_kb / 1024                     AS os_total_physical_mb,
    available_physical_memory_kb / 1024                 AS os_available_physical_mb,
    system_memory_state_desc                            AS os_memory_state
FROM sys.dm_os_sys_memory;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Page Life Expectancy per NUMA Node
  PLE is meaningful only against YOUR baseline. On multi-NUMA systems read it
  PER NODE (the instance-wide "Page life expectancy" can mask a starved node).
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    RTRIM(instance_name)                                AS numa_node,        -- e.g. '000', '001'
    cntr_value                                          AS page_life_expectancy_sec
FROM sys.dm_os_performance_counters
WHERE counter_name = N'Page life expectancy'
  AND object_name LIKE N'%Buffer Node%'
ORDER BY instance_name;

-- Instance-wide PLE (Buffer Manager) for comparison
SELECT
    cntr_value                                          AS instance_wide_ple_sec
FROM sys.dm_os_performance_counters
WHERE counter_name = N'Page life expectancy'
  AND object_name LIKE N'%Buffer Manager%';

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Buffer Cache Hit Ratio (ratio/base counter pattern)
  Raw cntr_value is meaningless alone - must divide by its matching BASE counter.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    CAST(100.0 * ratio.cntr_value / NULLIF(base.cntr_value, 0) AS DECIMAL(5,2))
        AS buffer_cache_hit_ratio_pct
FROM sys.dm_os_performance_counters AS ratio
JOIN sys.dm_os_performance_counters AS base
    ON ratio.object_name = base.object_name
WHERE ratio.counter_name = N'Buffer cache hit ratio'
  AND base.counter_name  = N'Buffer cache hit ratio base'
  AND ratio.object_name LIKE N'%Buffer Manager%';

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Top Memory Clerks
  Where the engine's memory is allocated. MEMORYCLERK_SQLBUFFERPOOL dominating
  is normal; a large CACHESTORE_SQLCP (plan cache) suggests ad-hoc bloat.
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (15)
    type                                                AS clerk_type,
    name                                                AS clerk_name,
    CAST(SUM(pages_kb) / 1024.0 AS DECIMAL(18,2))       AS allocated_mb
FROM sys.dm_os_memory_clerks
GROUP BY type, name
ORDER BY SUM(pages_kb) DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Buffer Pool Occupancy by Database
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    CASE database_id WHEN 32767 THEN 'ResourceDB' ELSE DB_NAME(database_id) END AS database_name,
    COUNT_BIG(*)                                        AS cached_pages,
    CAST(COUNT_BIG(*) * 8.0 / 1024 AS DECIMAL(18,2))    AS cached_mb
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY cached_pages DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 6: Memory Grants - Pending & Outstanding (live)
  grant_time NULL  => the query is WAITING for a grant (RESOURCE_SEMAPHORE).
  granted >> max_used => over-granting (wastes memory, limits concurrency).
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    mg.session_id,
    mg.dop,
    CASE WHEN mg.grant_time IS NULL THEN 'WAITING' ELSE 'GRANTED' END AS grant_state,
    mg.wait_time_ms,
    mg.requested_memory_kb / 1024                       AS requested_mb,
    mg.granted_memory_kb   / 1024                       AS granted_mb,
    mg.required_memory_kb  / 1024                       AS required_mb,
    mg.used_memory_kb      / 1024                       AS used_mb,
    mg.max_used_memory_kb  / 1024                       AS max_used_mb,
    mg.ideal_memory_kb     / 1024                       AS ideal_mb,
    mg.query_cost,
    DB_NAME(t.dbid)                                     AS database_name,
    SUBSTRING(t.text, mg.statement_start_offset / 2 + 1,
        (CASE WHEN mg.statement_end_offset = -1
              THEN DATALENGTH(t.text)
              ELSE mg.statement_end_offset END
         - mg.statement_start_offset) / 2 + 1)          AS statement_text
FROM sys.dm_exec_query_memory_grants AS mg
OUTER APPLY sys.dm_exec_sql_text(mg.sql_handle) AS t
ORDER BY (mg.grant_time IS NULL) DESC,                  -- waiting grants first
         mg.requested_memory_kb DESC;

-- Count of grants currently pending (quick gauge; should be 0)
SELECT
    (SELECT cntr_value FROM sys.dm_os_performance_counters
      WHERE counter_name = N'Memory Grants Pending'
        AND object_name LIKE N'%Memory Manager%')       AS memory_grants_pending,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
      WHERE counter_name = N'Memory Grants Outstanding'
        AND object_name LIKE N'%Memory Manager%')       AS memory_grants_outstanding;
