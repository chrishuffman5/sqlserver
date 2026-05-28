# Query Optimization Reference

How SQL Server compiles, estimates, caches, and adapts query plans — and how to influence each stage. Covers the optimization pipeline, statistics, the cardinality estimator, plan caching/recompilation, the full parameter-sniffing mitigation ladder, SARGability, memory grants, and the Intelligent Query Processing (IQP) timeline for SQL Server 2016–2025 and Azure SQL DB/MI.

---

## 1. The Compilation & Optimization Pipeline

1. **Parse** — T-SQL text → parse tree. Syntax errors caught here. No catalog access yet.
2. **Bind / Algebrize** — resolve names to objects, check types and permissions, normalize the query into a logical operator tree (the "algebrizer tree"). Binding errors (missing column/object) caught here.
3. **Optimize** — turn the logical tree into a physical plan:
   - **Trivial plan** — for queries with exactly one obvious plan (e.g. a single-table `SELECT` with no join/aggregate choice), the optimizer skips cost-based search entirely.
   - **Full (cost-based) optimization** — multi-stage search (search 0/1/2) exploring transformation rules, join orders, and physical operators, costing each via the cardinality model. The optimizer runs against a **time/transformation budget**: complex queries can hit `optimizer timeout` ("good enough plan found" / "time out") and ship a non-optimal plan — a reason to keep queries and schemas simple.
4. **Execute** — the chosen physical plan runs in the **iterator (Volcano/pull) model**: each operator pulls rows from its child via `Open/GetRow/Close`. Row mode pulls one row at a time; **batch mode** pulls ~900-row batches in columnar form (§9).

The output of optimization is a **cached plan** keyed as in §4.

---

## 2. Statistics

Statistics are how the optimizer guesses **cardinality** (row counts). They consist of:
- A **histogram** — up to **200 steps** describing the distribution of the **leading** statistics column (`RANGE_HI_KEY`, `EQ_ROWS`, `RANGE_ROWS`, `DISTINCT_RANGE_ROWS`, `AVG_RANGE_ROWS`). Only the leading column gets a histogram.
- A **density vector** — `1 / distinct values` for each left-based prefix of the key columns; used to estimate equality on non-leading columns and `GROUP BY` cardinality.

Inspect with `DBCC SHOW_STATISTICS('dbo.T', 'stat_name')` or `sys.dm_db_stats_properties` / `sys.dm_db_stats_histogram` (`scripts/06-statistics-info.sql`).

### Auto-create / auto-update
- `AUTO_CREATE_STATISTICS` and `AUTO_UPDATE_STATISTICS` are on by default. Single-column stats are auto-created when a column is used in a predicate without a supporting index.
- **Update threshold:** pre-2016 it was roughly `500 + 20% of rows` changed — far too lazy on big tables. **2016+ (compat 130+) uses a dynamic, sublinear threshold** ≈ `SQRT(1000 × rows)`, so a billion-row table refreshes after far fewer changes. This is the always-on equivalent of legacy **TF 2371**.
- **`AUTO_UPDATE_STATISTICS_ASYNC`** updates stale stats in the background instead of making the triggering query wait — reduces latency spikes but the *triggering* query uses the old stats.

### Sampling, FULLSCAN, filtered stats
- Auto-update uses a **sampled** scan (a small percentage on large tables). For skewed data this can produce a poor histogram. `UPDATE STATISTICS ... WITH FULLSCAN` reads every row for an exact histogram — schedule it for skewed/critical tables (a maintenance task → `sqlserver-operations`).
- Compare `rows` vs `rows_sampled` (and the modification counter) in `scripts/06` to spot under-sampled or stale stats.
- **Filtered statistics** (`CREATE STATISTICS ... WHERE ...`) give a sharper histogram for a subset, helping correlated/skewed predicates.
- **Incremental statistics** (2014+, `WITH INCREMENTAL = ON`) maintain per-partition statistics on a partitioned table and merge them into the table-level histogram, so loading one partition triggers a stats update for *that partition* instead of a full-table rescan. The auto-update threshold is then evaluated per partition — far less work on large partitioned fact tables. Set it at index/stats creation or via `ALTER TABLE ... SET (FILESTREAM... )`/`UPDATE STATISTICS ... WITH RESAMPLE, INCREMENTAL = ON`. (Note: the merged histogram is still capped at 200 steps, and a few features — e.g. some filtered-stats combinations — don't support incremental.)

### The ascending-key problem
On an ever-increasing column (dates, IDENTITY), newly inserted rows sit **above the histogram's max**. Until stats refresh, predicates on the new range estimate **1 row**, producing nested-loop plans that explode at runtime. Mitigations:
- More frequent / `FULLSCAN` updates on the hot table.
- **TF 2389 / 2390** — "ascending key" branding: estimate beyond the histogram using recent insert rate (2390 also handles "unknown" direction).
- **TF 4139** — applies the ascending-key estimate even under the new CE/quick-stats path. Behavior is compat-level dependent; test before standardizing.

---

## 3. The Cardinality Estimator (Legacy vs. New)

The CE turns statistics into row estimates. There are two models:

- **Legacy CE (model 70)** — used when the database **compatibility level < 120**. Conservative independence/containment assumptions tuned over SQL Server 7.0–2012.
- **New CE** — default at **compat ≥ 120** (since SQL Server 2014, refined every release). Different assumptions: e.g. it relaxes the "predicate independence" assumption (uses an *exponential backoff* across multiple predicates instead of pure multiplication) and changes join-containment and ascending-key handling.

Most workloads improve under the new CE; a minority regress (often where the legacy independence assumption happened to match the data). **Test a suspected regression without changing the query first:**

```sql
-- Per-query: force legacy estimation (read-only test; no persistent change)
SELECT ... OPTION (USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION'));
-- Per-query: force the new CE even if the DB is on legacy
SELECT ... OPTION (USE HINT('FORCE_DEFAULT_CARDINALITY_ESTIMATION'));

-- [CONFIG CHANGE] Per-database, scoped — DATABASE-WIDE behavior change affecting EVERY query.
-- Confirm target via SELECT DB_NAME(); a LAST RESORT after per-query USE HINT testing proves the
-- whole workload (not one query) benefits; capture a Query Store baseline FIRST so you can compare.
-- Rollback = SET LEGACY_CARDINALITY_ESTIMATION = OFF.
ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = ON;
```

Prefer `USE HINT` over the old `QUERYTRACEON 9481/2312` trace flags (hints don't need sysadmin and are documented/supported). Decide CE model per workload after measuring, not by superstition.

---

## 4. Plan Caching & the Cache Key

Compiled plans are cached and reused. A reuse requires an **exact** match on the cache key:
- **Query text**, byte-for-byte (whitespace, casing, comments all matter for ad-hoc).
- **SET options** — `ANSI_NULLS`, `QUOTED_IDENTIFIER`, `ARITHABORT`, `CONCAT_NULL_YIELDS_NULL`, etc. *Different SET options → different cached plan.* This is the classic "fast in the app, slow in SSMS (or vice-versa)" cause: SSMS and the app connect with different `ARITHABORT`, get different plans.
- **Database context**, schema version, and (for parameterized statements) the parameterized form.

**Ad-hoc bloat:** non-parameterized ad-hoc queries with embedded literals each cache a distinct single-use plan, wasting plan-cache memory. Mitigations: parameterize via `sp_executesql`, enable **`optimize for ad hoc workloads`** (caches a small stub on first use, full plan only on reuse), or `PARAMETERIZATION FORCED` (aggressive — test). Diagnose with `scripts/05-plan-cache-analysis.sql`.

`objtype` values you'll see: `Adhoc`, `Prepared`, `Proc`, `Trigger`. High `usecounts` = good reuse; a flood of `Adhoc` with `usecounts = 1` = bloat.

---

## 5. Recompilation — Causes & Control

A plan recompiles (re-optimizes mid-batch or on next execution) when:
- **Statistics changed** enough to cross the auto-update threshold (the most common cause).
- **Schema changes** to a referenced object (DDL, adding/dropping an index, constraint).
- **`OPTION (RECOMPILE)`** / `WITH RECOMPILE` was requested.
- **SET-option changes** within the batch, temp-table DDL interleaved with DML, or large temp-table row-count changes.
- Plan was **evicted** (memory pressure) or invalidated (`sp_recompile`, `DBCC FREEPROCCACHE`).

Recompiles cost CPU but produce a fresh, correctly-estimated plan. `OPTION (RECOMPILE)` at the **statement** level is far cheaper than `WITH RECOMPILE` at the **procedure** level (which recompiles the whole proc). Track excessive recompiles via `sys.dm_exec_query_stats` / Query Store and the live diagnostics in **`sqlserver-monitoring`**.

---

## 6. Parameter Sniffing — Full Mitigation Ladder

**What it is:** when a parameterized statement first compiles, the optimizer **sniffs** the actual parameter values and builds a plan optimal *for those values*. The plan is cached and reused for all later values. This is desirable — until **data skew** means one cached plan is great for value A (e.g. a rare country) and catastrophic for value B (e.g. the dominant country). Symptoms: wildly variable duration for "the same query," `max_duration >> avg_duration`, multiple plans recorded in Query Store. Detect with `scripts/07-parameter-sniffing-detect.sql`.

Mitigations, **least to most invasive**:

| # | Technique | Version | How it works / trade-off |
|---|---|---|---|
| 1 | **Query Store plan forcing** | 2016+ | Pin a specific known-good plan to the query out-of-band. Zero code change. Survives recompiles. Verify the forced plan stays valid (forcing can fail if the plan becomes invalid). |
| 1b | **Query Store hints** | 2022+ | Apply a query hint (e.g. `RECOMPILE`, `OPTIMIZE FOR`) to a query *by query_id*, no code change — the modern way to hint third-party/sealed code (`sys.sp_query_store_set_hints`). |
| 2 | **PSP optimization (Parameter-Sensitive Plan)** | 2022 (compat 160) | At compile time the engine evaluates the most at-risk parameterized predicates — **up to three** of them — and builds a *dispatcher plan* that routes runtime values into cardinality **buckets** (low/medium/high), each mapped to its own query variant. Fully automatic; the best first-line fix on 2022+ for the classic skew case. **Equality predicates only**; among multiple eligible predicates on the same table it picks the most skewed (a `UNION`/self-join can surface more). |
| 3 | **`OPTION (OPTIMIZE FOR UNKNOWN)`** | all | Ignore the sniffed value; estimate from **average density**. Produces one stable, mediocre-for-everyone plan. Good when no single plan should win. Loses sniffing's upside. |
| 4 | **`OPTION (OPTIMIZE FOR (@p = <typical value>))`** | all | Compile as if `@p` were the representative value you choose. Good when you know the common case. Bad if the chosen value stops being representative. |
| 5 | **`OPTION (RECOMPILE)`** | all | Recompile every execution with the *actual* values → always the right plan, never reused. Per-call CPU cost; no plan-cache footprint. Ideal for low-frequency, highly variable queries. Also unlocks filtered-index/literal-substitution benefits. |
| 6 | **Plan guide** (`sp_create_plan_guide`) | all | Attach hints/forced plans to a query by text/handle without editing the app — for sealed code when Query Store isn't available. Fragile: breaks on any text change. |
| 7 | **Local-variable copy** | all | Copy params into local variables so the optimizer can't sniff → falls back to density (same effect as OPTIMIZE FOR UNKNOWN). Works, but it's an *accidental* mechanism — prefer the explicit hint so intent is clear. |

**Decision guide:** on 2022+, try Query Store hints/forcing (1/1b) and let PSP (2) handle classic skew; reach for `RECOMPILE` (5) for rare variable queries and `OPTIMIZE FOR UNKNOWN` (3) when you want one stable plan. Avoid plan guides (6) unless you can't change the code and lack Query Store.

**Troubleshooting a PSP regression:** PSP is automatic at compat 160 but can itself pick a bad bucketization. To disable it without dropping compat level:
```sql
-- Per-query: skip PSP for one statement
SELECT ... OPTION (USE HINT('DISABLE_PARAMETER_SENSITIVE_PLAN'));

-- [CONFIG CHANGE] Per-database: turn PSP off database-wide (confirm via SELECT DB_NAME();
-- affects every parameterized query; rollback = SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON).
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF;
```
Note: disabling parameter sniffing (TF 4136 / `PARAMETER_SNIFFING` scoped config / `DISABLE_PARAMETER_SNIFFING`) also disables PSP. PSP, CE feedback, and memory-grant-feedback persistence all rely on **Query Store being ON** to persist their learning, and PSP/CE/DOP feedback are **compatibility-level gated** (see §9).

> **Community tooling (read-only):** to detect parameter-sniffing/skew symptoms across the workload, Brent Ozar's **`sp_BlitzCache`** ranks the most resource-intensive cached plans and flags warnings (implicit conversions, spills, missing indexes). For always-on historical baselining of plan/duration variance, Erik Darling's **PerformanceMonitor** is a continuous collector (an install, not a read-only snapshot). See the community-tools section in **`sqlserver-monitoring`**.

---

## 7. SARGability & Implicit Conversions

A predicate is **SARGable** if the optimizer can use it to **seek** an index (the column is exposed "bare" on one side, comparable to a constant/range). Non-SARGable predicates force scans.

Breakers and rewrites:
- **Function on the column:** `WHERE YEAR(OrderDate)=2024` → `WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01'`.
- **Arithmetic on the column:** `WHERE Price*1.1 > @x` → `WHERE Price > @x/1.1`.
- **Leading wildcard:** `LIKE '%abc'` can't seek (trailing `LIKE 'abc%'` can). Consider full-text search or a persisted reversed-string computed column + index.
- **Implicit conversion (type mismatch):** when two compared expressions differ in type, SQL Server converts the **lower-precedence** side. If that's the *column*, the seek dies. The infamous case: an `nvarchar` parameter compared to a `varchar` column — `nvarchar` outranks `varchar`, so the **column** is wrapped in `CONVERT_IMPLICIT` and the index can't seek. Fix by declaring the parameter in the column's type.
- **`OR` across different columns** can defeat a single index → sometimes rewrite as `UNION ALL` of two SARGable seeks.
- **Mismatched collation** in a join/predicate also injects a convert.

Find implicit conversions by scanning cached-plan XML for `CONVERT_IMPLICIT` (and the yellow-triangle warnings in SSMS) — `scripts/05-plan-cache-analysis.sql`.

---

## 8. Memory Grants, Spills & Feedback

Blocking operators — **Sort**, **Hash Match** (join/aggregate), and exchange — request a **memory grant** *before* execution, sized from the compile-time cardinality estimate × row width.
- **Under-grant** (estimate too low) → the operator **spills** its workspace to **tempdb** (slow, I/O-bound). Visible as a Sort/Hash warning in the actual plan and as `tempdb` usage in Query Store.
- **Over-grant** (estimate too high) → memory is reserved but unused, starving concurrency (other queries wait on `RESOURCE_SEMAPHORE`).

Both are estimate problems — fix stats/SARGability first. **Memory Grant Feedback** (an IQP feature) automatically corrects this across executions:
- **2017 (compat 140):** batch-mode memory grant feedback.
- **2019 (compat 150):** extended to **row mode**.
- **2022 (compat 160):** **percentile-based** feedback (more robust to oscillating workloads) and feedback **persistence** in Query Store (survives restart/eviction).

Live spill/`RESOURCE_SEMAPHORE` diagnosis is in **`sqlserver-monitoring`**; here, fix the cardinality that produced the bad grant.

---

## 9. Intelligent Query Processing (IQP) Timeline

IQP is a family of features that make the engine adapt plans automatically. They're gated by **database compatibility level**, so raising compat is how you opt in.

**Adaptive Query Processing — SQL Server 2017 (compat 140):**
- **Batch-mode adaptive joins** — defer the hash-vs-nested-loops choice to runtime based on actual row count crossing a threshold.
- **Interleaved execution** — for multi-statement TVFs, pause optimization to get the *real* cardinality before finishing the plan (fixes the old fixed-100/1-row TVF guess).
- **Batch-mode memory grant feedback** (see §8).

**Intelligent Query Processing — SQL Server 2019 (compat 150):**
- **Scalar UDF inlining** (FROID) — rewrite qualifying scalar UDFs into the query (see `tsql-development.md` §8).
- **Table-variable deferred compilation** — defer the plan so the table variable's *actual* row count is used instead of the fixed 1-row guess.
- **Batch mode on rowstore** — batch-mode execution for analytic queries on plain rowstore tables (no columnstore required).
- **Row-mode memory grant feedback** and **APPROX_COUNT_DISTINCT**.

**SQL Server 2022 (compat 160):**
- **Parameter-Sensitive Plan (PSP) optimization** — multiple cached plans for a skewed parameter (see §6).
- **Degree-of-Parallelism (DOP) feedback** — adjusts a query's MAXDOP over executions when parallelism isn't helping.
- **Cardinality Estimation (CE) feedback** — learns from misestimates (e.g. correlation/containment assumptions) and applies model corrections via Query Store on later runs.
- **Optimized plan forcing** — speeds recompiles of forced plans by persisting compilation steps.
- **Memory grant feedback** improvements: percentile-based + persisted (see §8).

**SQL Server 2025 (compat 170):** continued IQP refinements (PSP gains DML support, expanded `tempdb`, and better multi-predicate handling) plus engine features — confirm specifics against the target build. **Optimized locking** (a concurrency design lever) holds a single **Transaction-ID (TID) lock** instead of many row/key locks and uses **Lock After Qualification (LAQ)** to take locks only on rows that actually qualify; it requires **Accelerated Database Recovery (ADR)** enabled, is **off by default** on box 2025, and LAQ benefits most with **RCSI** on — verify availability/behavior on Microsoft Learn for your build. Native `vector`/`json` types also arrive in 2025.

**Query Store dependency & compat gating:** several IQP features — **CE feedback, DOP feedback, PSP**, and **memory-grant-feedback persistence** — require Query Store to be **ON** to persist their learning across recompiles/restarts, and each is gated by **database compatibility level** (raising compat is how you opt in). Confirm both before relying on adaptive behavior.

**Azure SQL DB/MI** typically receive IQP features at or before the corresponding box compat level — when in doubt, check the database's compat level and test.

---

## Cross-References
- Indexes that turn scans into seeks and eliminate lookups: `indexing.md`.
- Query patterns (set-based, APPLY, UDF inlining) that feed the optimizer good shapes: `tsql-development.md`.
- Statistics maintenance jobs and `FULLSCAN` scheduling: **`sqlserver-operations`**.
- Live waits (`RESOURCE_SEMAPHORE`, `CXPACKET`), Query Store *operation*, blocking, recompile storms: **`sqlserver-monitoring`**.
- MAXDOP / cost threshold for parallelism / max-server-memory instance settings: **`sqlserver-infrastructure`**.
