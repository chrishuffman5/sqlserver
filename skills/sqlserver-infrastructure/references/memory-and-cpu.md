# SQL Server Memory and CPU Reference

How SQL Server consumes memory and CPU on the platform, how to size and configure both, and what healthy looks like. Configuration here; *diagnosis* of pressure (interpreting waits, PLE trends over time, plan-level memory grants) is **sqlserver-monitoring** and **sqlserver-engineering** — this reference points there at the right moments.

**Scope:** box product 2016–2025 on Windows/Linux/containers. On Azure SQL DB/MI the engine manages most of this for you (memory is tied to the service tier/vCores) — see **sqlserver-cloud**.

---

## Memory Regions

SQL Server's memory is not one pool; it is many clerks. The major regions:

| Region | What it holds | Notes |
|---|---|---|
| **Buffer pool** | Data and index **pages** (8 KB each) read from disk | Usually the largest consumer; the cache that makes SQL fast |
| **Plan cache** | Compiled execution plans (`CACHESTORE_SQLCP`, `CACHESTORE_OBJCP`) | Bloats with single-use ad-hoc plans → `optimize for ad hoc workloads` |
| **Query workspace memory** | **Memory grants** for Sort, Hash Match/Join, and other operators | Under-grant → spill to tempdb (slow); over-grant → wasted reservation, limited concurrency |
| **Lock memory** | Lock-manager structures for concurrency control | Grows with lock count; escalation curbs runaway growth. **Optimized locking** (SQL Server 2025 / Azure SQL DB/MI; requires ADR) holds far fewer locks per transaction, materially reducing lock memory and escalation |
| **CLR** | .NET runtime + CLR object memory | Only relevant when `clr enabled = 1` |
| **Thread stacks** | One stack per worker thread | 2 MB/thread on x64 (512 KB on x86); scales with `max worker threads` |
| **In-Memory OLTP** | Memory-optimized table rows + indexes | Lives outside the buffer pool; bound by `max server memory` (2016+) and resource-pool limits |
| **Column store object pool** | Columnstore segments/dictionaries | Relevant for analytical/HTAP workloads |

Inspect the live distribution with **memory clerks**:

```sql
SELECT TOP 15
    type,
    name,
    pages_kb / 1024            AS pages_mb,
    virtual_memory_committed_kb / 1024 AS vm_committed_mb
FROM   sys.dm_os_memory_clerks
ORDER BY pages_kb DESC;
```

`MEMORYCLERK_SQLBUFFERPOOL` should dominate on a healthy OLTP box. A large `CACHESTORE_SQLCP` (SQL plans) relative to reuse points at ad-hoc plan bloat. The script `02-memory-config.sql` reports the top clerks and the target/total counters.

### Query workspace memory and grants (the infra view)

Query workspace memory is the pool from which Sort/Hash operators receive **memory grants**. The *size* of a grant is a query-plan decision (cardinality-estimate driven — tuning that is **sqlserver-engineering**), but the platform sets the boundaries:

- A single query cannot grab the whole pool: there is an internal per-query grant ceiling (~25% of the workspace), and Resource Governor's `REQUEST_MAX_MEMORY_GRANT_PERCENT` can lower it per workload group.
- Under-grant → the operator **spills to tempdb** (slow; shows as `HASH`/`SORT` warnings and tempdb writes). Over-grant → memory is reserved but idle, which throttles concurrency (other queries wait on `RESOURCE_SEMAPHORE`).
- `RESOURCE_SEMAPHORE` waits at the instance level mean grants are starving each other — a sign the box is memory-short for its concurrency, or that a few queries have grossly over-estimated grants. This is the bridge between infrastructure (total RAM, `max server memory`) and query design.

### In-Memory OLTP memory

Memory-optimized tables live **outside** the buffer pool but still count against `max server memory` (2016+). A runaway memory-optimized table can consume the whole cap and put the database into a memory-pressure state where new inserts are rejected. Bind In-Memory OLTP to a **Resource Governor resource pool** with a percentage cap so it cannot starve the rest of the engine. Sizing and durability (`SCHEMA_ONLY` vs `SCHEMA_AND_DATA`) are engineering concerns; the platform concern is reserving headroom for it within the cap.

---

## Sizing `max server memory` / `min server memory`

### The formula (do not use "half the RAM")

```
max server memory = Total RAM
                    − OS reservation (≈ 4 GB baseline, more on large boxes)
                    − 1 GB per 4 GB of RAM above 16 GB   (thread stacks, CLR, backups, linked servers, MTL)
                    − any other services on the box (SSIS/SSRS/SSAS, agents, AV, app tier)
```

Worked example, 64 GB dedicated: `64 − 4 − ((64 − 16) / 4) = 64 − 4 − 12 = 48 GB (49152 MB)`.

```sql
SELECT
    (SELECT total_physical_memory_kb / 1024 FROM sys.dm_os_sys_memory) AS total_ram_mb,
    (SELECT value_in_use FROM sys.configurations WHERE name = 'max server memory (MB)') AS max_server_memory_mb,
    (SELECT value_in_use FROM sys.configurations WHERE name = 'min server memory (MB)') AS min_server_memory_mb;
```

- **Version note:** on **2019+** `max server memory` bounds essentially all SQL allocations — the cap is an accurate ceiling. On 2016/2017 it largely bounded the buffer pool, so leave slightly more headroom for the out-of-pool consumers.
- **`min server memory`**: leave at **0** on dedicated boxes. Set a floor (e.g., 25–50% of max) only on shared boxes where SQL has been trimmed too hard. It is the level SQL will not voluntarily drop below — not a startup pre-allocation.
- **Multiple instances** on one host: the sum of all instances' `max server memory` plus OS headroom must fit in physical RAM, or they will fight (and page).

### Target vs total server memory

```sql
SELECT counter_name, cntr_value / 1024 AS value_mb
FROM   sys.dm_os_performance_counters
WHERE  object_name LIKE '%Memory Manager%'
  AND  counter_name IN ('Target Server Memory (KB)', 'Total Server Memory (KB)');
```

- **Total** climbing toward **Target** after startup = normal warm-up.
- **Total** well below **Target** and not rising under load can indicate external memory pressure or a `min`/`max` misconfiguration.
- **Total ≈ Target** and stable = healthy steady state.

---

## Lock Pages in Memory (LPIM)

LPIM grants the SQL service account the Windows **"Lock pages in memory"** user-right so the OS cannot page SQL's buffer pool out to disk under memory pressure. This protects against a hard working-set trim that tanks performance.

**When to use it:**
- Physical (bare-metal) servers, especially large-memory boxes.
- VMs where you observe the balloon driver / host trimming SQL's working set (sudden PLE collapse with the buffer pool shrinking).

**Confirm it is active** (locked allocations are non-zero only when LPIM is granted and working):

```sql
SELECT
    physical_memory_in_use_kb / 1024 AS sql_physical_mem_mb,
    locked_page_allocations_kb / 1024 AS locked_pages_mb,   -- > 0  ⇒ LPIM active
    memory_utilization_percentage,
    process_physical_memory_low,                            -- 1 ⇒ OS signalling low memory
    process_virtual_memory_low
FROM   sys.dm_os_process_memory;
```

**Risks and rules:**
- **Always pair LPIM with a correct `max server memory`.** Locked pages cannot be paged out, so if the cap is too high SQL can lock the OS out of RAM and destabilize the box.
- Granting the privilege is a security/hardening action on the service account — coordinate with **sqlserver-security**.
- On **Linux**, the concept maps differently — memory limits are set via `mssql-conf` (`memory.memorylimitmb`) and the OS does not have the Windows LPIM policy; see `platform-and-network.md`.

---

## NUMA, Soft-NUMA, and Memory Nodes

### Hardware NUMA

On multi-socket servers, each socket has memory **local** to it. Accessing another node's memory ("**foreign** memory") is slower. SQL builds **memory nodes** aligned to the hardware NUMA topology and tries to keep a query's threads and memory on the same node.

```sql
-- Hardware/soft NUMA nodes the engine sees
SELECT node_id, node_state_desc, memory_node_id, online_scheduler_count,
       processor_group, cpu_affinity_mask
FROM   sys.dm_os_nodes
WHERE  node_state_desc <> 'ONLINE DAC';

-- Memory per node, and foreign (cross-node) pages — high foreign pages hint at NUMA misalignment
SELECT memory_node_id,
       virtual_address_space_committed_kb / 1024 AS committed_mb,
       foreign_committed_kb / 1024                AS foreign_committed_mb
FROM   sys.dm_os_memory_nodes;
```

### Automatic soft-NUMA (2016+)

When a hardware NUMA node (or a non-NUMA socket) has **more than 8 physical cores**, SQL Server **2016+** automatically partitions it into **soft-NUMA** nodes to reduce contention on per-node structures (e.g., the lazywriter and partitioned data structures). The engine aims for **8 cores per soft node** but may use **as few as 4 or as many as 8**; simultaneous multithreading (SMT/hyperthread) cores are **not** counted when measuring physical cores per node. It is **on by default**; the extra nodes show in `sys.dm_os_nodes` (and `sys.dm_os_sys_info.softnuma_configuration`).

- Automatic soft-NUMA generally helps high-core-count single-socket servers; leave it on unless you have a specific reason and measurements to disable it.

```sql
-- [CONFIG CHANGE] disabling automatic soft-NUMA — REQUIRES A SERVICE RESTART to take effect. Confirm the target instance.
-- Rollback: ALTER SERVER CONFIGURATION SET SOFTNUMA = ON; (restart again). Verify default behavior on Microsoft Learn for your build.
-- ALTER SERVER CONFIGURATION SET SOFTNUMA = OFF;
```

- Soft-NUMA changes how **schedulers group** but does **not** change physical memory locality (it cannot move memory between hardware nodes).

---

## Schedulers, Worker Threads, and CPU Affinity

### Schedulers

SQL Server uses **cooperative (non-preemptive) scheduling**: one **scheduler** per logical CPU that is visible online. A scheduler runs one worker at a time; workers voluntarily yield. This is why pure CPU contention shows up as `SOS_SCHEDULER_YIELD` and a non-empty runnable queue rather than OS-level thread thrashing.

```sql
SELECT
    parent_node_id                                   AS numa_node,
    COUNT(*)                                          AS schedulers,
    SUM(current_tasks_count)                          AS current_tasks,
    SUM(runnable_tasks_count)                         AS runnable_tasks,   -- queued, waiting for CPU
    SUM(active_workers_count)                         AS active_workers
FROM   sys.dm_os_schedulers
WHERE  status = 'VISIBLE ONLINE'                       -- exclude DAC / hidden schedulers
GROUP BY parent_node_id
ORDER BY parent_node_id;
```

A persistently high `runnable_tasks` count across schedulers = CPU pressure (more demand than cores). Confirm with signal-wait analysis in **sqlserver-monitoring**.

### Worker threads

Each scheduler draws workers from a pool sized by `max worker threads` (`0` = auto; see `instance-configuration.md`). `THREADPOOL` waits mean the pool is exhausted — almost always a *symptom* of long blocking, not a reason to raise the thread count. Raising it just costs ~2 MB of stack per thread (x64) and delays the real fix.

### MAXDOP relative to physical cores per NUMA node

The parallelism cap should respect the NUMA topology so a parallel query stays within one node's cores where possible:

- Count **physical** cores in **one** NUMA node (exclude hyperthreads).
- Set MAXDOP to that number, capped at **8**.
- OLTP: bias lower (1–4). DW/reporting: 4–8.

```sql
-- Logical CPUs, NUMA node count, and a hyperthreading hint
SELECT
    cpu_count                                                   AS logical_cpus,
    (SELECT COUNT(DISTINCT parent_node_id)
       FROM sys.dm_os_schedulers
      WHERE status = 'VISIBLE ONLINE')                          AS numa_nodes,
    hyperthread_ratio,                                          -- logical : physical per socket
    CASE WHEN hyperthread_ratio < cpu_count / NULLIF(socket_count,0)
         THEN 'Hyperthreading likely ON — count PHYSICAL cores for MAXDOP'
         ELSE 'No obvious hyperthreading'
    END                                                         AS ht_hint,
    socket_count, cores_per_socket                              -- 2016 SP2+/2017+ columns
FROM   sys.dm_os_sys_info;
```

(Column availability: `socket_count`/`cores_per_socket`/`numa_node_count` appear on newer builds — script `03-cpu-numa-config.sql` guards for them.) CPU **affinity** (`affinity mask`) should stay at default unless you are deliberately partitioning physical cores between co-located instances; pinning the wrong cores can leave schedulers offline.

---

## Signs of CPU Pressure (pointer)

Configuration lives here; *diagnosis* is **sqlserver-monitoring**. The fingerprints to recognize, then hand off:

- **`SOS_SCHEDULER_YIELD`** dominating wait stats — workers yielding because they cannot get enough CPU time.
- **High signal-wait %** — tasks are ready (signaled) but waiting in the runnable queue for a scheduler.
- **Non-empty `runnable_tasks_count`** across schedulers (the query above).
- **Sustained > 80% CPU** in `sys.dm_os_ring_buffers` (SQL vs other-process split) or perfmon.

If MAXDOP and cost threshold are at defaults, fixing those (here) often *is* the remedy for parallelism-driven CPU burn. If they are already tuned, the cause is workload/plan-level — route to **sqlserver-monitoring**/**sqlserver-engineering**.
