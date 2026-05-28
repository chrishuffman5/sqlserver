# Recommendation Rule Catalog

The rule library that runs inside DuckDB against the captured data (see `duckdb-analysis.md` for how to load and run it). Each analysis file `a01..a10` emits the **unified findings shape** (`dimension, database_name, object_name, severity, metric, finding, recommendation, why, consult_skill`); `a99` consolidates and prioritizes them.

> **Everything here is ADVISORY.** A capture is a single point-in-time snapshot of DMV/catalog data — it does not know your workload's intent, your maintenance windows, your month-end jobs, or your business SLAs. **Validate every recommendation in a non-production environment before acting.** Remediation T-SQL is *not* the job of this skill: it lives in the deeper skills and follows the plugin **change-class convention** — mutating examples are tagged `[SCHEMA CHANGE]` / `[CONFIG CHANGE]` / `[DATA-LOSS RISK]`, and destructive commands are never inlined as runnable. The collectors that produced the capture are strictly read-only.

**Establish version / edition / platform first.** Read `server_info` (`product_major_version`, `edition`, `engine_edition`) before applying any version-sensitive rule. Feature-gated recommendations (ONLINE rebuilds, columnstore, compression, optimized locking) depend on edition; cloud platforms (Azure SQL DB/MI, AWS RDS, Google Cloud SQL) restrict or omit some DMVs and disallow some remediations (e.g. you don't set instance memory on Azure SQL DB). Note the caveat in the finding when the platform changes the answer.

**Severity is relative, not absolute.** The default thresholds below are starting points tuned for a typical OLTP instance. They are meant to be edited — adjust them for your environment and re-run; nothing touches SQL Server again.

---

## a01 — Table Design (heaps, missing PKs, wide/odd columns)

Reads `tables`, `columns`, `indexes`.

| Rule | Detection (key columns) | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Heap with significant rows** | `tables.is_heap = 1` and `row_count` high | `row_count >= 100,000` | High if `>= 1,000,000` and has nonclustered indexes (NCIs carry RID locators); else Medium | Evaluate a clustered index (narrow, unique, static, ever-increasing key) | Heaps cause forwarded records, full scans, and fat NCI RID locators |
| **Large table, no primary key** | `tables.has_primary_key = 0` and `row_count` high | `row_count >= 10,000` | Medium | Add a PK / enforce entity integrity | No PK → no enforced uniqueness, weak referential model, replication/AG friction |
| **Over-wide table** | many rows in `columns` for one `object_id` | `column_count >= 50` | Low (Medium if also many `nvarchar(max)`/`varchar(max)`) | Review for normalization / vertical partitioning | Wide rows reduce page density and inflate I/O |
| **Suspect data types** | `columns.data_type` heuristics | any of: `text`/`ntext`/`image` (deprecated); `float`/`real` for money; `nvarchar` where `varchar` suffices on ASCII; `(max)` used as a default | Low–Medium | Replace deprecated LOB types with `varchar(max)`/`nvarchar(max)`/`varbinary(max)`; use `decimal` for currency; size strings deliberately | Deprecated types block features; oversized types waste space and break SARGability |
| **GUID clustered key** | join `indexes` (clustered, key includes a `uniqueidentifier` column from `columns`) | clustered key leads with a GUID column | Medium | Consider a sequential surrogate or `NEWSEQUENTIALID()` | Random GUID cluster keys cause page splits + fragmentation and bloat every NCI |

**Caveats.** A heap is fine for tiny lookup/staging tables and some bulk-load patterns — don't blanket-cluster everything. "No PK" may be intentional for staging. Data-type changes are size-of-data `[SCHEMA CHANGE]`s and can break application contracts — verify usage first. `consult_skill = sqlserver-engineering` (schema-design.md / indexing.md).

---

## a02 — Indexing: Unused, Duplicate & Overlapping

Reads `indexes`, `index_usage`.

| Rule | Detection (key columns) | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Unused index with write cost** | `index_usage.user_seeks + user_scans + user_lookups = 0` (or NULL) and `user_updates` high; exclude PK/unique-constraint indexes | reads = 0 and `user_updates >= 1,000` | Medium (High if `user_updates` very high *and* index is wide) | Consider dropping after validating over a full business cycle | Every index is maintained on every write and consumes buffer pool/backup space; zero-read indexes are pure overhead |
| **Rarely-used wide index** | reads low relative to `user_updates`; wide `included_column_list` | reads < `user_updates / 100` | Low | Review necessity / trim INCLUDE columns | Low-value index paying high write cost |
| **Exact-duplicate index** | same `key_column_list` (same order) on same `object_id` | exact match | Medium | Drop the redundant copy (keep the better-covering one) | Duplicates double write cost for zero read benefit |
| **Left-prefix overlap** | one index's `key_column_list` is a leading prefix of another's | prefix match | Low | Consolidate into the wider/more-general index | The prefix index is redundant for most access |
| **Disabled index** | `indexes.is_disabled = 1` | any | Low | Decide: rebuild (re-enable) or drop | A disabled index is dead weight in the catalog and may signal abandoned tuning |

**Caveats — read before recommending a drop.**
- **Usage counters reset on instance restart**, and historically on index rebuild on some versions. A "zero reads" index may simply be young, or feed a **month-end / quarter-end / year-end job** that hasn't run during the capture window. **Confirm over a representative uptime window** (check `server_info.sqlserver_start_time` — short uptime = untrustworthy usage stats) and ideally across multiple captures (trend; see `duckdb-analysis.md`).
- **Never drop** the index backing a `PRIMARY KEY` / `UNIQUE` constraint (`is_primary_key`/`is_unique_constraint = 1`) or a unique index enforcing integrity, and check it isn't the supporting index for a foreign key's joins/cascades.
- A left-prefix index can still be the *better* choice if it's narrower and hotter — consolidation isn't automatic.
- `consult_skill = sqlserver-engineering` (indexing.md §10). Dropping an index is a `[SCHEMA CHANGE]`.

---

## a03 — Indexing: Missing Indexes (consolidated)

Reads `missing_indexes`.

| Rule | Detection (key columns) | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **High-impact missing index** | rank by `improvement_measure` (= `avg_total_user_cost * avg_user_impact/100 * (user_seeks + user_scans)`) | `improvement_measure >= 50,000` *and* `avg_user_impact >= 70` | High | **Consolidate overlapping suggestions for the same table**, then design one curated covering index (equality cols first in selectivity order, fold the rest into INCLUDE), test, and create | The optimizer wished it had this index during compilation; missing it forces scans/lookups |
| **Moderate missing index** | same | `improvement_measure` 10,000–50,000 | Medium | Same consolidate-then-curate workflow | Material but lower-priority gap |
| **Many suggestions, one table** | count of `missing_indexes` rows per `object_id`/table | `>= 5` suggestions on one table | Medium | Triage as a *set* — these are near-duplicates differing by an INCLUDE column | Indicates the table needs an index review, not 5 new indexes |

**Caveats — the DMV suggestions are RAW, not a plan.**
- Missing-index DMVs **never consolidate** overlapping suggestions, **ignore existing indexes**, **ignore write cost**, and don't always order equality-before-inequality correctly. **Never apply them verbatim.** Merge near-duplicates into one index, check it doesn't duplicate an existing index (cross-reference `indexes`), and weigh the DML overhead the new index adds.
- `improvement_measure` is a *ranking* heuristic, not absolute truth.
- Suggestions are also reset on restart and reflect only the workload seen since then.
- `consult_skill = sqlserver-engineering` (indexing.md §9 — "Use, Don't Obey"). Creating an index is a size-of-data `[SCHEMA CHANGE]`; ONLINE rebuild is Enterprise/Azure-gated.

---

## a04 — Indexing: Fragmentation & Page Fullness

Reads `index_physical` (SAMPLED, already filtered to `page_count >= 1000`).

| Rule | Detection (key columns) | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Heavily fragmented large index** | `avg_fragmentation_in_percent` high on a large index | `frag >= 30%` and `page_count >= 1000` | Medium (High if `page_count` very large *and* it's a hot index) | **REBUILD** (consider ONLINE on Enterprise/Azure) | Fragmentation hurts range scans and read-ahead; only matters on disk-bound scans |
| **Moderately fragmented index** | as above | `frag` 10–30% and `page_count >= 1000` | Low | **REORGANIZE** (online, any edition) | Light fragmentation → cheaper reorganize, not a rebuild |
| **Low page density** | `avg_page_space_used_in_percent` low | `< 70%` and `page_count >= 1000` | Low | Review fill factor; rebuild to re-pack | Half-empty pages waste buffer pool and inflate I/O |
| **Forwarded records (heap)** | `forwarded_record_count` high (`index_id = 0`) | `>= 1,000` | Medium | Add a clustered index, or `ALTER TABLE ... REBUILD` the heap | Forwarded records cause extra random reads on every scan |

**Caveats.**
- The classic 5%/30% reorganize/rebuild guidance is a **starting heuristic, widely over-applied**. Fragmentation **only matters for large range scans on disk-bound workloads**; on SSD/NVMe or when the index lives in the buffer pool, it's often irrelevant. **Don't rebuild on a schedule just to hit a number** — and over-aggressive rebuilds churn the transaction log, bloat differential backups, and reset usage stats. Rebuild because a *scan-heavy workload* is slow, not because a percentage crossed a line.
- ONLINE rebuild is **Enterprise/Developer/Eval and Azure SQL DB/MI only**; on Standard, `REBUILD` is OFFLINE (Sch-M lock blocks the table) — default to REORGANIZE or a maintenance window.
- The capture is SAMPLED (LIMITED-equivalent), so `avg_fragmentation_in_percent` is approximate.
- **Maintenance is owned by operations** — `consult_skill = sqlserver-operations`. The *index design* implications (fill factor, key choice) are in `sqlserver-engineering`. Rebuild/reorganize are `[SCHEMA CHANGE]` operations.

---

## a05 — Sizing & Capacity

Reads `tables`, `db_inventory`.

| Rule | Detection (key columns) | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Very large uncompressed table** | `tables.total_space_mb` large and `data_compression_desc IN ('NONE', NULL)` | `total_space_mb >= 102,400` (100 GB) | Medium | Evaluate `ROW`/`PAGE` compression (or columnstore for analytic tables) in non-prod | Compression cuts I/O and buffer-pool footprint at a CPU cost |
| **High unused space** | `tables.unused_space_mb` large relative to `total_space_mb` | `unused_space_mb >= 1,024` and `>= 25%` of total | Low | Investigate (dropped LOB, over-allocation, fragmentation, ghost records) | Allocated-but-unused space wastes storage and backups |
| **Large DB on FULL recovery, log-reuse blocked** | `db_inventory.recovery_model_desc = 'FULL'` and `log_reuse_wait_desc` not `NOTHING`/`CHECKPOINT` | `log_reuse_wait_desc IN ('LOG_BACKUP','ACTIVE_TRANSACTION','AVAILABILITY_REPLICA',...)` | Medium (High if `LOG_BACKUP` and DB is large) | Confirm log backups are running (or the AG/transaction issue) | A blocked log can grow unbounded and stop the database |
| **Capacity trend (multi-capture)** | growth in `total_size_mb` / `total_space_mb` across runs | `pct_growth` per interval above your norm | Medium | Plan storage; revisit data-lifecycle/archival/partitioning | Forecast before you run out of disk |

**Caveats.**
- **Compression has real CPU cost** — `PAGE` more than `ROW`. It's a win on I/O-bound, scan-heavy, or buffer-pressured systems; it can hurt CPU-bound OLTP. Always measure in non-prod with a representative workload; compressing is a size-of-data `[SCHEMA CHANGE]`.
- Unused space has many benign causes (recent large delete, LOB allocation); investigate before reclaiming. `DBCC SHRINK*` is **not** a routine fix — it causes massive fragmentation and is a `[DATA-LOSS RISK]`-adjacent operation owned by operations.
- Trend rules require multiple captures (see `duckdb-analysis.md` §6); a single snapshot can't show growth.
- `consult_skill = sqlserver-operations` (capacity, backup, maintenance); compression *design* and columnstore → `sqlserver-engineering`.

---

## a06 — Statistics

Reads `db_inventory` (auto-stats flags), `tables` (size context). *(Per-statistic freshness — last-updated, rows-sampled — is not in the contract; this rule works at the database-setting level and flags where deeper, live inspection is warranted.)*

| Rule | Detection (key columns) | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Auto-create stats off** | `db_inventory.is_auto_create_stats_on = 0` | off | High | Enable `AUTO_CREATE_STATISTICS` unless a deliberate, documented exception | Without it the optimizer flies blind on un-indexed predicates → bad plans |
| **Auto-update stats off** | `db_inventory.is_auto_update_stats_on = 0` | off | High | Enable `AUTO_UPDATE_STATISTICS` (or prove a managed stats job covers every table) | Stale stats → bad cardinality → bad plans |
| **Async update off on a busy DB** | `is_auto_update_stats_async_on = 0` on a large/hot DB | off and large DB | Low | Consider `AUTO_UPDATE_STATISTICS_ASYNC ON` to avoid compile-time stalls | Sync updates can block the query that triggered them |
| **Large DB likely to suffer stale stats** | big tables in `tables` + manual stats expectations | very large tables present | Low (informational) | Verify a stats-maintenance strategy exists; inspect freshness live | Big tables update stats less often relative to row churn (sublinear threshold) |

**Caveats.**
- **Turning auto-create/auto-update *off* is occasionally deliberate** (e.g. a controlled stats job, or avoiding mid-day auto-update stalls on a huge table). Flag it, don't assume it's a mistake — confirm whether a managed job compensates.
- Per-statistic staleness (histogram age, `rows_sampled` vs `rows`, ascending-key problem) needs a **live** look — point the user to `sqlserver-engineering`'s `scripts/06-statistics-info.sql`. This capture intentionally carries only the database-level switches.
- Enabling/disabling auto-stats is a `[CONFIG CHANGE]` (`ALTER DATABASE ... SET ...`). `consult_skill = sqlserver-engineering` (query-optimization.md — statistics & the CE).

---

## a07 — Query Hotspots

Reads `query_stats` (top ~50 plan-cache queries).

| Rule | Detection (key columns) | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Top CPU consumer (aggregate)** | high `total_worker_time_ms` | top by total worker time | High for the top few | Tune the query/index; inspect the plan live | These dominate instance CPU — the biggest aggregate wins |
| **Expensive per execution** | high `avg_worker_time_ms` or `avg_elapsed_time_ms` | `avg_worker_time_ms >= 1,000` | Medium | Inspect the plan; check SARGability, missing index, sniffing | Individually slow even if infrequent |
| **High logical reads (I/O hog)** | high `total_logical_reads` / `avg_logical_reads` | `avg_logical_reads >= 100,000` | Medium–High | Add covering index / fix scan; correlate with `a03` | Read amplification → buffer pressure and I/O waits |
| **Large memory grant** | high `total_grant_kb` relative to `execution_count` | grant per exec very large | Medium | Check for spills/over-grant; fix cardinality estimate | Over-grants throttle concurrency (`RESOURCE_SEMAPHORE`) |
| **Frequent + cheap-each but heavy total** | very high `execution_count`, modest avg | total cost high via frequency | Medium | Reduce call frequency / batch / cache; or shave per-call cost | Death-by-a-thousand-cuts hotspots |

**Caveats.**
- `query_stats` comes from the **plan cache, which is volatile** — it clears on restart, memory pressure, and recompiles, so it reflects only recently-cached plans and undercounts `OPTION (RECOMPILE)` and one-off ad-hoc queries. It is **not** historical truth — for "what changed yesterday," use **Query Store** (live; see `sqlserver-monitoring`).
- `sample_query_text` is one representative statement for a `query_hash`; parameter values and the actual plan are not in the capture. Inspect the live plan before tuning.
- `total_*_ms` figures are derived from microsecond DMV columns; treat as indicative, not exact.
- Fixing a query (index, plan, sniffing) → `consult_skill = sqlserver-engineering`. Finding *why it's slow right now* (live waits/plan) → `sqlserver-monitoring`.

---

## a08 — Configuration

Reads `config`, `server_info`, `db_inventory`.

| Rule | Detection (key columns) | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Cost threshold for parallelism at default 5** | `config.config_name = 'cost threshold for parallelism'`, `value_in_use = 5` | `= 5` | Medium | Raise (commonly start ~50) and observe | The 1997-era default sends trivial queries parallel → `CXPACKET` |
| **MAXDOP misconfigured** | `config 'max degree of parallelism'` vs `server_info.host_cpu_count` | `= 0` on a many-core box, or > NUMA-node core count | Medium | Set per current guidance for core/NUMA layout | MAXDOP 0 on a big box → runaway parallelism |
| **`max server memory` left at default** | `config 'max server memory (MB)'` near the 2147483647 default | at/near default and box product | High | Cap it below physical RAM, leaving headroom for OS/other | Uncapped SQL Server starves the OS → paging, instability |
| **`optimize for ad hoc workloads` off** | `config 'optimize for ad hoc workloads' = 0` | off | Low | Enable to curb single-use plan-cache bloat | Reduces cache pollution from one-off queries |
| **Legacy / risky settings** | e.g. `priority boost = 1`, `lightweight pooling = 1`, non-default `affinity` | any set | Medium | Review — these are almost always wrong | Known-harmful legacy knobs |
| **RCSI off on OLTP DB** | `db_inventory.is_read_committed_snapshot_on = 0` | off on an OLTP DB | Low–Medium | Evaluate enabling RCSI for non-blocking consistent reads | Removes reader/writer blocking without `NOLOCK` hazards |
| **Old compatibility level** | `db_inventory.compatibility_level` well below engine major | e.g. compat 100/110 on a 2019+ engine | Low | Plan a compat-level uplift with Query Store regression testing | Locks the DB out of modern optimizer/IQP features |
| **Non-`CHECKSUM` page verify** | `db_inventory.page_verify_option_desc <> 'CHECKSUM'` | `NONE`/`TORN_PAGE_DETECTION` | Medium | Set `PAGE_VERIFY CHECKSUM` | Without CHECKSUM, on-disk corruption can go undetected |

**Caveats.**
- **Configuration is platform-specific.** On **Azure SQL Database** you don't set instance memory or MAXDOP the box way (database-scoped settings differ); on **Azure SQL MI / RDS / Cloud SQL** some knobs are managed. Read `server_info.engine_edition` and qualify the finding.
- "Best practice" defaults are **starting points**, not laws — MAXDOP/cost-threshold/memory depend on workload and hardware. Recommend, then *observe* (correlate with `a09` waits).
- Changing compat level or RCSI changes plan shapes / read semantics **database-wide** — capture a Query Store baseline and test; RCSI needs brief exclusive DB access and shifts load to the tempdb version store.
- All of these are `[CONFIG CHANGE]`s. `consult_skill = sqlserver-infrastructure` (instance/memory/MAXDOP/tempdb/trace flags); RCSI/compat-level *design* and isolation semantics → `sqlserver-engineering`.

---

## a09 — Configuration / Waits Context

Reads `wait_stats`, `server_info`.

| Rule | Detection (key columns) | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Dominant wait type** | top `wait_type` by `pct_of_total` | any wait `>= 25%` of total | Medium | Route to the matching subsystem (see table) and confirm live | Points at the bottleneck *class* before you tune anything |
| **High signal-wait ratio** | `SUM(signal_wait_time_ms) / SUM(wait_time_ms)` | `>= 25%` | Medium | CPU pressure — review MAXDOP/cost threshold and top CPU queries (`a07`) | High signal % = threads ready but waiting for a scheduler |
| **tempdb allocation contention** | `PAGELATCH_*` prominent (`2:1:n`) | in top waits | Medium | Review tempdb file count/sizing | Allocation-page contention on tempdb |
| **Memory-grant pressure** | `RESOURCE_SEMAPHORE` prominent | in top waits | Medium | Hunt over-granting queries (`a07` grant rule); review max memory | Queries queuing for memory grants |
| **Short-uptime warning** | `server_info.sqlserver_start_time` recent | uptime < ~1 day | Informational on every wait/usage finding | Treat wait & usage stats as unreliable until uptime is representative | Cumulative DMVs reset on restart |

**Wait → subsystem routing (abbreviated; full table in `sqlserver-monitoring`):** `CXPACKET`/`CXCONSUMER` → cost threshold/MAXDOP (infra); `PAGEIOLATCH_*` → I/O / memory / missing index (monitoring + engineering); `WRITELOG` → log disk (infra/ops); `LCK_*` → blocking (monitoring); `RESOURCE_SEMAPHORE` → memory grants (engineering/infra); `ASYNC_NETWORK_IO` → client-side, not the server.

**Caveats.**
- `wait_stats` is **cumulative since restart** — a one-shot capture is a since-startup average, not a window. It tells you the *dominant class*, not what's happening *right now*. For a true window or live view, use the snapshot-and-diff / per-session waits in **`sqlserver-monitoring`**.
- Don't chase `CXPACKET` as a disease — it's a symptom (usually low cost threshold).
- `PAGELATCH_*` (in-memory latch) is **not** `PAGEIOLATCH_*` (disk I/O) — different subsystems.
- `consult_skill = sqlserver-monitoring` for the live drill-down; the config *fix* routes to `sqlserver-infrastructure`.

---

## a10 — Table Design: Foreign Keys & Referential Integrity

Reads `foreign_keys`, `tables`, `indexes`.

| Rule | Detection (key columns) | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Untrusted foreign key** | `foreign_keys.is_not_trusted = 1` (and not disabled) | any | Medium | `WITH CHECK CHECK CONSTRAINT` to re-validate | An untrusted FK can't be used by the optimizer for join elimination/cardinality and may hide integrity violations |
| **Disabled foreign key** | `foreign_keys.is_disabled = 1` | any | Medium (High if a large child table) | Decide: re-enable (with check) or document the exception | A disabled FK enforces nothing — orphan rows can accumulate |
| **Unindexed FK column** | FK `parent_column_list` not matched by a leading index key in `indexes` | no supporting index | Low–Medium | Add an index on the FK column(s) | Unindexed FKs cause scans on joins and slow/escalating-lock cascading deletes |
| **Cascading actions on large tables** | `delete/update_referential_action_desc <> 'NO_ACTION'` on big child tables | `CASCADE`/`SET NULL`/`SET DEFAULT` on a large table | Low | Review the blast radius of cascades | Cascades can fan out into large, lock-heavy modifications |

**Caveats.**
- Re-validating an untrusted FK (`WITH CHECK`) **scans the child table** to verify every row — a size-of-data operation; schedule it. It's a `[SCHEMA CHANGE]`.
- An "unindexed FK" is only worth indexing if the FK column is actually joined/filtered or the parent sees deletes/updates — don't add indexes reflexively (see `a02` over-indexing).
- FKs may be intentionally `NOCHECK` during bulk loads/migrations — confirm it's not transient.
- `consult_skill = sqlserver-engineering` (schema-design.md — constraints & trusted constraints; indexing.md for the supporting index).

---

## How a99 Prioritizes

`a99` `UNION ALL`s all rule outputs and orders **High → Medium → Low**, then by dimension and object. The intent is a single, skimmable, *explained* worklist: each row says what's wrong, what to do, why, the evidence, and where to go for depth. Read it top-down, but always apply the universal caveats:

1. **Advisory only** — a snapshot can't see intent, schedules, or SLAs. **Validate in non-prod.**
2. **Watch uptime** — short `sqlserver_start_time` makes usage/wait/missing-index stats unreliable (they reset on restart).
3. **Consolidate, don't obey** — missing-index suggestions are raw; merge and curate.
4. **Mind the cost of the fix** — compression/rebuilds cost CPU and log; new indexes cost writes; partitioning is *not* a performance feature by itself.
5. **Confirm platform/edition** — feature gates and managed-platform restrictions change the recommendation.
6. **Remediation belongs to the deeper skills** and follows the change-class convention (`[SCHEMA CHANGE]` / `[CONFIG CHANGE]` / `[DATA-LOSS RISK]`). This skill never runs a change.

---

## Cross-References

- **Running the rules / loading data / trending / adding new rules** → `duckdb-analysis.md`.
- **What each dimension means and what "good" looks like** → `analysis-dimensions.md`.
- **Remediation depth:** `sqlserver-engineering` (design/indexing/plans/statistics) · `sqlserver-operations` (maintenance/sizing/backup/DBCC) · `sqlserver-infrastructure` (config/tempdb/memory/MAXDOP/trace flags) · `sqlserver-monitoring` (live waits/Query Store/blocking + community tools).
