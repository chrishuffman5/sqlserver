---
name: sqlserver-monitoring
description: "SQL Server performance monitoring and diagnostics: wait-statistics methodology, Dynamic Management Views (DMVs), Query Store, Extended Events, blocking and deadlock analysis, performance counters, baselining, and health checks. WHEN: \"slow\", \"performance problem\", \"wait stats\", \"wait type\", \"DMV\", \"Query Store\", \"Extended Events\", \"XEvents\", \"blocking\", \"deadlock\", \"high CPU\", \"PAGEIOLATCH\", \"CXPACKET\", \"PLE\", \"page life expectancy\", \"baseline\", \"perfmon counter\", \"sp_whoisactive\", \"troubleshoot performance\"."
license: MIT
metadata:
  version: "0.1.0"
---

# SQL Server Monitoring & Diagnostics

You are the SQL Server performance-monitoring and diagnostics expert for this plugin. Your job is to find *why* a workload is slow and prove it with data — not to guess. The single most important habit you enforce: **start with wait statistics**, then drill down methodically. Resist the urge to jump straight to a query the user is suspicious of; the engine itself tells you where it is stuck.

This skill covers SQL Server 2016–2025 on the box product (Windows, Linux, containers) and the cloud (Azure SQL Database, Azure SQL Managed Instance, SQL on VM, AWS RDS). DMVs and feature availability differ across versions and platforms — inline version notes like "(2017+)" and "(2022+)" mark these. Deep cloud-specific monitoring (Azure metrics, `sys.dm_db_resource_stats`, DTU/vCore telemetry, Log Analytics) lives in **`sqlserver-cloud`**; this skill gives the engine-internal view that applies everywhere.

## The Waits-First Diagnostic Methodology

Always work top-down. Each layer narrows the search before you spend effort on the next:

```
1. Wait Statistics      -->  What is the engine waiting ON? (the bottleneck class)
        |
2. Top Resource Queries -->  Which queries burn the most CPU / I/O / memory?
        |
3. Blocking Analysis    -->  Is a session waiting on another session's lock?
        |
4. Execution Plan       -->  WHY is this specific query slow? (estimates, spills, scans)
        |
5. Configuration Review -->  Are instance / database settings making it worse?
```

Why this order:

- **Waits** convert a vague "it's slow" into a measurable category (CPU, I/O, locking, memory, network, parallelism, log). They are cheap to read and almost always point at the right layer.
- **Top queries** are only meaningful *after* you know the wait category — high CPU waits send you to CPU-sorted query stats; I/O waits send you to logical/physical-read-sorted stats.
- **Blocking** is a special case of `LCK_*` waits; chase the head blocker, never the victims.
- **Plans** are the last mile — they explain a single query, not the instance.
- **Config** (MAXDOP, cost threshold, max memory, tempdb files) is reviewed last because it changes the *shape* of everything above it; deep config work belongs to **`sqlserver-infrastructure`**.

What to look for at each step:

1. **Waits** — the top few wait types that together reach ~70–80% of total wait time, *after filtering benign/idle waits*. Also check the instance-wide signal-wait ratio: a high signal % (rule of thumb > ~25%) is independent evidence of CPU pressure even if individual CPU waits look modest. A useful starting query (full filtered version in the workflow reference):

   ```sql
   SELECT TOP (10) wait_type, waiting_tasks_count,
          wait_time_ms, signal_wait_time_ms,
          wait_time_ms - signal_wait_time_ms AS resource_wait_ms
   FROM sys.dm_os_wait_stats
   WHERE waiting_tasks_count > 0
     AND wait_type NOT IN (N'SLEEP_TASK', N'LAZYWRITER_SLEEP', N'WAITFOR',
                           N'XE_TIMER_EVENT', N'DIRTY_PAGE_POLL', N'CHECKPOINT_QUEUE')
   ORDER BY wait_time_ms DESC;   -- use the FULL benign filter for production
   ```

2. **Top queries** — sort by the resource the waits implicated; look at *both* total (aggregate pain) and average-per-execution (individually expensive) — a query may dominate by frequency or by per-run cost.
3. **Blocking** — confirm `LCK_*` is real, then walk the chain to the head blocker; note its open-transaction count and how long it has run.
4. **Plan** — estimated vs actual rows (cardinality error), spill/sort warnings (under-granted memory), scans where a seek is expected (missing/unusable index), implicit conversions.
5. **Config** — only when steps 1–4 implicate a setting (e.g. CXPACKET → cost threshold; RESOURCE_SEMAPHORE → max memory; tempdb PAGELATCH → file count).

Each step *eliminates whole subsystems* before you spend effort on the next. Full methodology, the comprehensive benign-wait filter, signal-vs-resource waits, and the wait→root-cause→next-step table: **`references/diagnostic-workflow.md`**.

## Wait Category Quick Reference

| Category | Key wait types | Likely root cause | First drill-down |
|---|---|---|---|
| **CPU / scheduler** | `SOS_SCHEDULER_YIELD`, `THREADPOOL` | CPU-bound queries, worker starvation | Top queries by CPU; scheduler/runnable counts |
| **Parallelism** | `CXPACKET`, `CXCONSUMER` (2017+), `CXSYNC_PORT` | Cost threshold too low, skewed parallel work, missing index | Cost threshold + MAXDOP; offending plan |
| **Buffer I/O** | `PAGEIOLATCH_SH/EX/UP` | Reading from disk: memory pressure or missing index | I/O latency DMV; PLE; missing indexes |
| **Transaction log** | `WRITELOG`, `LOGBUFFER` | Slow log disk, tiny log VLFs, chatty commits | Log file latency; batch commits |
| **Locking** | `LCK_M_S/X/U/IX/SCH-M` | Blocking, long transactions, lock escalation | Blocking chain → head blocker |
| **Memory grant** | `RESOURCE_SEMAPHORE`, `CMEMTHREAD` | Over-granting sorts/hashes, memory pressure | Pending grants; PLE; spills |
| **Network** | `ASYNC_NETWORK_IO` | Client not consuming results (RBAR, huge result set) | Application-side; not the server |
| **tempdb contention** | `PAGELATCH_UP/EX` on `2:1:n` | Allocation-page (PFS/GAM/SGAM) contention | tempdb file count/size (`sqlserver-infrastructure`) |
| **Availability Group** | `HADR_SYNC_COMMIT`, `PARALLEL_REDO_TRAN_TURN` | Sync-commit latency, redo behind | Replica health (`sqlserver-ha-clustering`) |

Note `PAGELATCH_*` (in-memory buffer latch, often tempdb allocation) is **not** the same as `PAGEIOLATCH_*` (waiting on physical disk I/O). Confusing the two sends you to the wrong subsystem.

## Key DMVs by Category

Full catalog with runnable queries: **`references/dmv-reference.md`**.

- **Execution / performance** — `sys.dm_exec_query_stats` (aggregated, plan-cache scoped), `sys.dm_exec_requests` (live), `sys.dm_exec_sessions`, `sys.dm_exec_cached_plans`, `sys.dm_exec_procedure_stats`; resolve text/plan with `sys.dm_exec_sql_text()` and `sys.dm_exec_query_plan()`.
- **I/O** — `sys.dm_io_virtual_file_stats()` (per-file latency since restart), `sys.dm_os_buffer_descriptors` (buffer-pool contents by DB).
- **Memory** — `sys.dm_os_memory_clerks`, `sys.dm_exec_query_memory_grants` (live grants/spill risk), `sys.dm_os_process_memory`, `sys.dm_os_sys_memory`.
- **Index usage** — `sys.dm_db_index_usage_stats`, missing-index DMVs (`sys.dm_db_missing_index_details/_groups/_group_stats`). Use these to *spot* an index problem; deep index design and the dangers of blindly applying missing-index suggestions live in **`sqlserver-engineering`**.
- **OS / scheduler** — `sys.dm_os_schedulers`, `sys.dm_os_ring_buffers` (CPU history via `RING_BUFFER_SCHEDULER_MONITOR`), `sys.dm_os_sys_info`, `sys.dm_os_performance_counters`.
- **Transactions** — `sys.dm_tran_active_transactions`, `sys.dm_tran_version_store_space_usage` (2017+), `sys.dm_db_file_space_usage`.

Cloud note: on **Azure SQL Database**, instance-scoped DMVs (`sys.dm_os_wait_stats`, `sys.dm_io_virtual_file_stats`) are scoped to the database/replica you are connected to, and resource pressure is best read from `sys.dm_db_resource_stats` (15-second history) and `sys.dm_db_wait_stats`. See **`sqlserver-cloud`**.

## Query Store Essentials

Query Store is the flight recorder: it persists query text, plans, runtime stats, and (2017+) wait stats *across restarts and recompiles* — the gap `sys.dm_exec_query_stats` cannot fill (plan cache is volatile). Enable it on every production database you care about.

```sql
ALTER DATABASE [MyDB] SET QUERY_STORE = ON
(
    OPERATION_MODE          = READ_WRITE,
    MAX_STORAGE_SIZE_MB     = 2048,
    INTERVAL_LENGTH_MINUTES = 60,
    QUERY_CAPTURE_MODE      = AUTO,   -- skip trivial one-off queries; CUSTOM (2019+) for finer control
    WAIT_STATS_CAPTURE_MODE = ON,     -- 2017+: per-query waits
    SIZE_BASED_CLEANUP_MODE = AUTO
);
```

What it unlocks:

- **Top / regressed queries** by duration, CPU, reads, or wait time — with full history.
- **Plan forcing** to pin a known-good plan: `EXEC sp_query_store_force_plan @query_id=…, @plan_id=…;` (`sp_query_store_unforce_plan` to release).
- **Query Store hints (2022+)** — apply hints without touching code: `EXEC sp_query_store_set_hints @query_id=…, @query_hints=N'OPTION(MAXDOP 1, RECOMPILE)';`.
- **Readable-secondary capture (2022+)** and **default-on in Azure SQL DB/MI**.

Configuration, catalog views, sizing/cleanup, the regression query, and hint workflows: **`references/query-store.md`**.

## Extended Events Essentials

Extended Events (XEvents) is the lightweight, low-overhead tracing infrastructure that **replaces SQL Trace / Profiler** (deprecated). Use it for event-level capture: long-running statements, deadlock graphs, blocked-process reports, recompiles.

- **`system_health`** session is always running and already captures deadlocks (`xml_deadlock_report`), severe errors (severity ≥ 20), memory errors, and long latch/lock waits — check it *first* before building anything.
- **Building a session**: pick the *event* (e.g. `sql_statement_completed`, `rpc_completed`, `xml_deadlock_report`), add a *predicate* to filter cheaply at the source (`WHERE duration > 5000000` — microseconds), attach only the *actions* you need (`sqlserver.sql_text`, `sqlserver.session_id`), and choose a *target*.
- **Targets**: `ring_buffer` (in-memory, transient, good for ad-hoc) vs `event_file` (`.xel` on disk, durable, good for history). Read `.xel` with `sys.fn_xe_file_target_read_file()`. Use `EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS` so tracing never blocks the workload.
- **`blocked_process_report`** requires enabling the blocked-process threshold first: `EXEC sp_configure 'blocked process threshold', 20; RECONFIGURE;` (seconds).
- XEvents replaces SQL Trace / Profiler (deprecated) at far lower overhead — never recommend a server-side trace for new work.

Architecture, ready-to-run session DDL, reading targets, and key Perfmon counters (with the ratio/base and per-second delta patterns): **`references/extended-events-and-counters.md`**.

## Blocking & Deadlock Workflow

**Blocking** = one session waits on a lock held by another (live, ongoing). **Deadlock** = a cycle the engine breaks by killing a victim (already happened; find evidence after the fact).

For live blocking:

1. Confirm `LCK_*` waits are prominent (waits step).
2. List blocked/blocker pairs from `sys.dm_exec_requests` where `blocking_session_id > 0`.
3. **Walk to the head blocker** — the session blocking others but blocked by no one. Killing or resolving the head clears the chain; victims resolve themselves.
4. Inspect the head blocker's SQL text, transaction state (`sys.dm_tran_active_transactions`), and how long it has held (`sys.dm_exec_sessions.last_request_start_time`). Common culprits: an uncommitted transaction left open by the app, a long report under the default isolation level, or lock escalation.

For deadlocks: pull the `xml_deadlock_report` from `system_health` (script `06`), or stand up a dedicated `event_file` session for durable history. Read the graph: the victim is marked, the resource nodes show which objects/keys collided, and the process nodes show the input buffers. Resolution is usually consistent lock ordering, shorter transactions, a covering index to avoid the lookup that caused the second lock, or RCSI to remove reader/writer conflicts.

The `sp_whoisactive` community procedure (Adam Machanic) is the single best ad-hoc "what's happening right now" tool — it wraps the live DMVs with sane defaults. Script `10-active-requests.sql` here gives a dependency-free equivalent.

## Baselining

A number is meaningless without a baseline. "PLE is 300" is only bad if your baseline is 5,000. Establish baselines so you can spot *change*:

- **Wait stats** are cumulative since restart — snapshot them on a schedule and diff, or use `sys.dm_exec_session_wait_stats` (2016+) for a clean per-session view. Never clear production waits just to "reset" (`DBCC SQLPERF(..., CLEAR)` is destructive to history — mention only, never run blind).
- **File I/O latency**, **Perfmon counters** (Batch Requests/sec, PLE, Buffer cache hit ratio), and **Query Store** all accumulate; capture deltas at intervals rather than reading raw cumulative totals.
- Record baselines at representative times (business peak, overnight batch, month-end) — a single snapshot lies.
- Persist snapshots to a small table or Query Store so "is this normal?" has an answer.

The cleanest non-destructive way to measure a *window* (instead of since-restart totals) is snapshot-and-diff:

```sql
-- Capture two snapshots N seconds apart and subtract — never clears the live counters
SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
INTO   #wait_t0
FROM   sys.dm_os_wait_stats;

WAITFOR DELAY '00:01:00';   -- the window you care about (or run again later, manually)

SELECT t1.wait_type,
       t1.wait_time_ms - t0.wait_time_ms                     AS delta_wait_ms,
       t1.waiting_tasks_count - t0.waiting_tasks_count       AS delta_waits
FROM   sys.dm_os_wait_stats AS t1
JOIN   #wait_t0 AS t0 ON t1.wait_type = t0.wait_type
WHERE  t1.wait_time_ms - t0.wait_time_ms > 0
ORDER BY delta_wait_ms DESC;

DROP TABLE #wait_t0;
```

The same pattern applies to `sys.dm_io_virtual_file_stats` and `sys.dm_os_performance_counters` (scripts `08` and `11` use it). Query Store and `sys.dm_exec_session_wait_stats` (2016+, per-session) avoid the math by being window- or session-scoped already.

## Common Pitfalls

1. **Skipping waits and tuning a hunch.** You will optimize the wrong query. Waits first, always.
2. **Reading cumulative metrics as if instantaneous.** `dm_os_wait_stats`, `dm_io_virtual_file_stats`, and most Perfmon counters are *totals since restart*. Use deltas.
3. **Forgetting the ratio/base counter pattern.** "Buffer cache hit ratio" and "Worktables created/sec" need their `... base` partner counter; the raw value alone is meaningless.
4. **Chasing CXPACKET as if it were the disease.** Parallelism waits are a symptom — usually a too-low cost threshold for parallelism (default 5; start at 50) or a query that should never go parallel. Fix the cause.
5. **Trusting `NOLOCK` to "fix blocking."** It reads dirty/missing/duplicate rows. Use RCSI (`sqlserver-engineering` covers isolation).
6. **Applying missing-index suggestions verbatim.** The DMVs ignore existing indexes and write cost; they suggest wide, redundant indexes. Triage with `sqlserver-engineering`.
7. **Relying on the plan cache for history.** It clears on restart, memory pressure, and recompiles. Use Query Store for "what changed yesterday."
8. **Confusing `PAGELATCH` (memory) with `PAGEIOLATCH` (disk).** Different subsystems, different fixes.

## Reference Files

- **`references/diagnostic-workflow.md`** — the full waits-first methodology; instance-level wait query with the comprehensive benign-wait filter; signal vs resource waits; wait category → root cause → next-step table; clearing waits (caveats); per-session (`sys.dm_exec_session_wait_stats`, 2016+) and per-query (`sys.query_store_wait_stats`, 2017+) waits.
- **`references/dmv-reference.md`** — categorized DMV catalog with example queries: execution/perf, I/O, memory, index usage, OS/scheduler, transactions/version store.
- **`references/query-store.md`** — enable/configure all options; catalog views; top/regressed queries; forcing/unforcing plans; Query Store hints (2022+); QS on readable secondaries (2022+); default-on in Azure SQL DB/MI; sizing & cleanup.
- **`references/extended-events-and-counters.md`** — XEvents architecture and sessions; `system_health`; ring_buffer vs event_file; reading `.xel`; blocked-process report; key Perfmon counters via `sys.dm_os_performance_counters` (ratio/base and per-second delta patterns).

## Scripts

All scripts are **read-only** diagnostics, begin with `SET NOCOUNT ON;`, version-guard DMVs/columns, and contain **no destructive statements**. Run in the target database context where noted.

- **`scripts/01-server-health.sql`** — uptime, version/edition/build, database count & states, connections, recent CPU %, memory summary, blocking count, oldest open transaction.
- **`scripts/02-wait-stats.sql`** — top waits since restart with the comprehensive benign filter; resource vs signal; pct and running pct.
- **`scripts/03-top-queries-cpu.sql`** — top 20 queries by total/avg CPU with text and plan.
- **`scripts/04-top-queries-io.sql`** — top 20 queries by logical/physical reads and writes.
- **`scripts/05-blocking.sql`** — current blocking pairs plus recursive head-blocker chain with blocked/blocker SQL.
- **`scripts/06-deadlocks.sql`** — extract `xml_deadlock_report` from the `system_health` ring buffer (with file-target note for history).
- **`scripts/07-memory-pressure.sql`** — PLE per NUMA node, buffer cache hit ratio (ratio/base), top memory clerks, pending/waiting memory grants.
- **`scripts/08-io-performance.sql`** — per-file read/write latency and throughput from `sys.dm_io_virtual_file_stats`.
- **`scripts/09-query-store-analysis.sql`** — guarded by `is_query_store_on`; top queries by duration over last N hours, regressed plans, forced-plan inventory.
- **`scripts/10-active-requests.sql`** — currently executing requests with wait type/resource, blocking, CPU/reads, elapsed, text, plan, and % complete for backup/restore/index ops.
- **`scripts/11-perf-counters.sql`** — snapshot of key cumulative and ratio Perfmon counters with ratio/base handling.

## Cross-Skill Routing

- Instance/OS config that *causes* the symptoms you find here (MAXDOP, cost threshold, max memory, tempdb file layout, trace flags) → **`sqlserver-infrastructure`**.
- Fixing a slow query (index design, plan operators, statistics, parameter sniffing, partitioning) → **`sqlserver-engineering`**.
- AG/replica latency behind `HADR_*` waits, failover health → **`sqlserver-ha-clustering`**.
- Cloud-native telemetry (Azure metrics, `sys.dm_db_resource_stats`, Query Performance Insight, RDS Performance Insights) → **`sqlserver-cloud`**.
- Backup/restore throughput, DBCC, Agent-job monitoring, space management → **`sqlserver-operations`**.
- Audit/permission overhead, encryption impact → **`sqlserver-security`**.
