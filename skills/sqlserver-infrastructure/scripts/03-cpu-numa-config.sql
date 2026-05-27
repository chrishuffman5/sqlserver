/*******************************************************************************
 * SQL Server Infrastructure - CPU, NUMA & Scheduler Configuration
 *
 * Purpose : Report the CPU/NUMA topology the engine sees, scheduler state and
 *           runnable-task pressure, NUMA/memory nodes, current MAXDOP and cost
 *           threshold, CPU affinity, soft-NUMA, and a hyperthreading hint - to
 *           validate that MAXDOP matches physical cores per NUMA node.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x) on Windows/Linux. Box product.
 *           socket_count/cores_per_socket/numa_node_count guarded (2016 SP2+/2017+).
 * Safety  : READ-ONLY. No data or configuration is modified. Recommended
 *           changes are shown only as COMMENTED-OUT templates.
 *
 * Sections:
 *   1. CPU summary & hyperthreading hint (sys.dm_os_sys_info)
 *   2. Current MAXDOP, cost threshold & affinity
 *   3. NUMA / memory nodes (sys.dm_os_nodes, sys.dm_os_memory_nodes)
 *   4. Scheduler state & runnable-task pressure (sys.dm_os_schedulers)
 *   5. Soft-NUMA status
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: CPU summary & hyperthreading hint
  Newer columns (socket_count, cores_per_socket, numa_node_count) are version
  guarded so this runs on 2016 RTM where they may be absent.
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @has_socket_cols BIT =
    CASE WHEN EXISTS (SELECT 1 FROM sys.all_columns
                      WHERE object_id = OBJECT_ID('sys.dm_os_sys_info')
                        AND name = 'socket_count') THEN 1 ELSE 0 END;

IF @has_socket_cols = 1
BEGIN
    SELECT
        cpu_count                                       AS logical_cpus,
        hyperthread_ratio                               AS logical_per_physical_socket,
        socket_count,
        cores_per_socket,
        numa_node_count,
        scheduler_count,
        CASE WHEN hyperthread_ratio > cores_per_socket
             THEN 'Hyperthreading LIKELY ON - count PHYSICAL cores for MAXDOP'
             ELSE 'No obvious hyperthreading' END        AS ht_hint,
        physical_memory_kb / 1024                        AS physical_memory_mb,
        virtual_machine_type_desc                        AS vm_type
    FROM sys.dm_os_sys_info;
END
ELSE
BEGIN
    SELECT
        cpu_count                                       AS logical_cpus,
        hyperthread_ratio                               AS logical_per_physical_socket,
        scheduler_count,
        physical_memory_kb / 1024                        AS physical_memory_mb,
        virtual_machine_type_desc                        AS vm_type,
        'socket_count/cores_per_socket not available on this build' AS note
    FROM sys.dm_os_sys_info;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Current MAXDOP, cost threshold & affinity
  Schedulers per NUMA node = the practical ceiling for a "per node" MAXDOP.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    (SELECT CAST(value_in_use AS INT) FROM sys.configurations
       WHERE name = 'max degree of parallelism')                AS maxdop_in_use,
    (SELECT CAST(value_in_use AS INT) FROM sys.configurations
       WHERE name = 'cost threshold for parallelism')           AS cost_threshold_in_use,
    (SELECT CAST(value_in_use AS BIGINT) FROM sys.configurations
       WHERE name = 'affinity mask')                            AS affinity_mask,
    (SELECT CAST(value_in_use AS BIGINT) FROM sys.configurations
       WHERE name = 'affinity I/O mask')                        AS affinity_io_mask,
    (SELECT COUNT(*) FROM sys.dm_os_schedulers
       WHERE status = 'VISIBLE ONLINE')                         AS online_schedulers,
    (SELECT COUNT(DISTINCT parent_node_id) FROM sys.dm_os_schedulers
       WHERE status = 'VISIBLE ONLINE')                         AS online_numa_nodes,
    CASE WHEN (SELECT CAST(value_in_use AS INT) FROM sys.configurations
                 WHERE name = 'max degree of parallelism') = 0
         THEN 'REVIEW - MAXDOP 0 (unlimited); set to physical cores per NUMA node, cap 8'
         ELSE 'configured' END                                  AS maxdop_note,
    CASE WHEN (SELECT CAST(value_in_use AS INT) FROM sys.configurations
                 WHERE name = 'cost threshold for parallelism') <= 5
         THEN 'DEVIATION - cost threshold default (5) is too low; raise to ~50'
         ELSE 'configured' END                                  AS cost_threshold_note;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: NUMA / memory nodes
  Online schedulers per node = candidate per-node MAXDOP (count physical cores).
  High foreign_committed_mb hints at NUMA misalignment.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    n.node_id,
    n.node_state_desc,
    n.memory_node_id,
    n.online_scheduler_count,
    n.processor_group,
    mn.virtual_address_space_committed_kb / 1024 AS committed_mb,
    mn.foreign_committed_kb               / 1024 AS foreign_committed_mb
FROM sys.dm_os_nodes AS n
LEFT JOIN sys.dm_os_memory_nodes AS mn
       ON n.memory_node_id = mn.memory_node_id
WHERE n.node_state_desc <> 'ONLINE DAC'
ORDER BY n.node_id;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Scheduler state & runnable-task pressure
  Persistently high runnable_tasks across schedulers = CPU pressure
  (confirm with signal-wait analysis in sqlserver-monitoring).
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    parent_node_id                  AS numa_node,
    COUNT(*)                        AS schedulers,
    SUM(current_tasks_count)        AS current_tasks,
    SUM(runnable_tasks_count)       AS runnable_tasks,     -- queued, waiting for a scheduler
    SUM(active_workers_count)       AS active_workers,
    SUM(work_queue_count)           AS work_queue,
    CASE WHEN SUM(runnable_tasks_count) > COUNT(*)
         THEN 'CPU PRESSURE - runnable tasks exceed scheduler count'
         ELSE 'ok' END              AS pressure_flag
FROM sys.dm_os_schedulers
WHERE status = 'VISIBLE ONLINE'
GROUP BY parent_node_id
ORDER BY parent_node_id;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Soft-NUMA status (auto soft-NUMA is ON by default 2016+ for >8 cores/node)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    COUNT(*)                                                    AS total_online_nodes,
    SUM(CASE WHEN node_state_desc LIKE '%SOFT%' THEN 1 ELSE 0 END) AS soft_numa_nodes,
    CASE WHEN SUM(CASE WHEN node_state_desc LIKE '%SOFT%' THEN 1 ELSE 0 END) > 0
         THEN 'Soft-NUMA in effect (auto soft-NUMA splits >8-core nodes, 2016+)'
         ELSE 'No soft-NUMA partitioning detected' END          AS soft_numa_note
FROM sys.dm_os_nodes
WHERE node_state_desc NOT LIKE '%DAC%';

/*──────────────────────────────────────────────────────────────────────────────
  Remediation template (COMMENTED OUT)
──────────────────────────────────────────────────────────────────────────────*/
/*
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'max degree of parallelism', 8;       RECONFIGURE;  -- physical cores per NUMA node, cap 8
EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE;
-- Disable auto soft-NUMA only with measured justification (restart required):
-- ALTER SERVER CONFIGURATION SET SOFTNUMA = OFF;
*/
