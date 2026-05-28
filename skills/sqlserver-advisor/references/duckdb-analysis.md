# DuckDB Analysis Reference

How this skill uses **DuckDB** as a local, offline analytics engine to turn a one-time, read-only capture from a target SQL Server into prioritized, explained recommendations. DuckDB is not a SQL Server replacement — it is the cheap, embeddable OLAP engine where you *iterate analysis* against captured data with **zero further load on the source**, join across captures, and trend across runs over time.

> **The model in one sentence:** capture read-only DMV/catalog data from SQL Server **once** → land it as CSV under `./capture/` → load it into DuckDB locally → run `00-load.sql`, then the `a01..a10` rule library, then `a99` for the consolidated prioritized report. Everything after the capture is offline.

---

## 1. The PerformanceMonitor "Lite" Analogy

Erik Darling's PerformanceMonitor (see the community-tools section of **`sqlserver-monitoring`**) has two shapes:

- **Full edition** installs a database, ~32 collector procedures, SQL Agent jobs, and Extended Events sessions *on the monitored instance* — a `[CONFIG CHANGE]` that runs continuously.
- **Lite edition** is a desktop app that pulls data and **stores it locally in DuckDB / Parquet**, leaving the monitored server untouched — the only option for Azure SQL Database, where you cannot install server-side jobs.

**`sqlserver-advisor` deliberately follows the Lite pattern.** The collectors here are strictly read-only `SELECT`/export queries (no install, no jobs, no objects on the server). The captured data lands on *your* workstation, and DuckDB is the local engine that does all the analysis. This means:

- **Zero standing overhead on the source** — you read the DMVs/catalog views once and disconnect.
- **Works on locked-down and managed platforms** — Azure SQL DB/MI, AWS RDS, Google Cloud SQL — where you cannot create server-side collectors. (Mind the DMV-availability caveats per platform; see the contract notes in `SKILL.md` and the per-capture comments.)
- **Iterate cheaply** — re-run the analysis library a hundred times, tweak thresholds, write new rules — none of it touches SQL Server again.

This **complements**, and does not replace, the live diagnostic skills (`sqlserver-monitoring` for live waits/Query Store/XEvents) or the bundled read-only `.sql` scripts in the sibling skills. Use those when you need *live, right-now* truth; use this skill when you want a consolidated, offline, repeatable advisory pass and the ability to **trend over time**.

---

## 2. Getting DuckDB

DuckDB is a single self-contained binary / library with no server to install. Any one of these is enough:

- **DuckDB CLI** — download the standalone `duckdb` executable from <https://duckdb.org/docs/installation/> (Windows/macOS/Linux). It is one file; put it on `PATH`. Start it with `duckdb advisor.duckdb` to open (or create) a persistent database file, or just `duckdb` for an in-memory session.
- **Python** — `pip install duckdb`, then `import duckdb`. The Python API runs the exact same SQL; `duckdb.connect("advisor.duckdb")` for a file, `duckdb.connect()` for in-memory.
- **Helper skills in this environment (preferred when available).** This environment may expose DuckDB helper skills and the `duckdb` CLI directly:
  - **`install-duckdb`** — install/update DuckDB extensions (e.g. for Parquet/HTTPFS if not already bundled).
  - **`attach-db`** — attach a DuckDB database file and explore its schema (tables, columns, row counts), writing a SQL state file so later queries auto-restore the session.
  - **`query`** — run SQL (or natural-language questions) against the attached DuckDB database or ad-hoc against files, using DuckDB Friendly-SQL idioms.
  - **`read-file`** — read/explore any data file (CSV, Parquet, JSON, …) locally or remotely with format auto-detection.
  - **`duckdb-docs`** — full-text search over DuckDB documentation when you need exact syntax.

  When these are present, you do not need to shell out manually — invoke the helper skill. When they are not, the plain CLI or Python API works identically.

DuckDB reads CSV and Parquet natively; CSV/Parquet readers are built in (no extension needed). Parquet trending only needs the bundled Parquet support.

---

## 3. Local Storage Model

You have two equivalent storage choices; both keep the capture immutable and the analysis offline.

**(a) DuckDB database file** — `duckdb advisor.duckdb`. `00-load.sql` creates one table per capture CSV; the tables persist in the `.duckdb` file so you can reopen and re-query without reloading. Good for a single server's working session.

**(b) In-memory + Parquet on disk** — `duckdb` (no file). Load the CSVs into memory for the session, optionally `COPY` them to **Parquet** for compact, typed, long-term storage and cross-run trending (§6). Good for ad-hoc analysis and for building a trend archive.

Either way the rule:

> **The `./capture/` files are the immutable source of truth. DuckDB tables are derived and disposable — you can always rebuild them by re-running `00-load.sql`.** The DuckDB table name **equals the capture file base name** (the contract): `server_info.csv` → table `server_info`, `index_usage.csv` → table `index_usage`, and so on.

### Capture layout

A single capture is a flat set of CSVs:

```
capture/
  server_info.csv      config.csv          db_inventory.csv
  tables.csv           columns.csv         indexes.csv
  index_usage.csv      missing_indexes.csv index_physical.csv
  foreign_keys.csv     query_stats.csv     wait_stats.csv
```

For **trending across multiple runs**, nest each run under `capture/<server>/<captured_at>/` (§6) so a glob can load and compare them.

---

## 4. The Workflow: load → analyze → report

The analysis library lives alongside this skill (conceptually under `analysis/`): `00-load.sql`, the rule files `a01-*.sql` … `a10-*.sql`, and the roll-up `a99-report.sql`.

### Step 1 — `00-load.sql`: create the 12 tables

`00-load.sql` points DuckDB at `./capture/` and creates one table per file with `read_csv_auto` (header + type inference on). One table per contract file:

```sql
-- 00-load.sql  (run once per session; safe to re-run — it replaces the tables)
CREATE OR REPLACE TABLE server_info     AS SELECT * FROM read_csv_auto('capture/server_info.csv');
CREATE OR REPLACE TABLE config          AS SELECT * FROM read_csv_auto('capture/config.csv');
CREATE OR REPLACE TABLE db_inventory    AS SELECT * FROM read_csv_auto('capture/db_inventory.csv');
CREATE OR REPLACE TABLE tables          AS SELECT * FROM read_csv_auto('capture/tables.csv');
CREATE OR REPLACE TABLE columns         AS SELECT * FROM read_csv_auto('capture/columns.csv');
CREATE OR REPLACE TABLE indexes         AS SELECT * FROM read_csv_auto('capture/indexes.csv');
CREATE OR REPLACE TABLE index_usage     AS SELECT * FROM read_csv_auto('capture/index_usage.csv');
CREATE OR REPLACE TABLE missing_indexes AS SELECT * FROM read_csv_auto('capture/missing_indexes.csv');
CREATE OR REPLACE TABLE index_physical  AS SELECT * FROM read_csv_auto('capture/index_physical.csv');
CREATE OR REPLACE TABLE foreign_keys    AS SELECT * FROM read_csv_auto('capture/foreign_keys.csv');
CREATE OR REPLACE TABLE query_stats      AS SELECT * FROM read_csv_auto('capture/query_stats.csv');
CREATE OR REPLACE TABLE wait_stats       AS SELECT * FROM read_csv_auto('capture/wait_stats.csv');
```

> `tables` and `columns` are reserved-ish words in some dialects; DuckDB accepts them as identifiers, but double-quote them (`"tables"`, `"columns"`) if a parser complains.

### Step 2 — `a01..a10`: run the rule library

Each rule file is a single `SELECT` that emits **exactly the unified findings shape** (see §5). They are pure reads — run any subset, or all of them. Each maps to one dimension (the full rule catalog with thresholds/caveats is in **`recommendation-rules.md`**; what each dimension means is in **`analysis-dimensions.md`**):

| File | Dimension | Primary captures it reads |
|---|---|---|
| `a01` | Table design | `tables`, `columns`, `indexes` |
| `a02` | Indexing — unused/duplicate/overlapping | `indexes`, `index_usage` |
| `a03` | Indexing — missing (consolidated) | `missing_indexes` |
| `a04` | Indexing — fragmentation/page fullness | `index_physical` |
| `a05` | Sizing & capacity | `tables`, `db_inventory` |
| `a06` | Statistics | `db_inventory` (auto-stats flags), `tables` |
| `a07` | Query hotspots | `query_stats` |
| `a08` | Configuration | `config`, `server_info`, `db_inventory` |
| `a09` | Configuration / waits context | `wait_stats`, `server_info` |
| `a10` | Table design — foreign keys / heaps | `foreign_keys`, `tables`, `indexes` |

(The exact file→rule mapping is the catalog's authority; the table above is the working layout.)

### Step 3 — `a99-report.sql`: the prioritized report

`a99` `UNION ALL`s every rule's findings (they all share the same column list) and orders them so **High** severity floats to the top, then by dimension:

```sql
-- a99-report.sql  — consolidate every rule into one prioritized advisory report
WITH findings AS (
    SELECT * FROM (/* paste or :include a01 */) 
    UNION ALL SELECT * FROM (/* a02 */)
    UNION ALL SELECT * FROM (/* a03 */)
    -- ... a04 .. a10 ...
)
SELECT
    CASE severity WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END AS severity_rank,
    dimension, database_name, object_name, severity,
    metric, finding, recommendation, why, consult_skill
FROM findings
ORDER BY severity_rank, dimension, database_name, object_name;
```

In the CLI, you can keep each rule in its own file and assemble the report with `.read`:

```
duckdb advisor.duckdb
D .read analysis/00-load.sql
D .read analysis/a99-report.sql      -- a99 itself .reads / inlines a01..a10
```

Or run a single rule interactively to inspect just one dimension:

```
D .read analysis/a07-query-hotspots.sql
```

The output is a ranked table of findings — each row tells the user **what is wrong (finding)**, **what to do (recommendation)**, **why it matters (why)**, the **evidence (metric)**, and **which sibling skill to consult for the remediation depth (consult_skill)**. Every recommendation is **advisory** — validate in non-prod before acting; see `recommendation-rules.md`.

---

## 5. The Loaded Table Schema (the capture contract)

These 12 tables are the contract — column names are load-bearing and shared by collectors and analysis. Every row carries `server_name` and `captured_at`; per-database tables also carry `database_name`. Key columns below; the full column list lives in `SKILL.md`.

1. **`server_info`** (one row) — `product_version`, `product_major_version`, `edition`, `engine_edition`, `host_cpu_count`, `host_physical_memory_mb`, `sql_memory_limit_mb`, `sqlserver_start_time`, `is_hadr_enabled`. *Establish version/edition/platform from here before any version-sensitive finding.*
2. **`config`** (one row per setting) — `config_name`, `value_in_use`, `minimum`, `maximum`.
3. **`db_inventory`** (one row per database) — `database_id`, `state_desc`, `recovery_model_desc`, `compatibility_level`, `is_read_committed_snapshot_on`, `is_snapshot_isolation_state_on`, `is_auto_create_stats_on`, `is_auto_update_stats_on`, `is_auto_update_stats_async_on`, `page_verify_option_desc`, `log_reuse_wait_desc`, `total_size_mb`.
4. **`tables`** (one row per user table) — `schema_name`, `table_name`, `object_id`, `is_heap`, `has_primary_key`, `has_clustered_columnstore`, `row_count`, `total_space_mb`, `used_space_mb`, `data_space_mb`, `index_space_mb`, `unused_space_mb`, `partition_count`, `data_compression_desc`.
5. **`columns`** (one row per column) — `table_name`, `column_name`, `column_id`, `data_type`, `max_length_bytes`, `precision`, `scale`, `is_nullable`, `is_computed`, `is_identity`, `collation_name`.
6. **`indexes`** (one row per index) — `table_name`, `object_id`, `index_name`, `index_id`, `index_type_desc`, `is_unique`, `is_primary_key`, `is_unique_constraint`, `is_disabled`, `is_filtered`, `fill_factor`, `key_column_list`, `included_column_list`.
7. **`index_usage`** (one row per index; LEFT JOIN so unused indexes appear with 0/NULL) — `index_name`, `index_id`, `user_seeks`, `user_scans`, `user_lookups`, `user_updates`, `last_user_seek`, `last_user_scan`, `last_user_lookup`, `last_user_update`.
8. **`missing_indexes`** (one row per suggestion) — `table_name`, `equality_columns`, `inequality_columns`, `included_columns`, `unique_compiles`, `user_seeks`, `user_scans`, `avg_total_user_cost`, `avg_user_impact`, `improvement_measure` (= `avg_total_user_cost * (avg_user_impact/100.0) * (user_seeks + user_scans)`).
9. **`index_physical`** (per DB; SAMPLED, `page_count >= 1000`) — `index_name`, `index_id`, `partition_number`, `index_type_desc`, `avg_fragmentation_in_percent`, `page_count`, `avg_page_space_used_in_percent`, `fragment_count`, `forwarded_record_count`.
10. **`foreign_keys`** (one row per FK) — `table_name`, `fk_name`, `referenced_schema`, `referenced_table`, `is_disabled`, `is_not_trusted`, `delete_referential_action_desc`, `update_referential_action_desc`, `parent_column_list`, `referenced_column_list`.
11. **`query_stats`** (top ~50 plan-cache queries) — `query_hash`, `execution_count`, `total_worker_time_ms`, `avg_worker_time_ms`, `total_logical_reads`, `avg_logical_reads`, `total_elapsed_time_ms`, `avg_elapsed_time_ms`, `total_grant_kb`, `sample_query_text`.
12. **`wait_stats`** (top waits, benign filtered) — `wait_type`, `waiting_tasks_count`, `wait_time_ms`, `signal_wait_time_ms`, `pct_of_total`.

### The unified findings shape

Every rule (`a01..a10`) `SELECT`s **exactly** these columns so `a99` can `UNION ALL` them with no casting:

| Column | Meaning |
|---|---|
| `dimension` | `'Table design'` \| `'Indexing'` \| `'Sizing & capacity'` \| `'Statistics'` \| `'Query hotspots'` \| `'Configuration'` |
| `database_name` | the database (or `NULL` for instance-level) |
| `object_name` | `schema.table[.index]` or `'(instance)'` |
| `severity` | `'High'` \| `'Medium'` \| `'Low'` |
| `metric` | the evidence, e.g. `'rows=12,000,000; frag=62%'` |
| `finding` | what is wrong / the smell |
| `recommendation` | what to do |
| `why` | one-line rationale / impact |
| `consult_skill` | `sqlserver-engineering` \| `sqlserver-operations` \| `sqlserver-infrastructure` \| `sqlserver-monitoring` |

---

## 6. Trending Across Multiple Capture Runs

The point of a *local* analytics engine is that you keep history cheaply and watch things **move** — table growth, fragmentation creep, new missing-index suggestions, configuration drift. Capture more than once and store each run separately.

### Layout: one folder per run

Land each capture under `capture/<server>/<captured_at>/` so the path itself encodes server and time:

```
capture/
  SQLPROD01/
    2026-05-01T0200Z/   tables.csv  index_physical.csv  ...
    2026-05-15T0200Z/   tables.csv  index_physical.csv  ...
    2026-05-28T0200Z/   tables.csv  index_physical.csv  ...
```

(The `captured_at` value is also *inside* every row per the contract, so you can trend purely from the data; encoding it in the path makes globbing and partition pruning easy.)

### Loading many runs with a glob

`read_csv_auto` and `read_parquet` accept globs and can add the source path as a column. Use `filename = true`:

```sql
-- Load every 'tables' capture across all runs into one trend table
CREATE OR REPLACE TABLE tables_trend AS
SELECT *
FROM read_csv_auto('capture/*/*/tables.csv', filename = true);
-- 'filename' column now holds e.g. 'capture/SQLPROD01/2026-05-15T0200Z/tables.csv'
-- (captured_at is already a column in the data — prefer it for time ordering)
```

For long-term storage, convert each run to **Parquet** once (typed, compact, columnar) and trend over Parquet instead of CSV:

```sql
-- One-time, per run: archive a capture as Parquet (still offline; no SQL Server involved)
COPY (SELECT * FROM read_csv_auto('capture/SQLPROD01/2026-05-28T0200Z/tables.csv'))
  TO 'archive/SQLPROD01/2026-05-28T0200Z/tables.parquet' (FORMAT PARQUET);

-- Trend over the Parquet archive
CREATE OR REPLACE TABLE tables_trend AS
SELECT * FROM read_parquet('archive/*/*/tables.parquet', filename = true);
```

### Hive partitioning (optional, cleaner pruning)

If you name folders `server=<name>/captured_at=<ts>/`, DuckDB derives `server` and `captured_at` as real columns and prunes by them:

```sql
SELECT * FROM read_parquet('archive/**/*.parquet', hive_partitioning = true)
WHERE server = 'SQLPROD01' AND captured_at >= '2026-05-01';
```

### Compare growth / fragmentation over time

With multiple runs loaded, trend with window functions or self-joins on the natural key (`server_name`, `database_name`, `schema_name`, `table_name`):

```sql
-- Table growth between consecutive captures (MB delta and % growth)
WITH t AS (
    SELECT server_name, database_name, schema_name, table_name,
           captured_at, row_count, total_space_mb,
           LAG(total_space_mb) OVER (
               PARTITION BY server_name, database_name, schema_name, table_name
               ORDER BY captured_at)            AS prev_space_mb,
           LAG(captured_at) OVER (
               PARTITION BY server_name, database_name, schema_name, table_name
               ORDER BY captured_at)            AS prev_captured_at
    FROM tables_trend
)
SELECT server_name, database_name, schema_name, table_name,
       prev_captured_at, captured_at,
       prev_space_mb, total_space_mb,
       total_space_mb - prev_space_mb                                   AS delta_mb,
       ROUND(100.0 * (total_space_mb - prev_space_mb)
             / NULLIF(prev_space_mb, 0), 1)                             AS pct_growth
FROM t
WHERE prev_space_mb IS NOT NULL
ORDER BY delta_mb DESC;
```

```sql
-- Fragmentation creep on large indexes between two captures
SELECT server_name, database_name, schema_name, table_name, index_name,
       captured_at, avg_fragmentation_in_percent, page_count
FROM read_parquet('archive/*/*/index_physical.parquet')
WHERE page_count >= 1000
ORDER BY server_name, database_name, schema_name, table_name, index_name, captured_at;
```

This is how you answer *"is this table growing 5% a week?"*, *"did fragmentation come back after the last rebuild?"*, or *"when did this configuration value change?"* — entirely offline, from the local archive.

---

## 7. Extending With Custom Rules

The library is meant to grow. To add a rule:

1. **Create a new `aNN-<name>.sql`** (pick an unused `NN`). Make it a single `SELECT` that emits **exactly the unified findings shape** (§5) — same column names, same order, same `dimension` vocabulary and `severity` values. The columns are the contract; if your rule doesn't have a value for one (e.g. instance-level rule with no `database_name`), `SELECT NULL AS database_name`.
2. **Read only the contract tables** (the 12 loaded by `00-load.sql`). Don't invent new captures unless you also extend the collectors and the contract.
3. **Use a clear `metric`** that shows the evidence (the numbers that triggered the rule) so a reviewer can sanity-check the threshold.
4. **Set `consult_skill`** to the sibling skill that owns the *how* (engineering / operations / infrastructure / monitoring).
5. **Register it in `a99`** — add one `UNION ALL SELECT * FROM (/* aNN */)` (or a `.read` include) so it appears in the consolidated report.
6. **Document it in `recommendation-rules.md`** — detection logic, threshold(s), severity, recommendation, rationale, and caveats — so the rule is reviewable, not a black box.

Skeleton for a new rule:

```sql
-- aNN-example.sql — emit the unified findings shape; reads only contract tables
SELECT
    'Sizing & capacity'                                       AS dimension,
    t.database_name                                           AS database_name,
    t.schema_name || '.' || t.table_name                      AS object_name,
    CASE WHEN t.total_space_mb >= 102400 THEN 'High'
         WHEN t.total_space_mb >= 10240  THEN 'Medium'
         ELSE 'Low' END                                       AS severity,
    'rows=' || format('{:,}', t.row_count)
        || '; size=' || ROUND(t.total_space_mb / 1024.0, 1) || ' GB'  AS metric,
    'Very large table with no data compression'               AS finding,
    'Evaluate ROW/PAGE compression in non-prod; measure CPU vs I/O trade-off' AS recommendation,
    'Compression cuts I/O and buffer-pool footprint at a CPU cost'            AS why,
    'sqlserver-engineering'                                    AS consult_skill
FROM "tables" AS t
WHERE t.total_space_mb >= 10240
  AND (t.data_compression_desc = 'NONE' OR t.data_compression_desc IS NULL)
ORDER BY t.total_space_mb DESC;
```

> Keep DuckDB SQL **standard and portable**: `read_csv_auto` / `read_parquet`, `CREATE OR REPLACE TABLE`, `LAG`/`LEAD` window functions, `||` for string concat, `NULLIF` to guard division. These behave identically in the CLI and the Python API.

---

## 8. Cross-References

- **What each rule detects, its thresholds, and its caveats** → `recommendation-rules.md`.
- **What each of the six dimensions means and which captures feed it** → `analysis-dimensions.md`.
- **Remediation depth (the "how" behind each recommendation):**
  - design / indexing / plans / statistics → **`sqlserver-engineering`**
  - maintenance / sizing / backup / DBCC → **`sqlserver-operations`**
  - instance/OS config / tempdb / memory / MAXDOP → **`sqlserver-infrastructure`**
  - live waits / Query Store / blocking → **`sqlserver-monitoring`**, including the community-tools doc (Brent Ozar First Responder Kit, Erik Darling PerformanceMonitor) this skill's Lite pattern is modeled on.
- **Remediation T-SQL** is never run by this skill; it belongs to the deeper skills and follows the plugin change-class convention (`[SCHEMA CHANGE]` / `[CONFIG CHANGE]` / `[DATA-LOSS RISK]` tags; never inline a runnable destructive command).
