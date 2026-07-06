# Recommendation Rule Catalog

The rule library that runs inside DuckDB against the captured data (see `duckdb-analysis.md` for how to load and run it). Each analysis file `a01..a17` emits the **unified findings shape** (`dimension, database_name, object_name, severity, metric, finding, recommendation, why, consult_skill`); `a99` consolidates and prioritizes them. **Section numbers below match the analysis file names exactly** — `a04` here is `analysis/a04-index-unused.sql`.

> **Everything here is ADVISORY.** A capture is a single point-in-time snapshot of DMV/catalog data — it does not know your workload's intent, your maintenance windows, your month-end jobs, or your business SLAs. **Validate every recommendation in a non-production environment before acting.** Remediation T-SQL is *not* the job of this skill: it lives in the deeper skills and follows the plugin **change-class convention** — mutating examples are tagged `[SCHEMA CHANGE]` / `[CONFIG CHANGE]` / `[DATA-LOSS RISK]`, and destructive commands are never inlined as runnable. The collectors that produced the capture are strictly read-only.

**Establish version / edition / platform first.** Read `server_info` (`product_major_version`, `edition`, `engine_edition`) before applying any version-sensitive rule. Feature-gated recommendations (ONLINE rebuilds, columnstore, compression, optimized locking) depend on edition; cloud platforms (Azure SQL DB/MI, AWS RDS, Google Cloud SQL) restrict or omit some DMVs and disallow some remediations (e.g. you don't set instance memory on Azure SQL DB). Note the caveat in the finding when the platform changes the answer.

**Severity is relative, not absolute.** The default thresholds below are starting points tuned for a typical OLTP instance. They are meant to be edited — adjust them for your environment and re-run; nothing touches SQL Server again.

---

## a01 — Table Design: Heaps, Missing PKs, Forwarded Records

Reads `tables`, `index_physical`.

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Heap with significant rows** | `tables.is_heap` and `row_count` high | `row_count >= 100,000` | High `>= 1,000,000`; else Medium | Evaluate a clustered index (narrow, unique, static, ever-increasing key) | Heaps cause forwarded records, IAM-chain scans, and fat NCI RID locators |
| **Table with no primary key** | `tables.has_primary_key = 0` | any (severity scales with rows) | High `>= 1,000,000`; Medium `>= 10,000`; else Low | Add a PK / enforce entity integrity | No PK → no enforced uniqueness, weak referential model, replication/AG friction |
| **Heap accumulating forwarded records** | `index_physical.forwarded_record_count > 0` on `index_id = 0` | any (severity scales) | High `>= 100,000`; Medium `>= 1,000` | Add a clustered index, or interim `ALTER TABLE ... REBUILD` | Each forwarded record costs an extra page read on every access |

**Caveats.** A heap is fine for tiny lookup/staging tables and some bulk-load patterns — don't blanket-cluster everything. "No PK" may be intentional for staging. `consult_skill = sqlserver-engineering`.

---

## a02 — Table Design: Clustered-Key Smells

Reads `indexes`, `columns`, `tables`.

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Non-unique clustered index** | `indexes` clustered, `is_unique = 0` | any | Medium | Make the clustered key unique (or base it on the PK) | Hidden uniquifier bloats every NCI row locator |
| **GUID-leading clustered key** | leading key column is `uniqueidentifier` | any | High | Sequential surrogate or `NEWSEQUENTIALID()` | Random inserts → page splits, fragmentation, write amplification |
| **Wide clustered key** | summed `max_length_bytes` of key columns | `>= 100` bytes | High `>= 200`; else Medium | Narrow the key (surrogate IDENTITY) | Every NCI carries the full clustered key as its locator |
| **Large heap** | `is_heap` and `row_count >= 500,000` | as stated | Medium | Evaluate a clustered index on the primary access path | Ordered access, no RID lookups/forwarding |

**Caveats.** GUID keys are sometimes mandated by app frameworks — the fix may be `NEWSEQUENTIALID()` or clustering on something else while keeping the GUID as a nonclustered PK. All fixes are size-of-data `[SCHEMA CHANGE]`s. `consult_skill = sqlserver-engineering`.

---

## a03 — Table Design: Data-Type Smells

Reads `columns`, `foreign_keys`.

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **LOB MAX column** | `(n)varchar/varbinary` with `max_length_bytes = -1` | any | Low | Right-size if values are bounded | MAX stores off-row, hurts scans/grants, blocks ONLINE ops |
| **Deprecated LOB types** | `text` / `ntext` / `image` | any | Medium | Migrate to `(N)VARCHAR(MAX)` / `VARBINARY(MAX)` | Deprecated, feature-hostile, replication/AG friction |
| **FK type/length mismatch** | parent vs. referenced column type or length differs | any | High | Align FK column type with the referenced key | `CONVERT_IMPLICIT` on the join → non-SARGable lookups |
| **Row-overflow risk** | summed declared widths `> 8060` bytes | as stated | Medium | Right-size columns / vertical split | Off-row push adds pointer indirection and reads |
| **Very high nullable ratio** | `>= 80%` nullable of `>= 10` columns | as stated | Low | Review normalization / SPARSE | Mostly-nullable tables often hide multiple entities |

**Caveats.** Data-type changes are size-of-data `[SCHEMA CHANGE]`s and can break application contracts — verify usage first. `consult_skill = sqlserver-engineering`.

---

## a04 — Indexing: Unused & Disabled Indexes

Reads `index_usage`, `indexes`, `server_info` (uptime).

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Written-never-read index** | reads = 0, `user_updates > 0`; excludes PK/unique-constraint/disabled | any writes | **Uptime-aware:** Low if uptime < 7 days; High if `user_updates >= 100,000`; Medium `>= 1,000` | Confirm over a representative window, then consider dropping | Pure write cost, zero read benefit |
| **Low read:write ratio** | reads < 1% of `user_updates`, `user_updates >= 1,000` | as stated | same scale | Review necessity / trim | Low-value index paying high write cost |
| **Disabled index** | `indexes.is_disabled = 1` | any | Medium | REBUILD to re-enable, or DROP | Dead metadata weight; disabled clustered = inaccessible table |

**Caveats — read before recommending a drop.**
- **Usage counters reset on instance restart** and are **wiped on database close** (`AUTO_CLOSE` — see the capture guide's volatile-DMV caveat). A "zero reads" index may feed a **month-end job** that hasn't run in the window. The rule already downgrades to Low under 7 days' uptime; confirm across multiple captures before dropping.
- **Never drop** the index backing a `PRIMARY KEY`/`UNIQUE` constraint (the rule excludes them) and check it isn't supporting FK joins/cascades (cross-reference `a12`).
- Dropping is a `[SCHEMA CHANGE]`. `consult_skill = sqlserver-engineering`.

---

## a05 — Indexing: Duplicate & Overlapping Indexes

Reads `indexes`.

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Exact duplicate** | same `key_column_list` **and** same `included_column_list` on one table | exact match | High | Keep one, drop the redundant copy | Double write/storage cost, zero added capability |
| **Left-prefix overlap** | one key list is a leading prefix of a wider index's | prefix match | Medium | Consider dropping the narrower (check seek patterns/INCLUDEs first) | The wider index usually satisfies the same seeks |

**Caveats.** A prefix index can still be the better choice if it's much narrower and hotter — consolidation isn't automatic. Dropping is a `[SCHEMA CHANGE]`. `consult_skill = sqlserver-engineering`.

---

## a06 — Indexing: Missing Indexes (top 25, consolidated)

Reads `missing_indexes`, `index_usage` (table write context).

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **High-impact suggestion** | rank by `improvement_measure` (= `avg_total_user_cost * avg_user_impact/100 * (user_seeks + user_scans)`), top 25 | High `>= 100,000`; Medium `>= 10,000`; else Low | as stated | Consolidate near-duplicates, order keys equality-then-range, cover with INCLUDE, check overlap with existing indexes, then create | The optimizer wished for this index at compile time |
| **Write-heavy table flag** | table's summed `user_updates >= 100,000` | as stated | annotation on the finding | "Consolidate, do not just add" | New index cost lands on every one of those writes |

**Caveats — the DMV suggestions are RAW, not a plan.** They never consolidate, ignore existing indexes, ignore write cost, and don't reliably order equality-before-inequality. **Never apply verbatim.** They also reset on restart/DB close. `consult_skill = sqlserver-engineering` (indexing — "Use, Don't Obey"). Creating an index is a size-of-data `[SCHEMA CHANGE]`.

---

## a07 — Indexing: Fragmentation

Reads `index_physical` (SAMPLED, `page_count >= 1000`).

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **High fragmentation** | `avg_fragmentation_in_percent > 30` | as stated | High if `page_count >= 100,000`; else Medium | REBUILD (ONLINE only on Enterprise/Azure) | Restores contiguity + fill factor |
| **Moderate fragmentation** | 10–30% | as stated | Low | REORGANIZE (always online) | Cheap leaf-level defrag |

**Caveats.** The 10/30 guidance is a **starting heuristic, widely over-applied** — fragmentation mostly matters for large range scans on disk-bound workloads; on SSD/NVMe or a warm buffer pool it's often irrelevant. Don't rebuild to chase a number; rebuilds churn the log and bloat differentials. ONLINE rebuild is Enterprise/Developer/Azure-gated; Standard rebuilds are OFFLINE (Sch-M). Maintenance is owned by `sqlserver-operations`; the metric includes `avg_page_space_used_in_percent` (page fullness) as supporting evidence.

---

## a08 — Sizing & Capacity

Reads `tables`.

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Largest tables (top 20)** | rank by `total_space_mb` | top 20 | High `>= 50 GB`; Medium `>= 10 GB`; else Low | Trend growth across captures; review retention/archival | Largest tables drive backup duration, RTO, maintenance windows |
| **High unused space** | `unused_space_mb >= 1,024` and `> 20%` of total | as stated | High `>= 10 GB` | Investigate cause; REBUILD reclaims most; avoid routine shrinks | Allocated-but-unused pages still get stored/backed up/scanned |
| **Large uncompressed table** | `data_compression_desc = 'NONE'`, `total >= 1 GB` | as stated | Medium `>= 10 GB`; else Low | Evaluate ROW/PAGE compression (columnstore for analytics) | Cuts I/O and buffer-pool footprint at CPU cost |
| **Very large unpartitioned table** | `total >= 50 GB`, `partition_count <= 1` | as stated | Medium | Evaluate partitioning for lifecycle management (not speed) | SWITCH/piecemeal maintenance on huge tables |
| **Over-indexed table** | `index_space > 2x data_space`, data `>= 100 MB` | as stated | Medium `>= 10 GB` index | Cross-check `a04`/`a05`, consolidate | Indexes outweighing data usually means redundant indexes |

**Caveats.** Compression has real CPU cost (`PAGE` > `ROW`) — measure in non-prod; it's a size-of-data `[SCHEMA CHANGE]`. Unused space has benign causes (recent delete, LOB); `DBCC SHRINK*` is **not** a routine fix. Growth *trends* need multiple captures (`duckdb-analysis.md` §6). `consult_skill = sqlserver-operations`; compression/partition design → `sqlserver-engineering`.

---

## a09 — Query Hotspots

Reads `query_stats` (top ~50 plan-cache queries).

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Top CPU consumers** | rank by `total_worker_time_ms`, top 15 | top 3 High; top 8 Medium; else Low | as stated | Capture the actual plan; SARGability, estimates, missing indexes | Biggest aggregate CPU wins |
| **Top logical-read (I/O) queries** | rank by `total_logical_reads`, top 15 | same scale | as stated | Scans that should be seeks; covering indexes (cross-ref `a06`) | Read amplification → buffer churn, I/O waits |
| **Expensive AND frequent** | `avg_elapsed >= 100 ms` and `execs >= 1,000` | as stated | High | Prioritize: per-call cost × frequency; check for RBAR | Cost×frequency is the true workload burden |

**Caveats.** The plan cache is **volatile** — clears on restart/memory pressure/recompile; undercounts `OPTION (RECOMPILE)` and one-off ad-hoc queries. Not historical truth — for "what changed yesterday" use **Query Store** (`sqlserver-monitoring`). `sample_query_text` is one representative statement per hash; inspect the live plan before tuning. `consult_skill = sqlserver-engineering` (fix) / `sqlserver-monitoring` (find).

---

## a10 — Configuration (instance sp_configure)

Reads `config`, `server_info`.

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Cost threshold for parallelism = 5** | `value_in_use = 5` | default | Medium | Raise (commonly 25–50), tune with CXPACKET/CXCONSUMER | 1990s default sends trivial queries parallel |
| **MAXDOP = 0 on multi-core** | `value = 0`, `host_cpu_count > 1` | as stated | High `>= 16` cores; else Medium | Bound per core/NUMA layout (typically ≤ 8) | One query can consume every scheduler |
| **Optimize for ad hoc off** | `value = 0` | off | Low | Enable | Single-use plans bloat the cache |
| **Backup compression default off** | `value = 0` | off | Low | Enable (box; check platform) | Smaller, faster backups at modest CPU |
| **max server memory uncapped** | `value >= 2147483647` on box (`engine_edition NOT IN (5,6,8)`) | default | High | Cap below physical RAM with OS headroom | Uncapped buffer pool starves the OS into paging |
| **Legacy knobs enabled** | `priority boost = 1` or `lightweight pooling = 1` | any | Medium | Turn off in a window | Long-deprecated, known-harmful settings |

**Caveats.** Configuration is **platform-specific** — on Azure SQL DB these are platform-managed (rules mostly cannot fire because `config` is empty/irrelevant there); on MI/RDS/Cloud SQL several knobs are provider-set. Defaults-vs-best-practice are starting points: recommend, then *observe* (correlate with `a17` waits). All `[CONFIG CHANGE]`s. `consult_skill = sqlserver-infrastructure`.

---

## a11 — Database Settings (statistics switches & DB config hygiene)

Reads `db_inventory` (user DBs only, `database_id > 4`).

| Rule | Detection | Severity | Recommendation | Why |
|---|---|---|---|---|
| **Auto-update stats off** | `is_auto_update_stats_on = 0` | Medium | Enable unless a managed stats regime demonstrably covers it | Stale cardinality → bad plans |
| **Auto-create stats off** | `is_auto_create_stats_on = 0` | Medium | Enable | Un-stat'd predicates get guessed selectivity |
| **Sync auto-update on a big DB** | async off and `total_size_mb >= 10 GB` | Low | Consider `AUTO_UPDATE_STATISTICS_ASYNC` | Sync update stalls the triggering query |
| **PAGE_VERIFY ≠ CHECKSUM** | as stated | Medium | Set CHECKSUM; pair with DBCC CHECKDB | Cheapest early corruption warning |
| **RCSI off** | `is_read_committed_snapshot_on = 0` | Low | Evaluate for read-heavy OLTP (size tempdb version store) | Removes reader/writer blocking without NOLOCK hazards |
| **Old compatibility level** | `compatibility_level < 150` | Low | Uplift behind Query Store baseline | Locks out modern optimizer/IQP; can shift plans |

**Caveats.** Auto-stats *off* is occasionally deliberate (controlled jobs) — flag, don't assume. RCSI/compat changes shift behavior database-wide — baseline + staged testing. All `[CONFIG CHANGE]`s. `consult_skill = sqlserver-operations` (stats/page-verify) / `sqlserver-engineering` (RCSI/compat semantics). Per-statistic freshness now has its own capture and rules — see **`a15`**.

---

## a12 — Table Design: Foreign-Key Trust & Support

Reads `foreign_keys`, `tables`, `indexes`.

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Untrusted FK** | `is_not_trusted = 1` and not disabled | any | High if child `>= 1M` rows; else Medium | `WITH CHECK CHECK CONSTRAINT` to re-validate (size-of-data scan — schedule) | Optimizer can't use it; violations may already exist |
| **Disabled FK** | `is_disabled = 1` | any | High if child `>= 1M` rows; else Medium | Re-enable WITH CHECK, or drop and document | Enforces nothing; orphans accumulate |
| **Cascade on large child** | referential action ≠ `NO_ACTION`, child `>= 1M` rows | as stated | Low | Review blast radius; consider batched cleanup | One parent DELETE fans out lock/log-heavy |
| **Unindexed FK column** | no index leads on the FK's first column | any enabled FK | Medium if child `>= 100k` rows; else Low | Index the FK column(s) **if** joined/filtered or parent sees deletes | Child scans on referential checks and joins |

**Caveats.** NOCHECK may be transient (bulk load/migration in progress) — confirm before flagging loudly. Re-validation scans the child table. An unindexed FK only matters if the access pattern exercises it — don't add indexes reflexively (see `a08` over-indexing). `[SCHEMA CHANGE]`s. `consult_skill = sqlserver-engineering`.

---

## a13 — Configuration / Sizing: Files, Autogrowth, VLFs, tempdb

Reads `db_files`, `server_info`.

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Percent autogrowth** | `is_percent_growth = 1` | any | Medium | Fixed-MB increments (commonly 256–1024 MB); pre-size | Compounding growth events; log growth zero-fills synchronously |
| **Tiny fixed growth** | growth `< 64 MB` on a file `>= 1 GB` | as stated | Medium | Raise increment; enable instant file init (data) | Constant micro-growth events; tiny VLFs on logs |
| **Autogrowth disabled** | `growth_value = 0` | any | Medium | Confirm deliberate, else enable a safety-net growth | File hard-stops when full |
| **Near MAXSIZE cap** | `size >= 80%` of `max_size_mb` (and growth enabled) | as stated | High `>= 95%`; else Medium | Raise/remove the cap or purge/archive | 1105/9002 errors at the cap |
| **High VLF count** | `vlf_count >= 300` (log files, 2016 SP2+) | as stated | High `>= 1,000` | One-time shrink + re-grow in large increments | Tiny-VLF bloat slows recovery/restores/log ops |
| **tempdb file count** | data files < `min(8, cpu_count)` on multi-core | as stated | High if exactly 1 file | One file per CPU up to 8, equal size/growth | PFS/GAM/SGAM allocation contention |

**Caveats.** On Azure SQL DB this capture is skipped (platform-managed). On RDS/Cloud SQL tempdb layout is provider-managed — informational. The VLF "shrink then re-grow" is the **one legitimate shrink**; routine shrinks remain harmful. tempdb changes need a service restart to take full effect. `[CONFIG CHANGE]`s. `consult_skill = sqlserver-infrastructure` (growth/tempdb) / `sqlserver-operations` (capacity/VLF).

---

## a14 — Configuration: Backup & Recovery Cadence

Reads `backup_history`, `db_inventory`.

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Never backed up** | `last_full_backup IS NULL` | any | High (user DB); Medium (system DB) | Take a full now; schedule to RPO | No restore path at all |
| **Stale full** | last full `> 7 days` ago | as stated | High `> 30 days`; else Medium | Restore-test + fix cadence; check for silently-dead jobs | Widening restore gap |
| **FULL recovery, no log backups** | FULL/BULK_LOGGED and last log backup NULL or `> 24 h` | as stated | High | Schedule log backups (5–15 min typical) or deliberately go SIMPLE | Log grows unbounded; PITR is fiction without log backups |
| **Log reuse blocked** | `log_reuse_wait_desc` not `NOTHING`/`CHECKPOINT` | any | High if `LOG_BACKUP`; else Medium | Fix the blocker (log backups / long transaction / AG replica / replication) | Blocked log → disk-full → error 9002 write outage |
| **SIMPLE on a sizable DB** | SIMPLE and `>= 10 GB` | as stated | Low | Confirm the RPO is accepted | No point-in-time restore |
| **Full without CHECKSUM** | `last_full_has_checksum = 0` | as stated | Low | `WITH CHECKSUM` + periodic restore tests | Backups can preserve corruption silently |

**Caveats.** COPY_ONLY fulls are excluded from the "recent full" logic (they don't establish the chain). **Managed platforms:** Azure SQL DB/MI automatic backups and RDS/Cloud SQL snapshots do **not** appear in msdb — the collector is skipped (Azure SQL DB) or its findings are informational unless native backups are the DR strategy. A backup is only proven by a **restore test**. `consult_skill = sqlserver-operations`.

---

## a15 — Statistics: Per-Statistic Staleness

Reads `stats_health` (statistics on rowsets ≥ 1000 rows).

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Stale stats** | `modification_counter >= max(500, sqrt(1000 × rows))` (the engine's own compat-130+ threshold) | as stated | High if `rows >= 1M` and mods `>= 20%` of rows; else Medium | UPDATE STATISTICS; find out why auto-update didn't fire | Histogram drift → cardinality misestimates → bad plans |
| **Old stats with churn** | `last_updated > 90 days` ago, mods > 0 (below rule-1 threshold) | as stated | Low | Fold into scheduled stats maintenance | Slow-churn tables age below the auto threshold for months |
| **Poor sampling** | `rows >= 1M` and `sample_pct < 5%` | as stated | Low | FULLSCAN / persisted sample rate if plans misestimate | Tiny samples miss skew |
| **NORECOMPUTE** | `no_recompute = 1` | any | Medium | Confirm a manual regime covers it, else re-enable | Frozen out of auto-update = silent decay |

**Caveats.** `modification_counter` counts **leading-column** changes since the last update — churn concentrated in non-leading columns undercounts. INCREMENTAL stats are absent from this capture (different TVF). Stats update triggers plan recompiles — schedule heavy passes in a window. `[INDEX MAINTENANCE]`. `consult_skill = sqlserver-operations` (maintenance) / `sqlserver-engineering` (CE behavior, ascending-key problem).

---

## a16 — Table Design: Identity & Sequence Exhaustion

Reads `identity_columns`.

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Range consumption** | `pct_used = last_value / type max` (ascending, non-cycling only) | `>= 50%` reported | High `>= 90%`; Medium `>= 70%`; else Low | Widen the type (int → bigint; size-of-data rebuild — plan it) or reseed into the negative range as a stopgap | At the max, every INSERT fails with error 8115 — a total, predictable write outage |

**Caveats.** Burn *rate* matters more than the current percentage — trend `last_value` across captures to compute the exhaustion date. A negative reseed doubles the runway but breaks apps assuming positive IDs. Widening an int PK also widens every FK and index that carries it — a project, not a hotfix; start it at 70%, not 95%. `[SCHEMA CHANGE]`. `consult_skill = sqlserver-engineering`.

---

## a17 — Configuration: Waits Context

Reads `wait_stats` (benign-filtered by the collector), `server_info` (uptime).

| Rule | Detection | Default threshold | Severity | Recommendation | Why |
|---|---|---|---|---|---|
| **Dominant wait type** | `pct_of_total >= 25%` | as stated | High `>= 50%`; else Medium | Routed per class (table below) | Names the bottleneck *class* to investigate first |
| **High signal-wait ratio** | `SUM(signal) / SUM(wait) >= 25%` | as stated | Medium | Reduce CPU demand (top queries `a09`, parallelism `a10`) before adding CPUs | Runnable-but-waiting = scheduler (CPU) pressure |

**Wait → subsystem routing (built into the rule):** `CXPACKET`/`CXCONSUMER` → cost threshold/MAXDOP (`sqlserver-infrastructure`); `PAGEIOLATCH_*` → memory/indexes/storage; `WRITELOG` → log-disk latency + VLFs (`a13`); `LCK_*` → blocking (live, `sqlserver-monitoring`); `RESOURCE_SEMAPHORE` → memory grants (`sqlserver-engineering`); `PAGELATCH_*` → tempdb allocation (`a13`); `ASYNC_NETWORK_IO` → the client, not the server; `HADR_*` → AG sync (`sqlserver-ha-clustering`).

**Caveats.** Counters are **cumulative since restart** — a one-shot capture is a since-startup average, not a window; the finding carries uptime so you can judge it. Short uptime = unreliable. Don't chase `CXPACKET` as a disease. `PAGELATCH_*` (memory latch) ≠ `PAGEIOLATCH_*` (disk I/O). For a true live window use the snapshot-and-diff views in **`sqlserver-monitoring`**.

---

## How a99 Prioritizes

`a99` materializes every rule above into one `advisor_findings` view (each rule's logic appears exactly once — the individual `aNN` files and `a99` are kept in sync verbatim) and orders **High → Medium → Low**, then by dimension and object; a second result gives counts by dimension × severity from the same view. Read it top-down, but always apply the universal caveats:

1. **Advisory only** — a snapshot can't see intent, schedules, or SLAs. **Validate in non-prod.**
2. **Watch uptime** — short `sqlserver_start_time` makes usage/wait/missing-index stats unreliable (they reset on restart, and on database close under `AUTO_CLOSE`).
3. **Consolidate, don't obey** — missing-index suggestions are raw; merge and curate.
4. **Mind the cost of the fix** — compression/rebuilds cost CPU and log; new indexes cost writes; partitioning is *not* a performance feature by itself; type-widening is a project.
5. **Confirm platform/edition** — feature gates and managed-platform restrictions change the recommendation (and silence some captures entirely).
6. **Remediation belongs to the deeper skills** and follows the change-class convention (`[SCHEMA CHANGE]` / `[CONFIG CHANGE]` / `[DATA-LOSS RISK]`). This skill never runs a change.

---

## Cross-References

- **Running the rules / loading data / trending / adding new rules** → `duckdb-analysis.md`.
- **What each dimension means and what "good" looks like** → `analysis-dimensions.md`.
- **Remediation depth:** `sqlserver-engineering` (design/indexing/plans/statistics) · `sqlserver-operations` (maintenance/sizing/backup/DBCC) · `sqlserver-infrastructure` (config/tempdb/memory/MAXDOP/trace flags) · `sqlserver-monitoring` (live waits/Query Store/blocking + community tools) · `sqlserver-ha-clustering` (AG sync waits).
