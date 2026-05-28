# Analysis Dimensions Reference

The advisor organizes every finding into one of **six dimensions**. Each `dimension` value is part of the unified findings shape (see `recommendation-rules.md`), so `a99` can group and prioritize across them. This doc defines, per dimension: what **"good" looks like**, which **captures feed it**, the main **smells** it detects, and the **sibling skill** to consult for remediation depth.

> All six dimensions are scored *offline* from a single read-only capture loaded into DuckDB. The advisor describes and prioritizes; it never changes the server. Establish **engine version / edition / platform** (`server_info`) before acting on any version-sensitive dimension — feature gates and managed-platform (Azure SQL DB/MI, AWS RDS, Cloud SQL) restrictions change what is possible.

The captures referenced below are the 12 contract tables loaded by `00-load.sql`: `server_info`, `config`, `db_inventory`, `tables`, `columns`, `indexes`, `index_usage`, `missing_indexes`, `index_physical`, `foreign_keys`, `query_stats`, `wait_stats`.

---

## 1. Table Design

**What "good" looks like.** Tables have a narrow, unique, static, ever-increasing **clustered key** (heaps reserved for tiny lookup/staging tables and bulk-load patterns). Every meaningful table has a **primary key** and enforced **referential integrity** via **trusted, enabled foreign keys**. Data types are **right-sized and current** — no deprecated `text`/`ntext`/`image`, `decimal` (not `float`) for money, strings sized deliberately, `nvarchar` only where Unicode is needed. Row width is reasonable (not 50+ columns or gratuitous LOBs) so pages stay dense.

**Captures that feed it.** `tables` (`is_heap`, `has_primary_key`, `has_clustered_columnstore`, `partition_count`, `data_compression_desc`), `columns` (types, sizes, nullability, identity/computed), `indexes` (clustered key, uniqueness), `foreign_keys` (trusted/disabled/cascade actions).

**Main smells detected.** Heaps with significant rows (forwarded records, fat NCI RID locators); large tables with no PK; over-wide tables; deprecated/oversized data types; random-GUID clustered keys (page splits); **untrusted or disabled foreign keys** (lost join elimination, hidden integrity violations); unindexed FK columns; risky cascade actions on big tables. (Rules `a01`, `a10`.)

**Consult for depth.** **`sqlserver-engineering`** — `references/schema-design.md` (normalization, data types, constraints & trusted constraints, partitioning) and `references/indexing.md` (clustered-key choice). Schema changes are size-of-data `[SCHEMA CHANGE]`s.

---

## 2. Indexing

**What "good" looks like.** Indexes earn their keep: each one supports real read patterns, with **equality columns before range columns** and `INCLUDE` used to cover hot queries without bloating keys. **No unused indexes** paying write cost for zero reads, **no exact-duplicate or left-prefix-redundant** indexes, and **missing-index gaps** that genuinely matter are filled with *consolidated, curated* indexes (not raw DMV dumps). Large, scan-heavy indexes are **not excessively fragmented** for the workload, and **no heap is accumulating forwarded records**.

**Captures that feed it.** `indexes` (`key_column_list`, `included_column_list`, uniqueness, disabled, filtered, fill factor), `index_usage` (`user_seeks/scans/lookups` vs `user_updates`, last-used timestamps), `missing_indexes` (`improvement_measure` and its components), `index_physical` (`avg_fragmentation_in_percent`, `page_count`, `avg_page_space_used_in_percent`, `forwarded_record_count`).

**Main smells detected.** Unused indexes with write cost; rarely-used wide indexes; exact-duplicate and left-prefix-overlap indexes; disabled indexes; high-impact missing indexes (ranked by improvement measure); tables drowning in near-duplicate suggestions; heavily fragmented large indexes; low page density; heap forwarded records. (Rules `a02`, `a03`, `a04`.)

**Key context.** Usage and missing-index stats **reset on instance restart** — check `server_info.sqlserver_start_time`; a "zero-read" index may just feed a month-end job that has not run, or the server rebooted yesterday. Missing-index DMVs are **raw signals, not a plan** — consolidate and curate. Fragmentation only matters for **disk-bound range scans** — do not rebuild to chase a percentage.

**Consult for depth.** **`sqlserver-engineering`** for index *design* (`references/indexing.md` — covering/INCLUDE, key-lookup elimination, the "use don't obey" missing-index workflow, unused/duplicate cleanup); **`sqlserver-operations`** for fragmentation *maintenance* (rebuild/reorganize thresholds, fill-factor jobs). Index create/drop/rebuild are `[SCHEMA CHANGE]`s; ONLINE rebuild is Enterprise/Azure-gated.

---

## 3. Sizing & Capacity

**What "good" looks like.** You **know** your largest tables and databases and their **growth trajectory**, with storage headroom to match. Large analytic/cold tables use appropriate **compression** (ROW/PAGE/columnstore) where the I/O-vs-CPU trade-off pays off. Allocated space is mostly **used** (little orphaned/unused space). On FULL recovery, **log reuse is not blocked** (log backups running, no stuck transactions), so files do not grow unbounded. Capacity is **planned from trends**, not discovered at 100% full.

**Captures that feed it.** `tables` (`total_space_mb`, `used_space_mb`, `data_space_mb`, `index_space_mb`, `unused_space_mb`, `row_count`, `data_compression_desc`), `db_inventory` (`total_size_mb`, `recovery_model_desc`, `log_reuse_wait_desc`). Trending uses **multiple captures** across `capture/<server>/<captured_at>/` (see `duckdb-analysis.md` section 6).

**Main smells detected.** Very large uncompressed tables; high unused/orphaned space; large FULL-recovery databases with blocked log reuse (e.g. `LOG_BACKUP` waiting); above-norm growth between captures. (Rule `a05`.)

**Key context.** This dimension is where DuckDB's **trend-over-time** ability shines: load many runs and compute MB deltas / % growth with `LAG()` window functions to forecast. Compression has a **real CPU cost** — measure in non-prod. `DBCC SHRINK*` is **not** a routine remedy (causes fragmentation).

**Consult for depth.** **`sqlserver-operations`** — capacity planning, backup/log management, maintenance. Compression *design* and columnstore choices route to **`sqlserver-engineering`**. Compression is a `[SCHEMA CHANGE]`; shrink is operations-owned and `[DATA-LOSS RISK]`-adjacent.

---

## 4. Statistics

**What "good" looks like.** `AUTO_CREATE_STATISTICS` and `AUTO_UPDATE_STATISTICS` are **on** (the safe default), so the optimizer always has cardinality information for predicates; on busy databases `AUTO_UPDATE_STATISTICS_ASYNC` avoids compile-time stalls. Where auto-stats is deliberately off, a **managed stats-maintenance job demonstrably covers every table**. Large tables have a **freshness strategy** that accounts for the sublinear auto-update threshold (big tables update less often relative to churn).

**Captures that feed it.** `db_inventory` (`is_auto_create_stats_on`, `is_auto_update_stats_on`, `is_auto_update_stats_async_on`), `tables` (size context — which databases have very large tables most exposed to staleness).

**Main smells detected.** Auto-create stats off; auto-update stats off; async update off on a busy/large database; large databases with no evident stats-maintenance strategy. (Rule `a06`.)

**Key context.** The contract carries the **database-level switches**, not per-statistic freshness. Turning auto-stats *off* is **sometimes intentional** (controlled jobs, avoiding mid-day stalls on a huge table) — flag it and confirm a job compensates rather than assuming a mistake. **Per-statistic** staleness (histogram age, `rows_sampled` vs `rows`, the ascending-key problem) requires a **live** look — point the user to the engineering skill's `scripts/06-statistics-info.sql`.

**Consult for depth.** **`sqlserver-engineering`** — `references/query-optimization.md` (statistics internals, the cardinality estimator legacy-vs-new, ascending-key mitigation). Toggling auto-stats is a `[CONFIG CHANGE]`.

---

## 5. Query Hotspots

**What "good" looks like.** No small set of queries disproportionately dominates **CPU, logical reads, or memory grants**; the heaviest queries are **SARGable, well-indexed, and covered**, with stable plans (no runaway parameter sniffing). High-frequency queries are **cheap per call** (or batched/cached), and large memory grants reflect genuine need, not cardinality over-estimates that throttle concurrency.

**Captures that feed it.** `query_stats` (`execution_count`, `total_/avg_worker_time_ms`, `total_/avg_logical_reads`, `total_/avg_elapsed_time_ms`, `total_grant_kb`, `query_hash`, `sample_query_text`).

**Main smells detected.** Top aggregate CPU consumers; queries expensive per execution; logical-read (I/O) hogs (correlate with missing-index findings in `a03`); large memory grants (spill/over-grant risk); frequent cheap-each queries that are heavy in total (death by a thousand cuts). (Rule `a07`.)

**Key context.** `query_stats` is sourced from the **volatile plan cache** — it clears on restart, memory pressure, and recompiles, and undercounts `OPTION (RECOMPILE)` and one-off ad-hoc queries. It is **not historical**. For "what changed yesterday," the durable record is **Query Store** (live; `sqlserver-monitoring`). `sample_query_text` is one representative statement per hash — inspect the **live actual plan** before tuning.

**Consult for depth.** **`sqlserver-engineering`** to *engineer the fix* (index/cover the query, fix SARGability, mitigate sniffing — `references/query-optimization.md`, `references/indexing.md`); **`sqlserver-monitoring`** to *find why it is slow right now* (live waits, Query Store top/regressed queries, plan inspection).

---

## 6. Configuration

**What "good" looks like.** Instance and database settings match the **hardware and workload**: **cost threshold for parallelism** raised off the 1997-era default of 5; **MAXDOP** set for the core/NUMA layout (not 0 on a big box); **`max server memory` capped** below physical RAM with OS headroom (box product); `optimize for ad hoc workloads` on; no legacy/harmful knobs (`priority boost`, `lightweight pooling`). Databases run a **modern compatibility level**, **`PAGE_VERIFY CHECKSUM`**, and OLTP databases use **RCSI** for non-blocking consistent reads. Where waits are captured, they are consistent with a healthy config (no dominant `CXPACKET` from a low cost threshold, no `RESOURCE_SEMAPHORE` queueing).

**Captures that feed it.** `config` (`config_name`, `value_in_use`, `minimum`, `maximum`), `server_info` (`host_cpu_count`, `host_physical_memory_mb`, `sql_memory_limit_mb`, `edition`, `engine_edition`, `sqlserver_start_time`), `db_inventory` (`compatibility_level`, `is_read_committed_snapshot_on`, `page_verify_option_desc`), and `wait_stats` for corroborating bottleneck class.

**Main smells detected.** Cost threshold left at 5; MAXDOP 0 / mis-set for NUMA; uncapped `max server memory`; ad-hoc workloads optimization off; legacy/risky settings; RCSI off on OLTP; old compatibility level; non-CHECKSUM page verify; a dominant wait type or high signal-wait ratio (CPU pressure); tempdb allocation contention; memory-grant pressure. (Rules `a08`, `a09`.)

**Key context.** **Configuration is platform-specific** — read `server_info.engine_edition`: on **Azure SQL Database** you do not set instance memory/MAXDOP the box way; on **Azure SQL MI / AWS RDS / Google Cloud SQL** several knobs are managed or absent (and some DMVs behind these rules are restricted/scoped). "Best-practice" defaults are **starting points** — recommend, then *observe*. `wait_stats` here is **cumulative since restart**: a one-shot capture shows the dominant class, not a live window; short uptime makes it (and usage stats) unreliable.

**Consult for depth.** **`sqlserver-infrastructure`** — instance/OS config, memory, MAXDOP, cost threshold, tempdb, trace flags, storage. RCSI/compatibility-level *semantics* and isolation design route to **`sqlserver-engineering`**; the **live** wait drill-down to **`sqlserver-monitoring`**. All config changes are `[CONFIG CHANGE]`s; RCSI/compat-level uplift change behavior database-wide — baseline with Query Store and test.

---

## Dimension to Rules to Captures to Skill (at a glance)

| Dimension | Rules | Primary captures | Consult skill(s) |
|---|---|---|---|
| **Table design** | `a01`, `a10` | `tables`, `columns`, `indexes`, `foreign_keys` | `sqlserver-engineering` |
| **Indexing** | `a02`, `a03`, `a04` | `indexes`, `index_usage`, `missing_indexes`, `index_physical` | `sqlserver-engineering` (design); `sqlserver-operations` (maintenance) |
| **Sizing & capacity** | `a05` | `tables`, `db_inventory` (+ multi-capture trend) | `sqlserver-operations`; `sqlserver-engineering` (compression) |
| **Statistics** | `a06` | `db_inventory`, `tables` | `sqlserver-engineering` |
| **Query hotspots** | `a07` | `query_stats` | `sqlserver-engineering` (fix); `sqlserver-monitoring` (find) |
| **Configuration** | `a08`, `a09` | `config`, `server_info`, `db_inventory`, `wait_stats` | `sqlserver-infrastructure`; `sqlserver-engineering`; `sqlserver-monitoring` |

---

## Cross-References

- **How the rules run (load to analyze to report), trending, and adding rules** -> `duckdb-analysis.md`.
- **Each rule's detection logic, thresholds, severity, and caveats** -> `recommendation-rules.md`.
- **Remediation depth** lives in the sibling skills and follows the change-class convention (`[SCHEMA CHANGE]` / `[CONFIG CHANGE]` / `[DATA-LOSS RISK]`); this skill is advisory only — validate every recommendation in non-production before acting.
