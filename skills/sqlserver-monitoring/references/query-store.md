# Query Store Reference

Query Store (QS) is SQL Server's built-in query performance flight recorder. It captures query text, every plan the optimizer produced, runtime statistics, and (2017+) wait statistics, persisting them **inside the user database** so they survive restarts, failovers, recompiles, and plan-cache eviction. It is database-scoped (each database has its own store) and is the only reliable source for "what changed yesterday / last week."

Availability: SQL Server 2016+ (box, all editions). **Default ON in Azure SQL Database and Managed Instance.** Capture on **readable secondaries** added in SQL Server 2022. Most useful with `WAIT_STATS_CAPTURE_MODE = ON` (2017+).

---

## Enabling & Configuring

Enabling or reconfiguring Query Store is a `[CONFIG CHANGE]` (`ALTER DATABASE ... SET QUERY_STORE`). It is low-risk and reversible (`SET QUERY_STORE = OFF`), but confirm the target via `DB_NAME()` first and use a placeholder DB name like `[MyDB]`.

```sql
-- [CONFIG CHANGE] enables/reconfigures Query Store on the named DB. Confirm DB_NAME() first.
-- Reversible: ALTER DATABASE [MyDB] SET QUERY_STORE = OFF;
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
-- [CONFIG CHANGE] Confirm DB_NAME() first; use a placeholder DB name. Reversible via SET QUERY_STORE = OFF.
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

Common `readonly_reason` causes: storage cap reached (size-based cleanup off or undersized), database read-only/in single-user, or QS internal error. Fix it **non-destructively first**: raise `MAX_STORAGE_SIZE_MB` and enable `SIZE_BASED_CLEANUP_MODE = AUTO` (both `[CONFIG CHANGE]`, see the change templates below) so QS resumes `READ_WRITE` without losing history. `SET QUERY_STORE CLEAR` is a **last resort only** — it destroys the very history you are trying to diagnose; see the Change Templates section before considering it.

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

Forcing/unforcing is a `[PERFORMANCE CHANGE]` — it alters how queries plan in production. The actual `sp_query_store_force_plan` / `sp_query_store_unforce_plan` calls are gathered (commented, with the pre-flight) in **[Change Templates](#change-templates-mutating--review-before-running)** below; run them only after confirming the exact `query_id`/`plan_id` from the regression query.

The read-only side — **verify and audit forced plans** — stays here:

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

Applying/clearing a hint is a `[PERFORMANCE CHANGE]`; the `sp_query_store_set_hints` / `sp_query_store_clear_hints` calls live (commented, with pre-flight) in **[Change Templates](#change-templates-mutating--review-before-running)** below. The hint-inspection query is read-only and stays here:

```sql
-- Inspect existing hints (read-only). Capture this BEFORE changing anything (rollback baseline).
SELECT query_hint_id, query_id, query_hint_text, source_desc, last_query_hint_failure_reason_desc
FROM sys.query_store_query_hints;
```

Hints are lower-friction than plan forcing for many problems (you express *intent* rather than pinning a brittle plan). Available SQL Server 2022+ and Azure SQL DB/MI.

---

## Query Store on Readable Secondaries (2022+)

SQL Server 2022 can capture Query Store data for read workloads running on **Always On readable secondary replicas**, so you can diagnose report queries that only ever run on the secondary. It is controlled by a database-scoped configuration, set on the primary:

```sql
-- [CONFIG CHANGE] Run on the primary (confirm DB_NAME()); replicates to secondaries. Reversible: SET ... = OFF.
ALTER DATABASE SCOPED CONFIGURATION SET QUERY_STORE_FOR_SECONDARY = ON;

-- Verify (read-only)
SELECT name, value
FROM sys.database_scoped_configurations
WHERE name = 'QUERY_STORE_FOR_SECONDARY';
```

Secondary-captured data is reconciled back to the primary's Query Store. AG/replica health itself is covered in `sqlserver-ha-clustering`.

---

## Cloud Default-On (Azure SQL DB / MI)

Query Store is **on by default** in Azure SQL Database and Azure SQL Managed Instance, and it powers **Query Performance Insight** and automatic plan-correction. Microsoft tunes default options for the service tier, but you can still `ALTER DATABASE ... SET QUERY_STORE` to adjust storage/intervals (a `[CONFIG CHANGE]`). **Automatic plan correction** (`FORCE_LAST_GOOD_PLAN`) builds on QS regression detection to auto-force the last good plan when a regression is detected (and auto-unforce if it doesn't help):

- **Azure SQL Database / Managed Instance:** `FORCE_LAST_GOOD_PLAN` is **ON by default** (it is part of the inherited Azure automatic-tuning defaults).
- **Box SQL Server (2017+):** it is **opt-in** — you must enable it explicitly per database: `[CONFIG CHANGE]` `ALTER DATABASE [MyDB] SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);` (reversible with `= OFF`; confirm `DB_NAME()` first).

Deep cloud telemetry is in `sqlserver-cloud`.

---

## Sizing & Cleanup

- **Right-size `MAX_STORAGE_SIZE_MB`** to your retention goal. If QS flips to `READ_ONLY`, history collection stops silently — alert on `actual_state_desc <> 'READ_WRITE'`.
- **Keep `SIZE_BASED_CLEANUP_MODE = AUTO`** so QS purges oldest data near the cap instead of wedging.
- **`STALE_QUERY_THRESHOLD_DAYS`** sets time-based retention; pair with size-based cleanup.
- **Use `QUERY_CAPTURE_MODE = AUTO` (or `CUSTOM` on 2019+)** on high-ad-hoc systems to avoid filling the store with one-shot queries.
- Manual purge/reset procedures **discard diagnostic history** — they are gathered (commented, with pre-flight) in **[Change Templates](#change-templates-mutating--review-before-running)** below. Always prefer right-sizing + size-based cleanup over manual purges.

Storage health quick check (read-only):

```sql
SELECT
    CAST(current_storage_size_mb AS DECIMAL(18,2))      AS used_mb,
    max_storage_size_mb,
    CAST(100.0 * current_storage_size_mb
         / NULLIF(max_storage_size_mb,0) AS DECIMAL(5,2)) AS pct_full,
    actual_state_desc, readonly_reason
FROM sys.database_query_store_options;
```

---

## 2022 Query-Intelligence Telemetry in Query Store

SQL Server 2022 (16.x) surfaces several **Intelligent Query Processing (IQP)** feedback features through Query Store, so an engine-driven adaptive change leaves a visible audit trail. This matters during triage: a plan or hint that changed because the *engine* applied feedback is **not** a regression to chase — it is the engine self-correcting.

- **`sys.query_store_plan_feedback` (read-only catalog view)** records query-feedback activity: **CE feedback** (cardinality-estimation model assumptions), **DOP feedback** (degree-of-parallelism tuning), **memory-grant feedback** (persisted grant sizing), and **LAQ** (lock-after-qualification). Each row ties a `plan_id` to a feedback `feature_desc` and a state (e.g. verification in progress vs. persisted). Persistence for CE/DOP/memory-grant feedback is **on by default in 2022**, but only takes effect when Query Store is enabled and `READ_WRITE`. *(Verify the exact column names — `feature_desc`, `feedback_data`, `state_desc` — on Microsoft Learn for your build.)*
- **CE and DOP feedback are implemented as Query Store hints**, so they also appear in `sys.query_store_query_hints` with `source_desc` indicating the engine (e.g. CE feedback) rather than a user. **Memory-grant feedback** persists in `sys.query_store_plan_feedback`. In a plan's XML, a hint sourced from feedback shows `QueryStoreStatementHintSource = 'CE feedback'` (and equivalents).
- **PSP (Parameter-Sensitive Plan) optimization (2022+)** lets a single parameterized query keep **multiple plan variants** behind a *dispatcher* plan, choosing a variant by predicate cardinality at runtime. In Query Store you will see several `plan_id`s for the same `query_id` that are all legitimate — do not "fix" this by force-pinning one variant unless you have confirmed a specific variant regressed.

**Telling engine feedback from a real regression:** before forcing a plan, check whether the change was engine-driven. If `sys.query_store_query_hints.source_desc` shows a feedback source, or the new `plan_id` is a PSP variant, the engine is adapting — give it a few executions to stabilize and watch the regression query, rather than immediately forcing. Force a plan only when a *user* workload genuinely regressed and the engine is not converging.

---

## Change Templates (mutating — review before running)

The procedures below **change production behavior or discard diagnostic history**. They are presented as **commented templates**, not runnable script. Run them only deliberately, after the pre-flight, with the exact IDs confirmed from the read-only queries above.

**Pre-flight (every template here):**

1. **Capture current state first** (rollback baseline): forced-plan inventory — `SELECT query_id, plan_id FROM sys.query_store_plan WHERE is_forced_plan = 1;` — and existing hints — `SELECT * FROM sys.query_store_query_hints;`. Save the output.
2. **Confirm the exact `query_id` / `plan_id`** from the **Regressed Queries** query above (do not reuse the example `42` / `7`).
3. **Confirm the correct database** (`SELECT DB_NAME();`) and pick a **low-risk workload window**.
4. **Define rollback** before you act: unforce the plan, `sp_query_store_clear_hints`, or re-force the last known-good plan.
5. **Monitor afterward**: watch `force_failure_count` / `last_force_failure_reason_desc` (forced plans) and `last_query_hint_failure_reason_desc` (hints); confirm the target query's runtime improved in the next intervals.

```sql
-- [PERFORMANCE CHANGE] Force / unforce a plan. Confirm query_id & plan_id from the regression query first.
-- EXEC sp_query_store_force_plan   @query_id = [CONFIRM_QUERY_ID], @plan_id = [CONFIRM_PLAN_ID];
-- Rollback (release the forced plan):
-- EXEC sp_query_store_unforce_plan @query_id = [CONFIRM_QUERY_ID], @plan_id = [CONFIRM_PLAN_ID];

-- [PERFORMANCE CHANGE] Apply / clear a Query Store hint (2022+). Capture existing hints first (rollback baseline).
-- EXEC sp_query_store_set_hints
--      @query_id    = [CONFIRM_QUERY_ID],
--      @query_hints = N'OPTION (MAXDOP 1, RECOMPILE)';
--   Other shapes: N'OPTION (OPTIMIZE FOR (@p = 100))'
--                 N'OPTION (USE HINT(''DISABLE_PARAMETER_SNIFFING''))'
--                 N'OPTION (HASH JOIN)'
-- Rollback (remove the hint):
-- EXEC sp_query_store_clear_hints @query_id = [CONFIRM_QUERY_ID];

-- [DATA-LOSS RISK] The following DISCARD Query Store diagnostic history and cannot be undone.
-- Prefer right-sizing MAX_STORAGE_SIZE_MB + SIZE_BASED_CLEANUP_MODE = AUTO over manual purges.
-- Purge a single query's data:
-- EXEC sp_query_store_remove_query     @query_id = [CONFIRM_QUERY_ID];
-- Purge a single plan:
-- EXEC sp_query_store_remove_plan      @plan_id  = [CONFIRM_PLAN_ID];
-- Reset runtime stats only (keeps queries/plans, drops their history):
-- EXEC sp_query_store_reset_exec_stats @query_id = [CONFIRM_QUERY_ID];
-- Clear the ENTIRE store (erases ALL QS history for the database) — last resort only:
-- ALTER DATABASE [CONFIRM_DB] SET QUERY_STORE CLEAR;
```
