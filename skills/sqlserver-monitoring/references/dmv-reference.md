# DMV Reference Catalog

A categorized catalog of the Dynamic Management Views (DMVs) and Functions (DMFs) that matter for performance monitoring, each with a runnable example. DMVs are the live instrumentation surface of the engine — most are *cumulative since restart*, so diff snapshots when you want a window.

Applies to SQL Server 2016–2025. Version notes are inline. On Azure SQL Database, instance-scoped DMVs are scoped to your database/replica and a few are unavailable — see the platform notes and `sqlserver-cloud`.

Permissions: most require `VIEW SERVER STATE` (box/MI) or `VIEW DATABASE STATE` (Azure SQL DB). Reading plan/text functions additionally needs the request to be visible to you.

> **Least-privilege monitoring logins (2022+).** SQL Server 2022 split the broad `VIEW SERVER STATE` into granular **`VIEW SERVER PERFORMANCE STATE`** (the performance/diagnostic DMVs this skill uses) and **`VIEW SERVER SECURITY STATE`** (the security-related ones), with matching fixed server roles (`##MS_ServerPerformanceStateReader##`, `##MS_ServerSecurityStateReader##`) and database-scoped equivalents (`VIEW DATABASE PERFORMANCE STATE` / `VIEW DATABASE SECURITY STATE`). Grant a monitoring account `VIEW SERVER PERFORMANCE STATE` instead of full `VIEW SERVER STATE` so it can read waits/plans/grants without exposing logins, permissions, or cryptographic metadata. Note: on 2022+, a few performance DMVs now require the *performance* permission specifically, so a login with only legacy `VIEW SERVER STATE` may still hit permission errors. Available on SQL Server 2022+ and Azure SQL; verify exact permission/role names and per-DMV requirements on Microsoft Learn for your build. Granting these is a `[SECURITY CHANGE]` — see `sqlserver-security`.

---

## 1. Execution & Performance

| DMV / DMF | Scope | Purpose |
|---|---|---|
| `sys.dm_exec_query_stats` | Instance | Aggregated per-statement stats for cached plans (CPU, reads, writes, duration, executions) |
| `sys.dm_exec_procedure_stats` | Instance | Same, aggregated per stored procedure |
| `sys.dm_exec_trigger_stats` | Instance | Per-trigger performance |
| `sys.dm_exec_function_stats` (2016+) | Instance | Per scalar UDF performance |
| `sys.dm_exec_requests` | Instance | Currently executing requests (live) |
| `sys.dm_exec_sessions` | Instance | All sessions (active and sleeping) |
| `sys.dm_exec_connections` | Instance | Physical connections, network, last read/write |
| `sys.dm_exec_cached_plans` | Instance | Plan-cache entries, use counts, size |
| `sys.dm_exec_query_plan(plan_handle)` | DMF | XML plan for a plan handle |
| `sys.dm_exec_text_query_plan(...)` | DMF | Statement-scoped XML plan (avoids truncation) |
| `sys.dm_exec_sql_text(handle)` | DMF | SQL batch text for a sql/plan handle |
| `sys.dm_exec_input_buffer(spid, req)` (2016+) | DMF | The literal input buffer of a session (replaces `DBCC INPUTBUFFER`) |
| `sys.dm_exec_query_stats_xml` / `sys.dm_exec_query_plan_stats` (2019+) | DMF | Last *actual* plan (runtime stats) when "last query plan stats" is on |
| `sys.dm_exec_query_profiles` | Instance | **Live per-operator actual row counts** for *currently running* queries (powers Live Query Statistics) |

**Watch a running query in flight.** `sys.dm_exec_query_profiles` returns one row per plan operator for in-progress statements, with the running `row_count` next to `estimate_row_count` — diff them to catch a cardinality blow-up before the query even finishes. It is fed by the **lightweight query profiling infrastructure**: **default-on in SQL Server 2019+** (and Azure SQL DB/MI). On 2016 SP1+/2017 enable it with trace flag **7412** (instance-wide) or a `query_thread_profile` XEvents session; on 2019+ TF 7412 has no effect. Disable per database via the `LIGHTWEIGHT_QUERY_PROFILING` database-scoped configuration. (Verify version/flag details on Microsoft Learn for your build.)

```sql
-- Live actual-vs-estimated rows per operator for a running session (replace 123)
SELECT
    qp.session_id, qp.node_id, qp.physical_operator_name,
    qp.row_count                                        AS actual_rows_so_far,
    qp.estimate_row_count                               AS estimated_rows,
    qp.elapsed_time_ms, qp.cpu_time_ms, qp.logical_read_count
FROM sys.dm_exec_query_profiles AS qp
WHERE qp.session_id = 123
ORDER BY qp.node_id;
```

**The plan cache is volatile** — it clears on restart, under memory pressure, and on recompiles. For history that survives those events, use Query Store (`references/query-store.md`).

```sql
-- Top 20 statements by total CPU, with text and plan (offset math trims to the statement)
SELECT TOP (20)
    qs.execution_count,
    qs.total_worker_time / 1000                         AS total_cpu_ms,
    qs.total_worker_time / NULLIF(qs.execution_count,0) / 1000 AS avg_cpu_ms,
    qs.total_logical_reads,
    qs.total_logical_reads / NULLIF(qs.execution_count,0)      AS avg_logical_reads,
    qs.total_elapsed_time / 1000                        AS total_elapsed_ms,
    qs.last_execution_time,
    SUBSTRING(qt.text,
        qs.statement_start_offset / 2 + 1,
        (CASE WHEN qs.statement_end_offset = -1
              THEN DATALENGTH(qt.text)
              ELSE qs.statement_end_offset END
         - qs.statement_start_offset) / 2 + 1)          AS statement_text,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)     AS qt
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle)  AS qp
ORDER BY qs.total_worker_time DESC;
```

```sql
-- Live, currently-running requests with their wait and progress
SELECT
    r.session_id, r.status, r.command,
    r.wait_type, r.wait_time, r.last_wait_type, r.wait_resource,
    r.blocking_session_id,
    r.cpu_time, r.total_elapsed_time, r.logical_reads, r.reads, r.writes,
    r.percent_complete,            -- populated for BACKUP/RESTORE/DBCC/index rebuild
    DB_NAME(r.database_id)         AS database_name,
    SUBSTRING(t.text,
        r.statement_start_offset/2 + 1,
        (CASE WHEN r.statement_end_offset = -1
              THEN DATALENGTH(t.text)
              ELSE r.statement_end_offset END
         - r.statement_start_offset)/2 + 1) AS current_statement
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.session_id <> @@SPID
  AND r.session_id > 50
ORDER BY r.cpu_time DESC;
```

---

## 2. I/O

| DMV / DMF | Purpose |
|---|---|
| `sys.dm_io_virtual_file_stats(db_id, file_id)` | Per-file I/O totals & stall (latency) since restart |
| `sys.dm_os_buffer_descriptors` | Every page currently in the buffer pool (by DB) |
| `sys.dm_io_pending_io_requests` | Outstanding (in-flight) physical I/O requests |
| `sys.dm_db_index_physical_stats(...)` | Index fragmentation & page density (heavy — sample) |

```sql
-- Per-file read/write latency. Cumulative since restart — diff two snapshots for a window.
SELECT
    DB_NAME(vfs.database_id)                            AS database_name,
    mf.name                                             AS logical_file,
    mf.type_desc                                        AS file_type,
    vfs.num_of_reads,
    vfs.num_of_writes,
    CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS DECIMAL(18,2)) AS avg_read_latency_ms,
    CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes,0)  AS DECIMAL(18,2)) AS avg_write_latency_ms,
    (vfs.num_of_bytes_read  / 1024 / 1024)              AS mb_read,
    (vfs.num_of_bytes_written / 1024 / 1024)            AS mb_written
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
    ON vfs.database_id = mf.database_id
   AND vfs.file_id     = mf.file_id
ORDER BY vfs.io_stall DESC;
```

Latency rule of thumb: data files < ~10–20 ms, log files < ~5 ms. Sustained higher values (especially on the log) point at storage; correlate with `WRITELOG`/`PAGEIOLATCH` waits.

```sql
-- Buffer pool occupancy by database (where is memory going)
SELECT
    CASE database_id WHEN 32767 THEN 'ResourceDB' ELSE DB_NAME(database_id) END AS database_name,
    COUNT_BIG(*)                                        AS cached_pages,
    CAST(COUNT_BIG(*) * 8.0 / 1024 AS DECIMAL(18,2))    AS cached_mb
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY cached_pages DESC;
```

> **Platform note.** On **Azure SQL Database** `sys.dm_io_virtual_file_stats` returns only the current database's files. `sys.dm_os_buffer_descriptors` is available on MI/box but limited/unavailable on Azure SQL DB.

---

## 3. Memory

| DMV | Purpose |
|---|---|
| `sys.dm_os_memory_clerks` | Memory consumption broken down by internal component (clerk) |
| `sys.dm_exec_query_memory_grants` | Live memory grants — who has/wants workspace memory, spill risk |
| `sys.dm_os_process_memory` | SQL Server process memory (committed, working set, locked pages) |
| `sys.dm_os_sys_memory` | OS-level physical memory and memory state |
| `sys.dm_os_memory_brokers` | Internal memory broker targets (buffer pool vs cache vs grants) |

```sql
-- Top memory clerks (where SQL Server's memory is allocated)
SELECT TOP (15)
    type                                                AS clerk_type,
    name                                                AS clerk_name,
    CAST(SUM(pages_kb) / 1024.0 AS DECIMAL(18,2))       AS allocated_mb
FROM sys.dm_os_memory_clerks
GROUP BY type, name
ORDER BY SUM(pages_kb) DESC;
```

```sql
-- Live memory grants: pending grants and large/over-granting queries
SELECT
    mg.session_id,
    mg.dop,
    mg.request_time,
    mg.grant_time,                                      -- NULL while still waiting (RESOURCE_SEMAPHORE)
    mg.requested_memory_kb / 1024                       AS requested_mb,
    mg.granted_memory_kb   / 1024                       AS granted_mb,
    mg.required_memory_kb  / 1024                       AS required_mb,
    mg.used_memory_kb      / 1024                       AS used_mb,
    mg.max_used_memory_kb  / 1024                       AS max_used_mb,
    mg.ideal_memory_kb     / 1024                       AS ideal_mb,
    mg.query_cost,
    mg.wait_time_ms,
    SUBSTRING(t.text, mg.statement_start_offset/2 + 1,
        (CASE WHEN mg.statement_end_offset = -1
              THEN DATALENGTH(t.text)
              ELSE mg.statement_end_offset END
         - mg.statement_start_offset)/2 + 1)            AS statement_text
FROM sys.dm_exec_query_memory_grants AS mg
OUTER APPLY sys.dm_exec_sql_text(mg.sql_handle) AS t
ORDER BY (mg.grant_time IS NULL) DESC,                  -- pending grants first
         mg.requested_memory_kb DESC;
```

A grant where `granted_mb` greatly exceeds `max_used_mb` is over-granting (wasted reservation, fewer concurrent queries); a grant smaller than what the query needed spills to tempdb. Both are plan/estimate problems — hand off to `sqlserver-engineering`.

```sql
-- Process and OS memory state
SELECT
    physical_memory_in_use_kb / 1024                    AS sql_working_set_mb,
    locked_page_allocations_kb / 1024                   AS locked_pages_mb,
    large_page_allocations_kb / 1024                    AS large_pages_mb,
    memory_utilization_percentage,
    process_physical_memory_low,                        -- 1 => external memory pressure
    process_virtual_memory_low
FROM sys.dm_os_process_memory;
```

---

## 4. Index Usage & Missing Indexes

| DMV | Purpose |
|---|---|
| `sys.dm_db_index_usage_stats` | Seeks / scans / lookups / updates per index since restart |
| `sys.dm_db_index_operational_stats(...)` | Low-level activity: row locks, page splits, latch waits per index |
| `sys.dm_db_missing_index_details` | Columns the optimizer wished it had an index on |
| `sys.dm_db_missing_index_groups` | Links details to group stats |
| `sys.dm_db_missing_index_group_stats` | Impact estimate (seeks, scans, avg user impact, cost) |

> **Use these to *spot* an index problem, not to apply fixes blindly.** Missing-index suggestions ignore existing indexes, write/maintenance cost, and column order beyond equality/inequality; applied verbatim they create wide, redundant, over-included indexes. Index *design* — consolidating suggestions, choosing key order, covering vs included columns, fill factor — belongs to **`sqlserver-engineering`**.

```sql
-- Missing-index suggestions ranked by a rough improvement measure (TRIAGE ONLY)
SELECT TOP (25)
    DB_NAME(mid.database_id)                            AS database_name,
    mid.statement                                       AS table_name,
    migs.user_seeks, migs.user_scans,
    migs.avg_user_impact,
    migs.avg_total_user_cost,
    CAST(migs.avg_total_user_cost
         * migs.avg_user_impact / 100.0
         * (migs.user_seeks + migs.user_scans) AS DECIMAL(18,2)) AS improvement_measure,
    mid.equality_columns, mid.inequality_columns, mid.included_columns
FROM sys.dm_db_missing_index_group_stats AS migs
JOIN sys.dm_db_missing_index_groups  AS mig ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details AS mid ON mig.index_handle  = mid.index_handle
ORDER BY improvement_measure DESC;
```

```sql
-- Unused / write-heavy indexes (candidates for review by sqlserver-engineering)
SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS table_name,
    i.name                                              AS index_name,
    ius.user_seeks, ius.user_scans, ius.user_lookups,
    ius.user_updates,                                   -- write cost
    ius.last_user_seek, ius.last_user_scan
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS ius
    ON i.object_id = ius.object_id
   AND i.index_id  = ius.index_id
   AND ius.database_id = DB_ID()
WHERE i.index_id > 1                                    -- skip heap/clustered
  AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
ORDER BY ius.user_updates DESC;
```

---

## 5. OS / Scheduler

| DMV | Purpose |
|---|---|
| `sys.dm_os_schedulers` | One row per scheduler (≈ logical CPU): runnable queue, active workers, pending I/O |
| `sys.dm_os_sys_info` | Instance facts: CPU count, physical memory, scheduler count, uptime, hyperthread ratio |
| `sys.dm_os_ring_buffers` | Internal ring buffers — `RING_BUFFER_SCHEDULER_MONITOR` gives CPU-usage history |
| `sys.dm_os_performance_counters` | Perfmon counters readable in T-SQL (see counters reference) |
| `sys.dm_os_waiting_tasks` | Live waiting tasks (the live counterpart of wait stats) |
| `sys.dm_os_nodes` | NUMA / soft-NUMA node layout |

```sql
-- Scheduler health: a persistently high runnable_tasks_count => CPU pressure
SELECT
    scheduler_id, cpu_id, status,
    is_online, is_idle,
    current_tasks_count,
    runnable_tasks_count,                               -- tasks ready, waiting for CPU (signal-wait companion)
    current_workers_count, active_workers_count,
    work_queue_count,
    pending_disk_io_count
FROM sys.dm_os_schedulers
WHERE scheduler_id < 1048576                            -- user schedulers only (exclude hidden/DAC)
ORDER BY runnable_tasks_count DESC;
```

```sql
-- Recent SQL vs other CPU % from the scheduler-monitor ring buffer
SELECT TOP (30)
    DATEADD(ms, -1 * (si.ms_ticks - rb.[timestamp]), GETDATE()) AS event_time,
    rb.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int')      AS sql_cpu_pct,
    rb.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]','int')              AS system_idle_pct,
    100
      - rb.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]','int')
      - rb.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int')  AS other_process_cpu_pct
FROM
(
    SELECT [timestamp], CONVERT(XML, record) AS record
    FROM sys.dm_os_ring_buffers
    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
      AND record LIKE N'%<SystemHealth>%'
) AS rb
CROSS JOIN sys.dm_os_sys_info AS si
ORDER BY rb.[timestamp] DESC;
```

> **Platform note.** `sys.dm_os_ring_buffers` and `sys.dm_os_schedulers` are unavailable on **Azure SQL Database**; read CPU there from `sys.dm_db_resource_stats` (`sqlserver-cloud`). They are available on **Managed Instance** and **box**.

---

## 6. Transactions & Version Store

| DMV | Purpose |
|---|---|
| `sys.dm_tran_active_transactions` | All active transactions (id, begin time, type, state) |
| `sys.dm_tran_session_transactions` | Maps sessions to transactions |
| `sys.dm_tran_database_transactions` | Per-DB transaction detail incl. log bytes used |
| `sys.dm_tran_version_store_space_usage` (2017+) | Version-store space attributed per database |
| `sys.dm_tran_active_snapshot_database_transactions` | Open snapshot/RCSI transactions holding versions |
| `sys.dm_db_file_space_usage` | tempdb file space split (user/internal/version-store) |
| `sys.dm_tran_locks` | Every live lock request (granted/waiting) |

```sql
-- Oldest active transactions (long open transactions block log truncation & escalate locks)
SELECT
    at.transaction_id,
    at.name                                             AS transaction_name,
    at.transaction_begin_time,
    DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) AS open_seconds,
    st.session_id,
    es.login_name, es.host_name, es.program_name,
    DB_NAME(dt.database_id)                             AS database_name,
    dt.database_transaction_log_bytes_used / 1024       AS log_kb_used
FROM sys.dm_tran_active_transactions AS at
LEFT JOIN sys.dm_tran_session_transactions AS st ON at.transaction_id = st.transaction_id
LEFT JOIN sys.dm_tran_database_transactions AS dt ON at.transaction_id = dt.transaction_id
LEFT JOIN sys.dm_exec_sessions AS es ON st.session_id = es.session_id
WHERE at.transaction_begin_time IS NOT NULL
ORDER BY at.transaction_begin_time ASC;
```

```sql
-- Version store usage per database (2017+) — RCSI/snapshot bloat detector
SELECT
    DB_NAME(database_id)                                AS database_name,
    reserved_page_count,
    CAST(reserved_space_kb / 1024.0 AS DECIMAL(18,2))   AS reserved_mb
FROM sys.dm_tran_version_store_space_usage
ORDER BY reserved_space_kb DESC;
```

```sql
-- tempdb space breakdown (version store vs internal vs user objects)
SELECT
    SUM(user_object_reserved_page_count)     * 8 / 1024 AS user_objects_mb,
    SUM(internal_object_reserved_page_count) * 8 / 1024 AS internal_objects_mb,
    SUM(version_store_reserved_page_count)   * 8 / 1024 AS version_store_mb,
    SUM(unallocated_extent_page_count)       * 8 / 1024 AS free_mb
FROM tempdb.sys.dm_db_file_space_usage;
```

A growing version store with no end usually means a long-running read transaction under RCSI/snapshot is pinning old row versions — find it with the active-transactions query above.
