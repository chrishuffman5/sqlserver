# Query Store Reference

Query Store (QS) is SQL Server's built-in query performance flight recorder. It captures query text, every plan the optimizer produced, runtime statistics, and (2017+) wait statistics, persisting them **inside the user database** so they survive restarts, failovers, recompiles, and plan-cache eviction. It is database-scoped (each database has its own store) and is the only reliable source for "what changed yesterday / last week."

Availability: SQL Server 2016+ (box, all editions). **Default ON in Azure SQL Database and Managed Instance.** Capture on **readable secondaries** added in SQL Server 2022. Most useful with `WAIT_STATS_CAPTURE_MODE = ON` (2017+).

---

## Enabling & Configuring

```sql
ALTER DATABASE [MyDB] SET QUERY_STORE = ON
(
    OPERATION_MODE          = READ_WRITE,    -- READ_WRITE (collecting) | READ_ONLY (full/over budget) | OFF
    DATA_FLUSH_INTERVAL_SECONDS = 900,       -- how often in-memory data is hardened to disk
    INTERVAL_LENGTH_MINUTES = 60,            -- runtime-stats aggregation bucket; valid: 1,5,10,15,30,60,1440
    MAX_STORAGE_SIZE_MB     = 2048,          -- size cap; QS flips to READ_ONLY when exceeded
    QUERY_CAPTURE_MODE      = AUTO,          -- ALL | AUTO (skip trivial/infrequent) | NONE | CUSTOM (2019+)
    SIZE_BASED_CLEANUP_MODE = AUTO,          -- auto-purge oldest data as the cap nears
    STALE_QUERY_THRESHOLD_DAYS = 30,         -- time-based retention
    MAX_PLANS_PER_QUERY     = 200,           -- cap plan history per query
    WAIT_STATS_CAPTURE_MODE = ON             -- 2017+: per-query wait categories
);
```

### Option guidance

| Option | Practical guidance |
|---|---|
| `OPERATION_MODE` | `READ_WRITE` in production. If it silently went `READ_ONLY`, it hit `MAX_STORAGE_SIZE_MB` or an error — check `actual_state_desc` below. |
| `INTERVAL_LENGTH_MINUTES` | Smaller = finer time resolution but more storage/rows. 60 is a good default; drop to 15 when chasing intermittent regressions. |
| `MAX_STORAGE_SIZE_MB` | Size to your retention need; 1–2 GB is typical, busy systems more. Too small + `AUTO` cleanup = short history. |
| `QUERY_CAPTURE_MODE` | `AUTO` avoids bloating the store with one-off ad-hoc queries. `CUSTOM` (2019+) lets you set thresholds precisely (below). `ALL` only for short, targeted investigations. |
| `WAIT_STATS_CAPTURE_MODE` | Keep `ON` — per-query waits are one of QS's best features. |
| `SIZE_BASED_CLEANUP_MODE` | Keep `AUTO` so QS never wedges itself into `READ_ONLY` by filling up. |

### CUSTOM capture policy (2019+)

`QUERY_CAPTURE_MODE = CUSTOM` adds a policy that only captures queries crossing thresholds within a window — dramatically reduces noise on high-ad-hoc workloads.

```sql
ALTER DATABASE [MyDB] SET QUERY_STORE = ON
(
    OPERATION_MODE     = READ_WRITE,
    QUERY_CAPTURE_MODE = CUSTOM,
    QUERY_CAPTURE_POLICY =
    (
        STALE_CAPTURE_POLICY_THRESHOLD = 24 HOURS,   -- evaluation window
        EXECUTION_COUNT                = 30,         -- capture once it runs >= 30 times in the window
        TOTAL_COMPILE_CPU_TIME_MS      = 1000,       -- ...or accumulates this much compile CPU
        TOTAL_EXECUTION_CPU_TIME_MS    = 100         -- ...or this much execution CPU
    )
);
```

### Verify state

```sql
SELECT
    actual_state_desc,                 -- should be READ_WRITE
    desired_state_desc,
    readonly_reason,                   -- non-zero explains why it flipped to READ_ONLY
    current_storage_size_mb,
    max_storage_size_mb,
    capture_policy_execution_count,    -- CUSTOM policy values (2019+)
    flush_interval_seconds,
    interval_length_minutes,
    stale_query_threshold_days,
    size_based_cleanup_mode_desc,
    wait_stats_capture_mode_desc       -- 2017+
FROM sys.database_query_store_options;
```

Common `readonly_reason` causes: storage cap reached (size-based cleanup off or undersized), database read-only/in single-user, or QS internal error. Increase `MAX_STORAGE_SIZE_MB` and/or enable `SIZE_BASED_CLEANUP_MODE = AUTO`, then `SET QUERY_STORE CLEAR;` only if you intend to discard history.

---

## Catalog Views

| View | Contents |
|---|---|
| `sys.database_query_store_options` | The configuration & live state shown above |
| `sys.query_store_query` | Query-level metadata: `query_id`, parameterization, context-settings id, compile stats |
| `sys.query_store_query_text` | Distinct query text (`query_sql_text`) |
| `sys.query_store_plan` | Each plan per query: `plan_id`, `query_plan` (XML), `is_forced_plan`, `force_failure_count` |
| `sys.query_store_runtime_stats` | Per-plan, per-interval runtime metrics (duration, CPU, reads, writes, memory, DOP, tempdb) |
| `sys.query_store_runtime_stats_interval` | Time buckets (`start_time`/`end_time`) for the stats above |
| `sys.query_store_wait_stats` (2017+) | Per-plan wait time bucketed into ~24 wait categories |
| `sys.query_context_settings` | SET options / language / etc. that distinguish query variants |

The join backbone is: `query_text → query → plan → runtime_stats → runtime_stats_interval` (and `→ wait_stats` for waits). Times in QS are **UTC**; use `SYSUTCDATETIME()` / `GETUTCDATE()` when filtering intervals.

---

## Top Queries (last N hours)

```sql
DECLARE @hours INT = 24;

SELECT TOP (25)
    q.query_id,
    p.plan_id,
    p.is_forced_plan,
    SUM(rs.count_executions)                            AS executions,
    CAST(SUM(rs.avg_duration   * rs.count_executions) / 1000.0
         / NULLIF(SUM(rs.count_executions),0) AS DECIMAL(18,2)) AS avg_duration_ms,
    CAST(SUM(rs.avg_cpu_time   * rs.count_executions) / 1000.0
         / NULLIF(SUM(rs.count_executions),0) AS DECIMAL(18,2)) AS avg_cpu_ms,
    CAST(SUM(rs.avg_logical_io_reads * rs.count_executions)
         / NULLIF(SUM(rs.count_executions),0) AS BIGINT)        AS avg_logical_reads,
    SUBSTRING(qt.query_sql_text, 1, 200)                AS query_text_snippet
FROM sys.query_store_runtime_stats AS rs
JOIN sys.query_store_runtime_stats_interval AS rsi
     ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan        AS p  ON rs.plan_id = p.plan_id
JOIN sys.query_store_query       AS q  ON p.query_id = q.query_id
JOIN sys.query_store_query_text  AS qt ON q.query_text_id = qt.query_text_id
WHERE rsi.start_time >= DATEADD(HOUR, -@hours, SYSUTCDATETIME())
GROUP BY q.query_id, p.plan_id, p.is_forced_plan, qt.query_sql_text
ORDER BY avg_duration_ms DESC;
```

Swap the `ORDER BY` / aggregate to rank by CPU, reads, or executions depending on the wait category you found in step 1 of the workflow.

---

## Regressed Queries (plan change made it slower)

A regression is a query whose newer plan performs materially worse than an older one. This is the classic "it was fine until the plan flipped" scenario — usually parameter sniffing or a stats update.

```sql
DECLARE @recent_hours  INT = 24;     -- "new" window
DECLARE @history_hours INT = 168;    -- "old" baseline window (7 days)

;WITH recent AS
(
    SELECT p.query_id, rs.plan_id,
           SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions),0) AS avg_dur,
           SUM(rs.count_executions) AS execs
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
    WHERE rsi.start_time >= DATEADD(HOUR, -@recent_hours, SYSUTCDATETIME())
    GROUP BY p.query_id, rs.plan_id
),
hist AS
(
    SELECT p.query_id,
           SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions),0) AS avg_dur
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
    WHERE rsi.start_time >= DATEADD(HOUR, -@history_hours, SYSUTCDATETIME())
      AND rsi.start_time <  DATEADD(HOUR, -@recent_hours,  SYSUTCDATETIME())
    GROUP BY p.query_id
)
SELECT TOP (25)
    r.query_id, r.plan_id,
    CAST(h.avg_dur/1000.0 AS DECIMAL(18,2))             AS old_avg_ms,
    CAST(r.avg_dur/1000.0 AS DECIMAL(18,2))             AS new_avg_ms,
    CAST((r.avg_dur - h.avg_dur) * 100.0 / NULLIF(h.avg_dur,0) AS DECIMAL(10,1)) AS pct_regression,
    r.execs,
    SUBSTRING(qt.query_sql_text,1,200)                  AS query_text_snippet
FROM recent r
JOIN hist  h ON r.query_id = h.query_id
JOIN sys.query_store_query      q  ON r.query_id = q.query_id
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE r.avg_dur > h.avg_dur * 1.5                       -- >=50% slower
  AND h.avg_dur > 1000                                  -- ignore trivially fast queries
ORDER BY pct_regression DESC;
```

When a regression is real and a known-good `plan_id` exists in history, force it (next section). The built-in **Regressed Queries** report in SSMS (under the database's Query Store node) visualizes the same data.

---

## Forcing & Unforcing Plans

Forcing pins a specific plan so the optimizer reuses it regardless of sniffed parameters. It is the fastest mitigation for a plan-flip regression while you work on a real fix (better index, statistics, or query change in `sqlserver-engineering`).

```sql
-- Force plan 7 for query 42
EXEC sp_query_store_force_plan @query_id = 42, @plan_id = 7;

-- Release the forced plan
EXEC sp_query_store_unforce_plan @query_id = 42, @plan_id = 7;
```

Verify and audit forced plans:

```sql
SELECT
    q.query_id, p.plan_id,
    p.is_forced_plan,
    p.force_failure_count,           -- > 0 means the forced plan could not be honored
    p.last_force_failure_reason_desc,
    SUBSTRING(qt.query_sql_text,1,200) AS query_text_snippet
FROM sys.query_store_plan AS p
JOIN sys.query_store_query AS q ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
WHERE p.is_forced_plan = 1
ORDER BY q.query_id;
```

A non-zero `force_failure_count` means the forced plan is no longer valid (e.g. an index it used was dropped) — SQL Server silently falls back to optimizing normally. Investigate and re-force a current plan or remove the force.

---

## Query Store Hints (2022+)

Query Store hints let you attach query hints to a `query_id` **without changing application code** — they survive recompiles and apply wherever that query runs. Ideal when you cannot edit the query (third-party app, ORM-generated SQL).

```sql
-- Apply hints to query 42 (e.g. tame a bad parallel plan / force recompile)
EXEC sp_query_store_set_hints
     @query_id    = 42,
     @query_hints = N'OPTION (MAXDOP 1, RECOMPILE)';

-- Other examples:
--   N'OPTION (OPTIMIZE FOR (@p = 100))'
--   N'OPTION (USE HINT(''DISABLE_PARAMETER_SNIFFING''))'
--   N'OPTION (HASH JOIN)'

-- Inspect existing hints
SELECT query_hint_id, query_id, query_hint_text, source_desc, last_query_hint_failure_reason_desc
FROM sys.query_store_query_hints;

-- Remove the hint
EXEC sp_query_store_clear_hints @query_id = 42;
```

Hints are lower-friction than plan forcing for many problems (you express *intent* rather than pinning a brittle plan). Available SQL Server 2022+ and Azure SQL DB/MI.

---

## Query Store on Readable Secondaries (2022+)

SQL Server 2022 can capture Query Store data for read workloads running on **Always On readable secondary replicas**, so you can diagnose report queries that only ever run on the secondary. It is controlled by a database-scoped configuration, set on the primary:

```sql
-- Run on the primary; replicates to secondaries
ALTER DATABASE SCOPED CONFIGURATION SET QUERY_STORE_FOR_SECONDARY = ON;

-- Verify
SELECT name, value
FROM sys.database_scoped_configurations
WHERE name = 'QUERY_STORE_FOR_SECONDARY';
```

Secondary-captured data is reconciled back to the primary's Query Store. AG/replica health itself is covered in `sqlserver-ha-clustering`.

---

## Cloud Default-On (Azure SQL DB / MI)

Query Store is **on by default** in Azure SQL Database and Azure SQL Managed Instance, and it powers **Query Performance Insight** and automatic plan-correction. Microsoft tunes default options for the service tier, but you can still `ALTER DATABASE ... SET QUERY_STORE` to adjust storage/intervals. **Automatic plan correction** (`ALTER DATABASE ... SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON)`) builds on QS regression detection to auto-force the last good plan — available in Azure by default and in box 2017+. Deep cloud telemetry is in `sqlserver-cloud`.

---

## Sizing & Cleanup

- **Right-size `MAX_STORAGE_SIZE_MB`** to your retention goal. If QS flips to `READ_ONLY`, history collection stops silently — alert on `actual_state_desc <> 'READ_WRITE'`.
- **Keep `SIZE_BASED_CLEANUP_MODE = AUTO`** so QS purges oldest data near the cap instead of wedging.
- **`STALE_QUERY_THRESHOLD_DAYS`** sets time-based retention; pair with size-based cleanup.
- **Use `QUERY_CAPTURE_MODE = AUTO` (or `CUSTOM` on 2019+)** on high-ad-hoc systems to avoid filling the store with one-shot queries.
- Manual maintenance procedures (use deliberately, they discard data):

```sql
-- Purge a single query's data
EXEC sp_query_store_remove_query @query_id = 42;
-- Purge a single plan
EXEC sp_query_store_remove_plan  @plan_id  = 7;
-- Reset runtime stats only (keeps queries/plans)
EXEC sp_query_store_reset_exec_stats @query_id = 42;
-- Clear the entire store (DESTRUCTIVE — discards all QS history)
-- ALTER DATABASE [MyDB] SET QUERY_STORE CLEAR;
```

Storage health quick check:

```sql
SELECT
    CAST(current_storage_size_mb AS DECIMAL(18,2))      AS used_mb,
    max_storage_size_mb,
    CAST(100.0 * current_storage_size_mb
         / NULLIF(max_storage_size_mb,0) AS DECIMAL(5,2)) AS pct_full,
    actual_state_desc, readonly_reason
FROM sys.database_query_store_options;
```
