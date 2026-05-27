/*******************************************************************************
 * SQL Server Infrastructure - Memory Configuration & State
 *
 * Purpose : Report the memory configuration (max/min server memory), physical
 *           RAM, OS memory state, SQL process memory (incl. Lock Pages in
 *           Memory), the target/total server memory counters, and the top
 *           memory clerks - to validate the max-server-memory formula and
 *           detect external memory pressure.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x) on Windows/Linux. Box product.
 * Safety  : READ-ONLY. No data or configuration is modified. Recommended
 *           changes are shown only as COMMENTED-OUT templates.
 *
 * Sections:
 *   1. Configured memory vs physical RAM (with formula reminder)
 *   2. OS system memory state (sys.dm_os_sys_memory)
 *   3. SQL process memory & LPIM (sys.dm_os_process_memory)
 *   4. Target vs Total server memory counters
 *   5. Top memory clerks
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Configured memory vs physical RAM
  Formula: max server memory = RAM - 4GB(OS) - 1GB per 4GB above 16GB - other svcs
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    (SELECT total_physical_memory_kb / 1024 FROM sys.dm_os_sys_memory)              AS total_ram_mb,
    (SELECT CAST(value_in_use AS BIGINT) FROM sys.configurations
       WHERE name = 'max server memory (MB)')                                       AS max_server_memory_mb,
    (SELECT CAST(value_in_use AS BIGINT) FROM sys.configurations
       WHERE name = 'min server memory (MB)')                                       AS min_server_memory_mb,
    -- Suggested cap from the formula (informational only)
    CAST(
        (SELECT total_physical_memory_kb / 1024 FROM sys.dm_os_sys_memory)
        - 4096
        - CASE WHEN (SELECT total_physical_memory_kb / 1024 / 1024 FROM sys.dm_os_sys_memory) > 16
               THEN ((SELECT total_physical_memory_kb / 1024 FROM sys.dm_os_sys_memory) - 16384) / 4
               ELSE 0 END
    AS BIGINT)                                                                      AS suggested_max_mb_formula,
    CASE WHEN (SELECT CAST(value_in_use AS BIGINT) FROM sys.configurations
                 WHERE name = 'max server memory (MB)') = 2147483647
         THEN 'DEVIATION - max server memory is unlimited (default)'
         ELSE 'configured' END                                                      AS note;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: OS system memory state
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    total_physical_memory_kb     / 1024 AS total_physical_mb,
    available_physical_memory_kb / 1024 AS available_physical_mb,
    total_page_file_kb           / 1024 AS total_page_file_mb,
    available_page_file_kb       / 1024 AS available_page_file_mb,
    system_memory_state_desc            AS system_memory_state   -- e.g. 'Available physical memory is high'
FROM sys.dm_os_sys_memory;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: SQL process memory & Lock Pages in Memory
  locked_page_allocations_kb > 0  ⇒  LPIM is active
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    physical_memory_in_use_kb    / 1024 AS sql_physical_mem_mb,
    locked_page_allocations_kb   / 1024 AS locked_pages_mb,        -- > 0 ⇒ LPIM ON
    CASE WHEN locked_page_allocations_kb > 0
         THEN 'LPIM ACTIVE' ELSE 'LPIM not active' END             AS lpim_status,
    large_page_allocations_kb    / 1024 AS large_pages_mb,
    memory_utilization_percentage,                                 -- working set as % of committed
    process_physical_memory_low,                                   -- 1 ⇒ OS signalled low physical memory
    process_virtual_memory_low,                                    -- 1 ⇒ low VAS
    total_virtual_address_space_kb / 1024 AS total_vas_mb
FROM sys.dm_os_process_memory;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Target vs Total server memory
  Total climbing toward Target after startup is normal warm-up.
  Total << Target under load can indicate external memory pressure.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    MAX(CASE WHEN counter_name = 'Target Server Memory (KB)' THEN cntr_value / 1024 END) AS target_server_mem_mb,
    MAX(CASE WHEN counter_name = 'Total Server Memory (KB)'  THEN cntr_value / 1024 END) AS total_server_mem_mb,
    MAX(CASE WHEN counter_name = 'Database Cache Memory (KB)' THEN cntr_value / 1024 END) AS database_cache_mb,
    MAX(CASE WHEN counter_name = 'Free Memory (KB)'          THEN cntr_value / 1024 END) AS free_memory_mb
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Memory Manager%'
  AND counter_name IN ('Target Server Memory (KB)', 'Total Server Memory (KB)',
                       'Database Cache Memory (KB)', 'Free Memory (KB)');

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Top memory clerks (where SQL's memory actually went)
  MEMORYCLERK_SQLBUFFERPOOL should dominate on a healthy OLTP box.
  Large CACHESTORE_SQLCP relative to reuse ⇒ ad-hoc plan bloat (optimize for ad hoc).
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP 15
    type,
    name,
    pages_kb                    / 1024 AS pages_mb,
    virtual_memory_committed_kb / 1024 AS vm_committed_mb,
    awe_allocated_kb            / 1024 AS awe_allocated_mb
FROM sys.dm_os_memory_clerks
ORDER BY pages_kb DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Remediation template (COMMENTED OUT - compute the value first)
──────────────────────────────────────────────────────────────────────────────*/
/*
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'max server memory (MB)', 49152; RECONFIGURE;   -- use the formula above
-- Lock Pages in Memory: grant "Lock pages in memory" to the SQL service account
-- (Windows policy). ALWAYS pair with a correct max server memory cap.
*/
