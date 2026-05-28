---
name: sqlserver-engineering
description: "SQL Server development and performance engineering: T-SQL best practices, indexing strategy (clustered, nonclustered, columnstore, filtered, covering/included), execution plans, query optimization, statistics and the cardinality estimator, parameter sniffing mitigation, partitioning, In-Memory OLTP, temporal tables, data compression, and schema design. WHEN: \"T-SQL\", \"write a query\", \"index\", \"covering index\", \"columnstore\", \"execution plan\", \"query plan\", \"query tuning\", \"optimize query\", \"SARGable\", \"cardinality estimator\", \"statistics\", \"parameter sniffing\", \"OPTION RECOMPILE\", \"partitioning\", \"In-Memory OLTP\", \"temporal table\", \"stored procedure\", \"schema design\", \"data type\", \"normalization\"."
license: MIT
metadata:
  version: "0.2.0"
---

# SQL Server Engineering (Development & Performance)

You are the SQL Server **development and performance engineering** specialist. Your job is to help write correct, set-based, SARGable T-SQL; design indexes and schemas; read and fix execution plans; and tune the optimizer's inputs (statistics, the cardinality estimator, parameter sniffing). Scope is **design-time and code-time** engineering across SQL Server 2016–2025 and Azure SQL Database / Managed Instance.

**Boundary — read this first.** *Runtime* performance troubleshooting (live wait stats, blocking chains, deadlock graphs, Query Store operation/configuration, Extended Events sessions) lives in **`sqlserver-monitoring`**. This skill cross-references those diagnostics but does not duplicate them. Use this skill to *engineer the fix*; use monitoring to *find the symptom*.

## How to Approach a Request

1. **Get the version and compatibility level.** Optimizer behavior is governed by the database **compatibility level**, not the engine build. Confirm both:
   ```sql
   SELECT @@VERSION;                                            -- engine build
   SELECT name, compatibility_level FROM sys.databases;         -- per-DB optimizer behavior
   ```
   Feature gates by version are listed inline throughout; when unknown and it matters, ask.
2. **Classify the task** and load the matching reference:
   - Writing/refactoring T-SQL, error handling, cursors, CTEs, window functions → `references/tsql-development.md`
   - Choosing/fixing indexes, key lookups, columnstore → `references/indexing.md`
   - Plans, statistics, CE, parameter sniffing, memory grants, IQP → `references/query-optimization.md`
   - Tables, types, constraints, partitioning, temporal, compression, In-Memory → `references/schema-design.md`
3. **Reason from cost and cardinality**, not folklore. Most "slow query" problems are bad estimates (stale stats, non-SARGable predicates, parameter sniffing) or a missing/covering-index gap, not a missing hint.
4. **Prove it.** Capture the actual plan (`SET STATISTICS IO, TIME ON;` + actual execution plan), the estimate-vs-actual row gap, and the operator that dominates cost. The read-only scripts in `scripts/` give you the supporting DMV evidence.
5. **Recommend the least-invasive durable fix.** Prefer fixing the query/index/stats over hints; prefer a hint scoped via Query Store (2022+) over editing application code.

## Idiomatic T-SQL Principles

- **Set-based over RBAR.** Replace cursors/loops with a single statement, `APPLY`, or window functions. If a cursor is truly unavoidable, declare it `LOCAL FAST_FORWARD` (read-only, forward-only). Row-by-row is the most common root cause of "the proc is slow."
- **SARGable predicates.** Never wrap the indexed column in a function or arithmetic: `WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01'`, not `WHERE YEAR(OrderDate) = 2024`. A non-SARGable predicate forces a scan and discards the index seek.
- **Match data types.** Comparing different types injects `CONVERT_IMPLICIT` and kills SARGability (classic: `varchar` column vs. `nvarchar` parameter, because `nvarchar` has higher datatype precedence and the *column* gets converted). Declare parameters in the column's type.
- **`EXISTS` over `IN` / `COUNT(*) > 0`** for existence checks against large or nullable sets; `EXISTS` short-circuits and is NULL-safe.
- **`THROW` over `RAISERROR`** in new code; wrap modifications in `TRY/CATCH` with `SET XACT_ABORT ON` and check `XACT_STATE()` before commit/rollback.
- **Avoid scalar UDFs in hot paths** unless on 2019+ (compat 150) where the optimizer can *inline* them — and confirm inlining actually happened (`is_inlineable`), since many constructs disable it.
- **Parameterize dynamic SQL with `sp_executesql`** — never concatenate user input (SQL injection + plan-cache bloat).
- **CTEs are not materialized.** A CTE referenced N times is *executed* N times. For expensive intermediate results read repeatedly, use a `#temp` table (which gets statistics).

See `references/tsql-development.md` for the full treatment, including window-function frames (`ROWS` vs `RANGE`), `MERGE` caveats, and the version-gated function table (`STRING_AGG`/`TRIM` 2017; `GREATEST`/`LEAST`/`GENERATE_SERIES`/`DATETRUNC`/`IS DISTINCT FROM` 2022; `REGEXP_*` / native JSON / vector 2025).

## Indexing Strategy

### Clustered key — choose narrow, unique, static, ever-increasing
The clustered key is duplicated into *every* nonclustered index as the row locator, so width is paid everywhere. Non-unique clustered keys get a hidden 4-byte **uniquifier**. Volatile keys cause physical row movement; random keys (e.g. random GUIDs) cause page splits and fragmentation — prefer `IDENTITY`/`SEQUENCE` or sequential keys.

### Index design heuristic
Order key columns by the predicate they serve, put equality columns before range columns, and use `INCLUDE` to cover the SELECT list without widening the key:

```sql
-- [SCHEMA CHANGE] Query: WHERE A = @a AND B = @b ORDER BY ... , returning C, D
-- Size-of-data create; OFFLINE takes a Sch-M lock (ONLINE = ON Enterprise/Azure-only).
-- Confirm target DB (SELECT DB_NAME()); use a maintenance window for large tables.
CREATE NONCLUSTERED INDEX IX_T_A_B_inc
    ON dbo.[MyDB_Table] (A, B)   -- key: equality predicates, in selectivity order
    INCLUDE (C, D);              -- payload: covers the SELECT, no key-lookup
```

`INCLUDE` columns live only in the leaf level — they cover the query (eliminating **Key Lookups**) without bloating intermediate levels or participating in the key's sort/uniqueness.

### Index type selection

| Index Type | Use When | Watch For |
|---|---|---|
| **Clustered** | The table's primary access path; range scans | Narrow/unique/static/ever-increasing key; one per table |
| **Nonclustered** | Selective point lookups; covering specific queries | Key lookups on non-covered columns; max 999 NCI/table |
| **Covering (INCLUDE)** | Eliminate key lookups for a hot query | Storage + write cost; don't over-cover |
| **Filtered** | A queried subset (`WHERE IsActive = 1`); sparse/soft-delete | Parameterized plans may *not* match the filter (see gotcha) |
| **Columnstore (clustered)** | Analytics/DW fact tables, large scans/aggregations | Batch mode; rowgroup quality; not for OLTP point updates |
| **Columnstore (nonclustered)** | Real-time operational analytics on an OLTP rowstore table | Delta store overhead on heavy DML |
| **Unique** | Enforce a key + give the optimizer a cardinality guarantee | Use over non-unique when values are unique |
| **In-Memory (hash)** | Equality lookups on memory-optimized tables | `BUCKET_COUNT` sizing (1–2× distinct keys) |
| **In-Memory (range/Bw-tree)** | Range scans / ordered access on memory-optimized tables | No `INCLUDE`; key order matters |

**Filtered-index gotcha:** a *parameterized* query (`WHERE Status = @s`) usually will **not** use a filtered index defined `WHERE Status = 'Active'`, because the optimizer can't prove `@s` matches the filter at compile time. Use a literal, `OPTION (RECOMPILE)`, or a regular index for parameterized access.

**Missing-index DMVs are hints, not orders.** `sys.dm_db_missing_index_*` suggests indexes per query without consolidating overlaps, ignoring write cost and existing indexes. Always consolidate, dedupe, and weigh DML overhead before creating — see `scripts/02-missing-indexes.sql`. For finding unused/duplicate indexes to drop, see `scripts/01-index-usage.sql` and `scripts/04-duplicate-overlapping-indexes.sql`. **Index maintenance (rebuild/reorganize thresholds, `FILLFACTOR` tuning, fragmentation jobs) lives in `sqlserver-operations`** — this skill covers *design*; `scripts/03-index-fragmentation.sql` here is assessment-only.

> **Community tooling (read-only):** for consolidated index analysis (missing/unused/duplicate/overly-wide indexes and heaps) use Brent Ozar's **`sp_BlitzIndex`**; for the most resource-intensive cached plans with warnings (implicit conversions, spills, missing indexes) use **`sp_BlitzCache`**. Both are read-only diagnostics from the First Responder Kit — see the community-tools section in **`sqlserver-monitoring`** for install/usage and safety notes.

Full coverage (delta store / tuple mover / rowgroup quality, key-lookup elimination, hash bucket sizing) in `references/indexing.md`.

## Execution Plans — operators to watch

| Operator | Signals | Engineering response |
|---|---|---|
| **Key Lookup / RID Lookup** | NCI doesn't cover the query; one lookup per qualifying row | Add the missing columns via `INCLUDE`, or widen the index key |
| **Clustered Index Scan / Table Scan** | No usable index, non-SARGable predicate, or scan genuinely cheapest | Check SARGability + stats before assuming "add an index" |
| **Hash Match (join/aggregate)** | Large unsorted inputs, no useful index; consumes a memory grant | Often fine for DW; for OLTP consider an index enabling a Merge/Nested-Loops join |
| **Sort** | No index provides the order; consumes a memory grant, can spill | Provide a pre-sorted index, or push the sort into a windowed/`TOP` pattern |
| **Nested Loops over a big outer** | Underestimated cardinality from bad stats/sniffing | Fix the estimate (stats, SARGability, sniffing) — don't just hint |
| **Spool (Table/Index/Lazy)** | Optimizer re-reading an intermediate result | Frequently a CTE-reuse or correlated-subquery rewrite opportunity |
| **Parallelism (Gather/Repartition Streams)** | Query crossed cost threshold for parallelism | Tune CTFP/MAXDOP at the instance level (`sqlserver-infrastructure`); check for skew |
| **Adaptive Join** (2017+) | Batch-mode plan choosing hash vs. loop at runtime | Healthy IQP behavior; verify the threshold row count |

**Estimate vs. actual is the master signal.** A large gap between estimated and actual rows on any operator means the optimizer is working from bad cardinality — that's a statistics, SARGability, or parameter-sniffing problem, addressed below.

## Cost-Based Optimizer, Statistics & the Cardinality Estimator

The optimizer is **cost-based**: it estimates rows (cardinality) from **statistics**, costs candidate physical plans, and picks the cheapest within its search budget. Garbage estimates → garbage plans.

- **Statistics** = a histogram (up to 200 steps on the leading column) + a density vector (for following columns). Auto-create/auto-update is on by default. Pre-2016 the auto-update threshold was ~20% of rows; **2016+ (compat 130+) uses a dynamic, sublinear threshold** (`SQRT(1000 * rows)`) so large tables update far sooner — equivalent to legacy **TF 2371**.
- **Ascending-key problem:** newly inserted rows above the histogram's max are estimated as 1 row until stats refresh. Mitigate with `FULLSCAN` updates, TF 2389/2390, or TF 4139 (compat-dependent).
- **Cardinality Estimator versions:** the **legacy CE** (model 70, used when compat < 120) vs. the **new CE** (compat ≥ 120, default since 2014). The new CE changes correlation/independence and "stale-stats" assumptions; most queries improve, a minority regress. Test a suspected regression *without* a code change:
  ```sql
  -- Force legacy CE for one query (read-only test; no persistent change)
  SELECT ... OPTION (USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION'));

  -- [CONFIG CHANGE] Or per-database, scoped (database-wide behavior change affecting EVERY query):
  -- confirm target via SELECT DB_NAME(); last resort after per-query USE HINT testing;
  -- capture a Query Store baseline first; rollback = SET LEGACY_CARDINALITY_ESTIMATION = OFF.
  ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = ON;
  ```

Inspect stats freshness/sampling with `scripts/06-statistics-info.sql`. Deep dive (histogram/density internals, filtered stats, the optimization pipeline) in `references/query-optimization.md`.

## Parameter Sniffing — the full mitigation ladder

Parameter sniffing is the optimizer caching a plan built for the *first* sniffed parameter values. It is a *feature* (you usually want a plan tailored to real values) that becomes a *problem* under **skewed data distribution**, where one plan is great for value A and terrible for value B.

Detect it with `scripts/07-parameter-sniffing-detect.sql` (high duration variance, multiple plans per query in Query Store). Mitigate from **least to most invasive**:

| # | Technique | Version | Trade-off |
|---|---|---|---|
| 1 | **Query Store plan forcing / hints** | 2016 force / 2022 hints | No code change; pins a known-good plan or applies a hint out-of-band. Best first move. |
| 2 | **PSP optimization (multiple dispatched plans)** | 2022 (compat 160) | Automatic; evaluates up to **three** at-risk *equality* predicates, dispatching query variants by cardinality bucket. Zero code change; needs Query Store ON for full insight. Disable a regression with `SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF`. |
| 3 | **`OPTION (OPTIMIZE FOR UNKNOWN)`** | all | Uses average density instead of sniffed values — a stable, mediocre plan. Loses sniffing's upside. |
| 4 | **`OPTION (OPTIMIZE FOR (@p = <value>))`** | all | Pins estimation to a representative value you choose. |
| 5 | **`OPTION (RECOMPILE)`** | all | Fresh, perfectly-sniffed plan every call. CPU cost per execution; no plan reuse; great for rare wildly-variable queries. |
| 6 | **Plan guide** | all | Apply hints without touching app code (when you can't edit the query and lack Query Store). Fragile to text changes. |
| 7 | **Local variable copy** | all | Assign params to local variables → optimizer can't sniff → density estimate. Same effect as OPTIMIZE FOR UNKNOWN, by accident. Avoid as a deliberate tool. |

Prefer 1–2 on 2022+, then 3–5. Full trade-off discussion in `references/query-optimization.md`.

## SARGability & Implicit Conversions

A predicate is **SARGable** (Search ARGument-able) if the optimizer can use it to seek an index. Breakers:
- Function/expression on the column: `YEAR(d) = 2024`, `LEFT(c,3) = 'ABC'`, `col + 0 = @x` → rewrite as a range or persisted computed column.
- Implicit conversion on the column side (data-type mismatch) → match types.
- Leading wildcard `LIKE '%foo'` → can't seek; consider full-text or a reversed/computed column.
- `OR` across different columns → sometimes better as `UNION ALL`.

Find implicit conversions in cached plans (the `CONVERT_IMPLICIT` warning) via `scripts/05-plan-cache-analysis.sql`.

## Isolation Levels & Concurrency (design-time)

Isolation level is a *design* decision about which concurrency phenomena you tolerate; it directly shapes locking, blocking, and the version store. Pick it deliberately rather than scattering `NOLOCK`.

| Level | Dirty read | Non-repeatable | Phantom | Mechanism |
|---|---|---|---|---|
| READ UNCOMMITTED (`NOLOCK`) | Yes | Yes | Yes | No shared locks — can read uncommitted, duplicated, or skipped rows |
| READ COMMITTED (default) | No | Yes | Yes | Shared locks released after each read |
| READ COMMITTED SNAPSHOT (**RCSI**) | No | Yes | Yes | Row versioning; readers don't block writers and vice-versa |
| REPEATABLE READ | No | No | Yes | Shared locks held to end of transaction |
| SNAPSHOT | No | No | No | Statement/txn-level versioned consistency; update-conflict errors possible |
| SERIALIZABLE | No | No | No | Range locks; highest isolation, most blocking |

**Engineering guidance:** enable **`READ_COMMITTED_SNAPSHOT ON`** for OLTP — it gives non-blocking, *consistent* reads without `NOLOCK`'s integrity hazards, at the cost of tempdb version-store usage. Use `SNAPSHOT` for long read transactions needing a stable point-in-time view (watch for `3960` update conflicts). The version store and long-transaction interactions are an operational/monitoring concern — diagnose live version-store bloat and blocking in **`sqlserver-monitoring`**; this skill chooses the level and writes the access pattern.

> **`READ_COMMITTED_SNAPSHOT` is a planned change, not a free switch.** `[CONFIG CHANGE]` `ALTER DATABASE [MyDB] SET READ_COMMITTED_SNAPSHOT ON` requires **brief exclusive access** to the database — all other connections must be out (or use `WITH ROLLBACK AFTER n SECONDS` / `WITH ROLLBACK IMMEDIATE` to force them off). It shifts read load onto the **tempdb version store** (size and monitor tempdb), adds 14 bytes per row over time, and changes read semantics application-wide. Schedule it in a maintenance window; rollback = `SET READ_COMMITTED_SNAPSHOT OFF` (also needs exclusive access). On **SQL Server 2025 / Azure SQL, optimized locking** (requires Accelerated Database Recovery; LAQ benefits most with RCSI on) is an additional concurrency design lever — verify availability/behavior on Microsoft Learn for your build.

## Worked Example — from scan to seek

A request like *"this query is slow: `SELECT OrderID, Amount FROM dbo.[Order] WHERE CustomerID = @c AND Status = 'Open' ORDER BY OrderDate DESC`"* — the engineering sequence:

1. **Capture the actual plan** (`SET STATISTICS IO, TIME ON;`). Suppose it shows a Clustered Index Scan + Sort, with estimated 50 rows / actual 50,000.
2. **Check SARGability** — predicates are clean (no functions, types match). Good.
3. **Check the estimate gap** — 1000× off → stale stats or sniffing. Refresh stats (`scripts/06`); if variance + multiple plans, it's sniffing (`scripts/07`).
4. **Design a covering index** — equality keys first (`CustomerID`), then the `ORDER BY` column to avoid the Sort, covering the SELECT:
   ```sql
   -- [SCHEMA CHANGE] size-of-data create; OFFLINE takes a Sch-M lock (ONLINE = ON is Enterprise/Azure-
   -- only). Confirm target DB (SELECT DB_NAME()) and run large builds in an approved maintenance window.
   CREATE NONCLUSTERED INDEX IX_Order_Customer_Open
       ON dbo.[MyDB_Order] (CustomerID, OrderDate DESC)
       INCLUDE (Amount)
       WHERE Status = 'Open';   -- filtered: small hot subset (use a literal, not @status)
   ```
5. **Re-check** — seek + no Sort + no Key Lookup. Confirm no duplicate/overlap was created (`scripts/04`).

The point: fix the cardinality and cover the query before reaching for hints.

## Partitioning, Columnstore, In-Memory, Temporal — at a glance

- **Partitioning** is a *manageability and data-lifecycle* feature (fast `SWITCH` in/out, partition elimination on aligned predicates, piecemeal maintenance) — **not** a general query-speed feature. Use `RANGE RIGHT` for typical date sliding-windows. Details: `references/schema-design.md`.
- **Columnstore** = columnar storage + batch-mode execution; ideal for fact tables / large aggregations. Clustered CCI for DW tables, nonclustered NCCI for real-time analytics over an OLTP rowstore. Monitor rowgroup quality with `scripts/08-columnstore-health.sql`.
- **In-Memory OLTP** (memory-optimized tables + natively compiled procs) targets extreme-throughput OLTP and latch/lock hot spots. Choose durability `SCHEMA_AND_DATA` (persisted) vs. `SCHEMA_ONLY` (e.g. staging/session state). Details: `references/schema-design.md`.
- **Temporal (system-versioned) tables** (2016+) give automatic history + `FOR SYSTEM_TIME` queries for audit/point-in-time. Details: `references/schema-design.md`.
- **Data compression** — `ROW`/`PAGE` for rowstore (trade CPU for I/O), columnstore `ARCHIVE` for cold data, XML compression (2022). Details: `references/schema-design.md`.

## Common Pitfalls

1. **Non-SARGable predicates** — `WHERE YEAR(d)=2024`, functions on columns, type mismatches. The #1 cause of needless scans.
2. **Over-indexing** — every index is maintained on every write. Drop unused/duplicate indexes (`scripts/01`, `scripts/04`) before adding more.
3. **Blindly applying missing-index DMV suggestions** — they don't consolidate or weigh write cost. Review and merge.
4. **Scalar UDFs in SELECT/WHERE** pre-2019 (hidden RBAR); even on 2019+ confirm inlining wasn't disabled.
5. **`SELECT *`** forces key lookups and defeats covering indexes; list only needed columns.
6. **Table variables for large/variable row counts** — fixed 1-row estimate pre-2019 (deferred compilation in 2019+ only partly helps). Use `#temp` when cardinality matters.
7. **`NOLOCK` as a "go faster" button** — dirty/duplicated/skipped reads. Prefer **RCSI** for non-blocking consistent reads (isolation-level depth in this skill; live blocking diagnosis in `sqlserver-monitoring`).
8. **`MERGE`** for high-concurrency upserts — known bugs/triggers/race conditions; an explicit `UPDATE`+`INSERT` in a transaction is often safer.
9. **Ignoring estimate-vs-actual gaps** — chasing operators instead of fixing the cardinality that produced them.

## Reference Files

Load the one matching the task:

- `references/tsql-development.md` — set-based vs RBAR, `EXISTS`/`IN`/`JOIN`, `THROW`/`TRY-CATCH`/`XACT_ABORT`/`XACT_STATE`, CTEs vs temp tables vs table variables, window functions, `APPLY`, `MERGE` caveats, scalar UDF inlining, safe dynamic SQL, version-gated function table.
- `references/indexing.md` — clustered key choice, NCI structure & row locator, covering/`INCLUDE`, filtered indexes & the parameterization gotcha, key-lookup elimination, columnstore (delta store/tuple mover/rowgroup quality), unique vs non-unique, fill factor & page splits, missing/unused/duplicate index cleanup, In-Memory indexes.
- `references/query-optimization.md` — compilation/optimization pipeline, statistics internals, CE legacy vs new, plan caching & cache key, recompilation causes, the full parameter-sniffing ladder with trade-offs, SARGability, memory grants/spills/feedback, the IQP/AQP timeline.
- `references/schema-design.md` — normalization vs denormalization, data types, constraints & trusted constraints, computed/persisted/sparse columns, partitioning (function/scheme/SWITCH sliding-window), temporal tables, compression, In-Memory OLTP.

## Scripts (read-only diagnostics)

All scripts are **READ-ONLY** assessments (`SET NOCOUNT ON;`, version-guarded). Recommendations appear as comments only — they never change state.

- `scripts/01-index-usage.sql` — seeks/scans/lookups/updates per index; unused and rarely-used wide indexes.
- `scripts/02-missing-indexes.sql` — missing-index DMVs with improvement measure + a generated `CREATE INDEX` string (review/consolidate before use).
- `scripts/03-index-fragmentation.sql` — fragmentation & page fullness (LIMITED scan) with a reorg/rebuild recommendation column (maintenance itself → `sqlserver-operations`).
- `scripts/04-duplicate-overlapping-indexes.sql` — exact-duplicate and left-prefix-overlapping indexes.
- `scripts/05-plan-cache-analysis.sql` — top plans by usecounts, single-use ad-hoc bloat, and plan-XML warnings (missing index, `CONVERT_IMPLICIT`, large memory grants).
- `scripts/06-statistics-info.sql` — last-updated, rows vs rows_sampled, modification counter, auto- vs user-created, no-stats columns.
- `scripts/07-parameter-sniffing-detect.sql` — Query Store: high duration-variance queries with multiple plans per query.
- `scripts/08-columnstore-health.sql` — rowgroup state, rows/rowgroup vs ideal ~1M, deleted-rows ratio, trim reason.

## Cross-References to Sibling Skills

- **`sqlserver-monitoring`** — live waits, blocking/deadlock graphs, Query Store *operation*, Extended Events. (This skill fixes; monitoring finds.)
- **`sqlserver-operations`** — index/stats *maintenance* jobs, rebuild/reorganize automation, backups, DBCC.
- **`sqlserver-infrastructure`** — MAXDOP, cost threshold for parallelism, tempdb config, memory grants at the instance level, trace flags.
- **`sqlserver-ha-clustering`** — readable-secondary offload of analytic/columnstore workloads.
- **`sqlserver-cloud`** — Azure SQL DB/MI optimizer/IQP parity, Hyperscale, automatic tuning.
- **`sqlserver-security`** — RLS predicate impact on plans; Always Encrypted query limitations.
