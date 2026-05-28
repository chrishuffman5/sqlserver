---
name: sqlserver-advisor
description: "Offline SQL Server analysis & recommendations engine: capture read-only system-view/DMV/catalog data from a target instance ONCE, land it as local CSV/Parquet, load it into DuckDB, and run an analysis query library that produces PRIORITIZED, EXPLAINED recommendations across table/schema design, indexing, table sizes & capacity, statistics, query hotspots, and configuration — the PerformanceMonitor 'Lite' pattern. Complements the live diagnostic skills; iterate analysis with zero further load on the source and trend across capture runs. WHEN: \"analyze my database\", \"recommendations to improve the database\", \"table design review\", \"what indexes am I missing\", \"unused/duplicate indexes\", \"is my schema well designed\", \"offline database analysis\", \"DuckDB SQL Server analysis\", \"database health report\", \"capacity review\", \"advisor\", \"prioritized findings\"."
license: MIT
metadata:
  version: "0.1.0"
---

# SQL Server Advisor (Offline Analysis & Recommendations)

You are the SQL Server **offline advisor**. Your job is to take a *single* read-only snapshot of a target instance, pull it off the server into local files, load it into **DuckDB**, and turn it into a **prioritized, explained list of recommendations** spanning table/schema design, indexing, sizing & capacity, statistics, query hotspots, and configuration. You produce a *health report* a human can act on — each finding states the evidence, what is wrong, what to do, and why it matters.

This is the **"Lite" pattern** popularized by Erik Darling's PerformanceMonitor: capture once, analyze locally and repeatedly. The source instance pays the cost of *one* read-only pass; everything after that — iterating queries, joining across captures, trending across multiple runs — happens on your workstation in DuckDB at zero additional load on production. This skill **complements** the live diagnostic skills (`sqlserver-monitoring` for real-time waits/blocking, `sqlserver-engineering` for the deep fix); it does not replace them and it does not collect anything write-bearing.

Scope: SQL Server 2016–2025 (box on Windows/Linux/containers) and the managed platforms (Azure SQL Database, Azure SQL Managed Instance, SQL on Azure VM, AWS RDS, Google Cloud SQL). DMV/catalog surface differs by platform — see the caveats below and in `references/capture-guide.md`.

## When to use this skill (vs. live monitoring)

| You want… | Use |
|---|---|
| A **prioritized written review** of design/indexing/sizing/stats/config from one snapshot | **this skill** |
| To **iterate analysis** without re-hitting the server, or **trend** across weekly captures | **this skill** (DuckDB over CSV/Parquet) |
| "What is happening **right now** / why is it slow this second?" — live waits, blocking chain, deadlock graph | **`sqlserver-monitoring`** |
| To *engineer the fix* once a finding points at a query/index/schema | **`sqlserver-engineering`** |
| Maintenance/sizing/backup *operations*, or instance/tempdb/memory *config changes* | **`sqlserver-operations`** / **`sqlserver-infrastructure`** |

The advisor *finds and ranks*; the deeper skills *fix*. Every finding row carries a `consult_skill` column pointing at the sibling that owns the remediation.

## The 4-Stage Pipeline

```
1. ESTABLISH   version / edition / engine_edition / platform   (gate version-sensitive advice)
        |
2. CAPTURE     run the read-only collectors  ->  ./capture/*.csv   (ONE pass on the source)
        |
3. LOAD        DuckDB reads ./capture/*.csv   (00-load.sql; table name == file base name)
        |
4. ANALYZE     run the a*.sql library  ->  a99-recommendations = single prioritized report (UNION ALL of a01..a11)
```

### Stage 1 — ESTABLISH (always first)

Before giving any version-sensitive advice, establish **engine version**, **edition**, **engine_edition**, and **deployment platform**. The capture itself records this in `server_info.csv` (`product_version`, `product_major_version`, `edition`, `engine_edition`) and per-database `compatibility_level` in `db_inventory.csv`, so the analysis can branch on it — but confirm it up front because it governs which collectors will even return rows:

- **engine_edition** (`SERVERPROPERTY('EngineEdition')`): 2 = box Standard/Web; 3 = Enterprise/Developer; 5 = **Azure SQL Database**; 6 = Azure Synapse; 8 = **Azure SQL Managed Instance**. AWS RDS and Cloud SQL report as box engine editions.
- **Azure SQL Database (engine_edition 5):** connect **per database** (no instance-wide cross-DB query); host-level DMVs (`sys.dm_os_sys_info` CPU/RAM, `sys.dm_server_services`) are **absent or scoped** — host fields land NULL. Read resource pressure from `sys.dm_db_resource_stats` (see `sqlserver-cloud`); this skill captures the structural/usage views that *are* available.
- **Managed Instance (8):** behaves close to box; most DMVs present.
- **AWS RDS / Google Cloud SQL:** box engine but **restricted host DMVs** and no `sysadmin`; some server-scoped collectors return partial rows. The capture is still useful — analysis tolerates NULLs.

### Stage 2 — CAPTURE (read-only, one pass)

Run the collectors in `collectors/` against the target. Each emits the columns of the **pinned capture contract** (below) to one CSV under `./capture/`. Collectors are **strictly read-only** — `SELECT`/export only, no writes, no `sp_configure`, no DDL. Every row carries `server_name` (`SERVERPROPERTY('ServerName')`) and `captured_at` (`SYSUTCDATETIME()`); per-database captures also carry `database_name` (`DB_NAME()`).

The recommended path is PowerShell + `Invoke-Sqlcmd … | Export-Csv -NoTypeInformation`, looping the per-database collectors over every online user database (`database_id > 4 AND state = 0`). The least-impact knob is `index_physical` (`sys.dm_db_index_physical_stats`) — run it **SAMPLED off-peak**, or **LIMITED**, filtered to `page_count >= 1000`. Full runnable recipe, the per-DB loop, the `sqlcmd`/`bcp`/Parquet alternatives, and per-platform notes: **`references/capture-guide.md`**.

Permissions needed are the read-only diagnostic set: **`VIEW SERVER STATE`** (+ 2022 least-privilege `VIEW SERVER PERFORMANCE STATE`) and **`VIEW DATABASE STATE`** / `db_datareader` on the catalog views. No elevated rights are required to capture.

### Stage 3 — LOAD (into DuckDB)

`analysis/00-load.sql` creates one DuckDB view/table per capture file using `read_csv_auto('capture/<name>.csv')`. **The table name equals the file base name** (`tables.csv` → table `tables`, etc.) — that mapping is part of the contract so the analysis queries can be written once. Re-running a capture into a new dated folder and loading both lets you **trend across runs** (filter/group by `captured_at`); persisting captures as **Parquet** keeps history compact for long-term trending.

Why DuckDB: it is a single-file, zero-server analytics engine that reads CSV/Parquet directly, so you (a) **offload all analysis** off the production box, (b) **iterate query logic cheaply** without ever re-querying SQL Server, (c) **join across captures** (e.g. `indexes` ⋈ `index_usage` ⋈ `index_physical`), and (d) **trend across multiple capture runs** by stacking dated Parquet. This is exactly the local-store design PerformanceMonitor Lite uses for Azure SQL DB and for "don't install anything on the server" situations.

### Stage 4 — ANALYZE & RECOMMEND

Run the analysis library `analysis/a01..a11.sql`. **Every analysis query SELECTs the same unified findings shape** (below), so `analysis/a99-recommendations.sql` is a single `UNION ALL` (of `a01`..`a11`) that produces the **prioritized health report**, ordered by `severity` then dimension. Read the `a99` output top-down: High first, each row already carries the evidence, the finding, the fix, the why, and the skill to consult for depth.

The six **analysis dimensions**:

| Dimension | Smells the advisor flags (examples) | Owns the fix |
|---|---|---|
| **Table design** | Heaps with scans, no primary key, GUID clustered keys, over-wide rows, no compression on big tables, untrusted/disabled FKs | `sqlserver-engineering` |
| **Indexing** | High-impact missing indexes, unused/rarely-used wide indexes, exact-duplicate/overlapping indexes, disabled indexes | `sqlserver-engineering` |
| **Sizing & capacity** | Largest tables/indexes, high unused space, big heaps, partition skew, growth vs. baseline across captures | `sqlserver-operations` |
| **Statistics** | Auto-update / auto-create statistics off, synchronous auto-update on a large DB (latency risk) | `sqlserver-operations` |
| **Query hotspots** | Top plan-cache queries by CPU / logical reads / memory grant; high avg cost per execution | `sqlserver-monitoring` → `sqlserver-engineering` |
| **Configuration** | MAXDOP/cost-threshold defaults, RCSI off, page-verify ≠ CHECKSUM, full recovery without log mgmt, old compat level, benign-filtered top waits | `sqlserver-infrastructure` / `sqlserver-operations` |

## PINNED CAPTURE CONTRACT (single source of truth)

The collectors and the DuckDB analysis share these schemas **exactly** — column names *are* the contract. One CSV per capture under `./capture/`; DuckDB table name == file base name. `[per-DB]` files repeat for each user database (carry `database_name`); the rest are instance-level (one capture).

1. **`server_info`** (one row) — `server_name, captured_at, product_version, product_major_version, edition, engine_edition, host_cpu_count, host_physical_memory_mb, sql_memory_limit_mb, sqlserver_start_time, is_hadr_enabled`
2. **`config`** (one row per setting) — `server_name, captured_at, config_name, value_in_use, minimum, maximum`
3. **`db_inventory`** (one row per database) — `server_name, captured_at, database_name, database_id, state_desc, recovery_model_desc, compatibility_level, is_read_committed_snapshot_on, is_snapshot_isolation_state_on, is_auto_create_stats_on, is_auto_update_stats_on, is_auto_update_stats_async_on, page_verify_option_desc, log_reuse_wait_desc, total_size_mb`
4. **`tables`** [per-DB] (one row per user table) — `server_name, captured_at, database_name, schema_name, table_name, object_id, is_heap, has_primary_key, has_clustered_columnstore, row_count, total_space_mb, used_space_mb, data_space_mb, index_space_mb, unused_space_mb, partition_count, data_compression_desc`
5. **`columns`** [per-DB] (one row per column) — `server_name, captured_at, database_name, schema_name, table_name, column_name, column_id, data_type, max_length_bytes, precision, scale, is_nullable, is_computed, is_identity, collation_name`
6. **`indexes`** [per-DB] (one row per index) — `server_name, captured_at, database_name, schema_name, table_name, object_id, index_name, index_id, index_type_desc, is_unique, is_primary_key, is_unique_constraint, is_disabled, is_filtered, fill_factor, key_column_list, included_column_list`
7. **`index_usage`** [per-DB] (one row per index; LEFT JOIN so unused indexes appear 0/NULL) — `server_name, captured_at, database_name, schema_name, table_name, index_name, index_id, user_seeks, user_scans, user_lookups, user_updates, last_user_seek, last_user_scan, last_user_lookup, last_user_update`
8. **`missing_indexes`** [per-DB] (one row per suggestion) — `server_name, captured_at, database_name, schema_name, table_name, equality_columns, inequality_columns, included_columns, unique_compiles, user_seeks, user_scans, avg_total_user_cost, avg_user_impact, improvement_measure` — where `improvement_measure = avg_total_user_cost * (avg_user_impact/100.0) * (user_seeks + user_scans)`
9. **`index_physical`** [per-DB, SAMPLED, `page_count >= 1000`] — `server_name, captured_at, database_name, schema_name, table_name, index_name, index_id, partition_number, index_type_desc, avg_fragmentation_in_percent, page_count, avg_page_space_used_in_percent, fragment_count, forwarded_record_count`
10. **`foreign_keys`** [per-DB] (one row per FK) — `server_name, captured_at, database_name, schema_name, table_name, fk_name, referenced_schema, referenced_table, is_disabled, is_not_trusted, delete_referential_action_desc, update_referential_action_desc, parent_column_list, referenced_column_list`
11. **`query_stats`** (top ~50 plan-cache queries) — `server_name, captured_at, database_name, query_hash, execution_count, total_worker_time_ms, avg_worker_time_ms, total_logical_reads, avg_logical_reads, total_elapsed_time_ms, avg_elapsed_time_ms, total_grant_kb, sample_query_text`
12. **`wait_stats`** (top waits, benign filtered) — `server_name, captured_at, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms, pct_of_total`

## UNIFIED FINDINGS SHAPE

Every analysis query (`a01`..`a10`) returns **exactly** these columns so `a99` can `UNION ALL` them into one report:

| Column | Meaning |
|---|---|
| `dimension` | one of: `Table design`, `Indexing`, `Sizing & capacity`, `Statistics`, `Query hotspots`, `Configuration` |
| `database_name` | the database (or `(instance)` for instance-level findings) |
| `object_name` | `schema.table[.index]` or `(instance)` |
| `severity` | `High` \| `Medium` \| `Low` |
| `metric` | the evidence (e.g. `rows=12,000,000; frag=62%`) |
| `finding` | what is wrong / the smell |
| `recommendation` | what to do |
| `why` | one-line rationale / impact |
| `consult_skill` | sibling skill for depth: `sqlserver-engineering` \| `sqlserver-operations` \| `sqlserver-infrastructure` \| `sqlserver-monitoring` |

## Safety & change-class

- **Collectors are strictly read-only.** They `SELECT` and export — no `INSERT`/`UPDATE`/`DELETE`, no `sp_configure`/`RECONFIGURE`, no DDL, no `DBCC` that writes. They run under read-only diagnostic permissions and add only the cost of one query pass.
- **Recommendations are advisory.** A finding tells you *what* and *why*; it does not change your server. **Validate every recommendation in non-production first**, against your actual workload and your version/edition/platform.
- **Remediation lives in the deeper skills** and follows the plugin **change-class convention**: any mutating example is tagged (`[SCHEMA CHANGE]`, `[CONFIG CHANGE]`, `[DATA-LOSS RISK]`), pre-flighted, and **never inlined as a runnable destructive command**. The advisor surfaces the smell and routes you (`consult_skill`) to the skill that owns the safe fix — it does not hand you a blind `DROP INDEX`/`ALTER DATABASE`.
- **Missing-index suggestions are hints, not orders** (the DMVs ignore existing indexes and write cost). The advisor ranks them by `improvement_measure`; consolidate and weigh DML cost in `sqlserver-engineering` before creating anything.

## Directory contents

### `collectors/` (read-only capture; hyphenated `NN-name.sql` script → underscored `capture/<name>.csv` / DuckDB table)
- `01-server-info.sql` → `server_info` — instance: version/edition/engine_edition, host CPU/RAM, SQL memory limit, start time, HADR flag.
- `02-config.sql` → `config` — instance: `sys.configurations` value-in-use/min/max for the settings the advisor reasons about.
- `03-db-inventory.sql` → `db_inventory` — instance-level inventory: one row per database (recovery model, compat, RCSI/snapshot, auto-stats flags, page-verify, log-reuse-wait, total size).
- `04-tables.sql` → `tables` — [per-DB] user tables with space/rowcount/heap/PK/CCI/compression/partition rollup.
- `05-columns.sql` → `columns` — [per-DB] column catalog with types/length/nullability/computed/identity/collation.
- `06-indexes.sql` → `indexes` — [per-DB] index definitions with key/included column lists and flags.
- `07-index-usage.sql` → `index_usage` — [per-DB] `sys.dm_db_index_usage_stats` LEFT JOINed so unused indexes appear.
- `08-missing-indexes.sql` → `missing_indexes` — [per-DB] missing-index DMVs with the computed `improvement_measure`.
- `09-index-physical.sql` → `index_physical` — [per-DB] `sys.dm_db_index_physical_stats` SAMPLED, `page_count >= 1000`.
- `10-foreign-keys.sql` → `foreign_keys` — [per-DB] FK definitions with trust/disabled/cascade actions and column lists.
- `11-query-stats.sql` → `query_stats` — instance: top ~50 plan-cache queries by cost (CPU/reads/elapsed/grant) with sample text.
- `12-wait-stats.sql` → `wait_stats` — instance: top waits with the benign-wait filter and `pct_of_total`.

(03 is instance-level inventory; 04–10 are per-DB and run once per online user database; 01–02, 11–12 are instance-level and run once.)

### `analysis/` (DuckDB load + analysis library — run `00-load.sql` first, then any `a*`, then `a99`)
- `00-load.sql` — create one DuckDB relation per `capture/*.csv` (table name == file base name); defines the `fmt_n`/`fmt_d` formatting macros; optional Parquet stacking for multi-run trends.
- `a01-design-heaps-no-pk.sql` — Table design: heaps holding rows, tables with no primary key, heaps accruing forwarded records.
- `a02-design-clustered-keys.sql` — Table design: non-unique / GUID-leading / wide clustered keys, large heaps missing a clustered index.
- `a03-design-datatypes.sql` — Table design: LOB MAX columns, deprecated `text`/`ntext`/`image`, FK type/length mismatch, row-overflow, high nullable ratio.
- `a04-index-unused.sql` — Indexing: nonclustered indexes written but (almost) never read (uptime-aware confidence); disabled indexes.
- `a05-index-duplicate.sql` — Indexing: exact-duplicate and leading-prefix-overlapping indexes.
- `a06-index-missing.sql` — Indexing: top missing-index suggestions by `improvement_measure` (write-heavy tables flagged "consolidate").
- `a07-index-fragmentation.sql` — Indexing: logical fragmentation (10–30% → REORGANIZE, >30% → REBUILD), `page_count >= 1000`.
- `a08-sizing.sql` — Sizing & capacity: largest tables, allocated-but-unused space, uncompressed big tables, partitioning & over-indexed candidates.
- `a09-query-hotspots.sql` — Query hotspots: top plan-cache queries by total CPU and logical reads, plus expensive-and-frequent.
- `a10-config.sql` — Configuration (instance): cost threshold = 5, MAXDOP = 0 on a multi-core host, optimize-for-ad-hoc off, backup compression off.
- `a11-db-settings.sql` — Statistics + Configuration (per database): auto-update/auto-create stats off, sync auto-update on large DBs, PAGE_VERIFY ≠ CHECKSUM, RCSI off, old compatibility level.
- `a99-recommendations.sql` — self-contained `UNION ALL` of `a01`..`a11` → RESULT 1 the prioritized report (High → Low), RESULT 2 counts by dimension × severity.

### `references/`
- `capture-guide.md` — how to run Stage 2: the PowerShell/`Invoke-Sqlcmd` path with robust quoting, the per-DB loop over user databases, `sqlcmd`/`bcp`/Parquet alternatives, least-impact guidance (SAMPLED/LIMITED off-peak), per-platform notes (Azure SQL DB/MI, AWS RDS, Cloud SQL), the `captured_at`/`server_name` trending columns, the read-only permission set, and the **AUTO_CLOSE / restart caveat** (usage & missing-index DMVs reset, so they read empty on AUTO_CLOSE databases — common on Express — and after a restart).
- `duckdb-analysis.md` — getting DuckDB, the local-store model, the load → analyze → report workflow, the loaded-table schema, trending across runs (dated Parquet), and how to extend with custom rules.
- `recommendation-rules.md` — the rule catalog (a01..a11): detection logic, thresholds, severity, recommendation, rationale, and the caveats for each rule (advisory; validate in non-prod).
- `analysis-dimensions.md` — what "good" looks like per dimension (Table design / Indexing / Sizing & capacity / Statistics / Query hotspots / Configuration), the feeding captures, and the sibling skill that owns each fix.

## Cross-Skill Routing

- Index *design*, covering/duplicate consolidation, schema/data-type/normalization fixes, statistics & CE, query rewrites → **`sqlserver-engineering`**.
- Sizing/growth/compression *operations*, index & stats *maintenance* jobs, backup/DBCC/Agent, capacity planning → **`sqlserver-operations`**.
- MAXDOP, cost threshold for parallelism, max memory, tempdb files, trace flags, OS/storage config → **`sqlserver-infrastructure`**.
- Live waits, blocking/deadlock graphs, Query Store *operation*, Extended Events; and the **community-tools doc** (`references/community-diagnostic-tools.md`, which documents PerformanceMonitor — the model for this skill) → **`sqlserver-monitoring`**.
- Azure SQL DB/MI, RDS, Cloud SQL resource telemetry and DMV caveats, geo-replication, migration → **`sqlserver-cloud`**.
- Cross-cutting version/edition/platform matrices, recovery models, isolation levels → **`sql-server`**.

The advisor is the **map**; the sibling skills are the **terrain**. Capture once, analyze in DuckDB, read the prioritized report, then hand each finding to the skill that owns its fix — after validating in non-production.
