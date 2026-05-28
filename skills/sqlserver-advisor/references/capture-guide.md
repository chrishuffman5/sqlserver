# Capture Guide — Stage 2 of the Advisor Pipeline

This is the operational guide for the **CAPTURE** stage: running the read-only collectors against a target SQL Server and landing one CSV per capture under `./capture/`. Everything here is **read-only** — `SELECT`/export only. No collector writes data, changes configuration, or runs DDL; the source instance pays only the cost of one query pass. After capture you `LOAD` into DuckDB (`analysis/00-load.sql`) and `ANALYZE` (`analysis/a*.sql`) entirely on your workstation, with zero further load on the server.

> **Permissions (read-only).** The collectors need the standard read-only diagnostic set: **`VIEW SERVER STATE`** at the instance (or, on 2022+, the least-privilege **`VIEW SERVER PERFORMANCE STATE`**), **`VIEW DATABASE STATE`** in each database analyzed, and read access to the catalog views (`db_datareader`, or membership that grants `SELECT` on `sys.*`). No `sysadmin`, no `db_owner`, no elevated rights are required to *capture*. On managed platforms the available subset is smaller (see [Per-platform notes](#per-platform-notes)).

## The contract you are filling

Each collector `collectors/NN-<name>.sql` produces the columns of capture item `<name>` and must land at `capture/<name>.csv`. **The file base name is the DuckDB table name** — keep it exact (`tables.csv` → table `tables`). Every row carries `server_name` (`SERVERPROPERTY('ServerName')`) and `captured_at` (`SYSUTCDATETIME()`); the per-database collectors (04–10) also carry `database_name` (`DB_NAME()`).

| Collector | Output file | Scope |
|---|---|---|
| `01-server_info.sql` | `server_info.csv` | instance (once) |
| `02-config.sql` | `config.csv` | instance (once) |
| `03-db_inventory.sql` | `db_inventory.csv` | instance (once; one row per DB) |
| `04-tables.sql` | `tables.csv` | **per-DB** |
| `05-columns.sql` | `columns.csv` | **per-DB** |
| `06-indexes.sql` | `indexes.csv` | **per-DB** |
| `07-index_usage.sql` | `index_usage.csv` | **per-DB** |
| `08-missing_indexes.sql` | `missing_indexes.csv` | **per-DB** |
| `09-index_physical.sql` | `index_physical.csv` | **per-DB** (SAMPLED, `page_count >= 1000`) |
| `10-foreign_keys.sql` | `foreign_keys.csv` | **per-DB** |
| `11-query_stats.sql` | `query_stats.csv` | instance (once) |
| `12-wait_stats.sql` | `wait_stats.csv` | instance (once) |

`03` is **instance-level inventory** — it emits one row per database from `sys.databases`/`sys.master_files` and runs once. `04`–`10` are **per-database**: run each once per online user database, appending all databases into a single CSV. `01`–`02` and `11`–`12` are instance-level and run once. The per-DB collectors must execute **in the context of the database being captured** (so `DB_NAME()`, the object catalog, and `sys.dm_db_*` resolve to that DB) — set this with `-Database` (PowerShell) or `:setvar` / `USE` (sqlcmd).

## Recommended path — Windows PowerShell + Invoke-Sqlcmd

`Invoke-Sqlcmd` (SqlServer module) runs a collector file and returns rows; pipe to `Export-Csv -NoTypeInformation` to land the contract CSV. Install once with `Install-Module -Name SqlServer -Scope CurrentUser`.

### 0. Set up

```powershell
# --- Edit these for your environment ---
$ServerInstance = 'PRODSQL01\INST1'           # or 'tcp:myserver.database.windows.net,1433'
$CaptureRoot    = 'C:\Users\chris\Github\sqlserver\skills\sqlserver-advisor'
$Collectors     = Join-Path $CaptureRoot 'collectors'
$Capture        = Join-Path $CaptureRoot 'capture'

# Use a dated capture folder so you can keep history and TREND across runs.
$RunStamp  = (Get-Date -Format 'yyyyMMdd-HHmmss')
$Capture   = Join-Path $Capture $RunStamp
New-Item -ItemType Directory -Force -Path $Capture | Out-Null

# Authentication: integrated by default. For SQL/Azure auth add -Credential or -AccessToken.
$Common = @{ ServerInstance = $ServerInstance; QueryTimeout = 0; TrustServerCertificate = $true }
# Azure AD example: $Common += @{ AccessToken = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/').Token }
```

### 1. Instance-level collectors (run once)

```powershell
foreach ($name in 'server_info','config','db_inventory','query_stats','wait_stats') {
    # Map name -> NN-<name>.sql
    $file = Get-ChildItem -Path $Collectors -Filter "*-$name.sql" | Select-Object -First 1
    $out  = Join-Path $Capture "$name.csv"
    Write-Host "Capturing $name -> $out"
    Invoke-Sqlcmd @Common -Database 'master' -InputFile $file.FullName |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path $out
}
```

`db_inventory` (collector `03`) is instance-level and reads `sys.databases` from `master`; it does not need a per-DB loop even though it emits one row per database.

### 2. Per-database collectors (loop over every online user database)

Enumerate user databases the same way the contract specifies (`database_id > 4 AND state = 0` — skip the four system DBs and anything offline/restoring), then run collectors `04`–`10` in each DB's context and **append** to one CSV per collector.

```powershell
# Discover online USER databases (excludes master/tempdb/model/msdb; skips offline/restoring)
$dbQuery = "SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 ORDER BY name;"
$userDbs = (Invoke-Sqlcmd @Common -Database 'master' -Query $dbQuery).name

# Per-DB collectors in run order
$perDb = 'tables','columns','indexes','index_usage','missing_indexes','index_physical','foreign_keys'

# Start each per-DB CSV empty so we can append across databases
foreach ($name in $perDb) { Remove-Item (Join-Path $Capture "$name.csv") -ErrorAction SilentlyContinue }

foreach ($db in $userDbs) {
    Write-Host "=== Database: $db ==="
    foreach ($name in $perDb) {
        $file = Get-ChildItem -Path $Collectors -Filter "*-$name.sql" | Select-Object -First 1
        $out  = Join-Path $Capture "$name.csv"
        $rows = Invoke-Sqlcmd @Common -Database $db -InputFile $file.FullName -QueryTimeout 0
        if ($null -ne $rows) {
            if (Test-Path $out) {
                # Append without re-writing the header
                $rows | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 |
                    Add-Content -Encoding UTF8 -Path $out
            } else {
                $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $out
            }
        }
    }
}
Write-Host "Capture complete: $Capture"
```

Notes on robustness:

- **Quoting / commas / newlines.** `Export-Csv` (and `ConvertTo-Csv`) RFC-quote fields containing commas, quotes, or line breaks automatically — important for `key_column_list`, `included_column_list`, and `sample_query_text`. Do **not** hand-build CSV with string concatenation; let the cmdlet quote. DuckDB's `read_csv_auto` reads this quoting natively.
- **Encoding.** Force `-Encoding UTF8` everywhere so non-ASCII object names and collations survive; DuckDB expects UTF-8.
- **Append correctly.** The `ConvertTo-Csv | Select-Object -Skip 1 | Add-Content` idiom appends rows from later databases without duplicating the header. The first database creates the header via `Export-Csv`.
- **`-QueryTimeout 0`** disables the client timeout for the large catalog scans (`tables`, `index_physical`); the work is still read-only.
- **Empty results are normal.** A database with no foreign keys yields no `foreign_keys` rows for that DB — the loop simply contributes nothing, which is correct.

## Alternative — sqlcmd

When PowerShell/`Invoke-Sqlcmd` is unavailable, `sqlcmd` exports CSV with comma separator and minimal headers. The collectors return a single result set each, so this maps cleanly:

```bat
sqlcmd -S PRODSQL01\INST1 -d master -E -b -W -s "," -h -1 ^
       -i collectors\01-server_info.sql -o capture\server_info.csv
```

- `-s ","` sets the field separator, `-W` trims trailing spaces, `-h -1` suppresses the header/dashes row. With `-h -1` you must **prepend the header row yourself** (the column order is the contract) or load in DuckDB with explicit column names — prefer the `Invoke-Sqlcmd` path, which preserves headers and proper quoting. `sqlcmd` does **not** RFC-quote embedded commas/newlines, so it is risky for `sample_query_text`/column-list fields; reserve it for the simpler instance collectors or post-process carefully.
- For the per-DB loop, drive `-d <db>` from a shell `for` loop over the `database_id > 4 AND state = 0` list, redirecting each collector's output and concatenating.
- `-b` makes sqlcmd return a non-zero exit code on error so a wrapping script can detect failures.

## bcp and Parquet notes

- **`bcp` / `queryout`** is the highest-throughput export for very large captures (e.g. `columns` on a wide schema): `bcp "<query>" queryout columns.csv -c -t"," -S <server> -T`. It is read-only (a `SELECT`), but like `sqlcmd` it does not quote embedded delimiters — wrap text fields or use a non-comma terminator (`-t"|"`) and tell DuckDB `delim='|'`. For a contract this column-rich, the `Invoke-Sqlcmd` path is safer; reach for `bcp` only when CSV size/throughput is a real constraint.
- **Parquet for trending.** CSV is the canonical capture format (human-readable, what the collectors emit). For **multi-run trending** and compact history, convert each dated capture to Parquet *in DuckDB* after loading — e.g. `COPY tables TO 'history/tables_20260528.parquet' (FORMAT PARQUET);` — then stack the dated Parquet files (`read_parquet('history/tables_*.parquet')`) and group by `captured_at`/`server_name`. This keeps a year of weekly captures small and lets `a05` (sizing) compute growth deltas across runs. SQL Server itself never produces Parquet here — DuckDB does, locally.

## Least-impact guidance

The capture is one read-only pass, but two collectors deserve care on a busy production box:

- **`09-index_physical.sql` (`sys.dm_db_index_physical_stats`)** is the only collector that reads index pages. Always run it in **`SAMPLED`** mode (the collector default) and **filtered to `page_count >= 1000`** — fragmentation on tiny indexes is noise. Run it **off-peak** if possible. If even SAMPLED is too heavy on a critical instance, switch the collector's mode to **`LIMITED`** (reads only the upper b-tree levels — cheapest, but `avg_page_space_used_in_percent` and `forwarded_record_count` come back NULL; the analysis tolerates this). `DETAILED` is the most accurate but the most expensive — **do not** use it for a routine capture.
- **`11-query_stats.sql`** reads the plan cache (`sys.dm_exec_query_stats` + `sys.dm_exec_sql_text`/`sys.dm_exec_query_plan` cross-applies). It is read-only and bounded to the **top ~50** rows, but the text/plan cross-applies have a small cost — fine to run during business hours; avoid running it in a tight loop.

The remaining collectors read catalog and usage DMVs (cheap, metadata-only). Run the whole capture during a representative window — capturing during a quiet maintenance hour can make a busy index *look* unused (`index_usage` counters are cumulative **since service restart**, so note `sqlserver_start_time` from `server_info` when interpreting usage and waits).

> **Volatile-DMV caveat (important).** `sys.dm_db_index_usage_stats` and the missing-index DMVs (`sys.dm_db_missing_index_*`) are **in-memory and reset**: they clear on service restart, and — critically — they are **wiped whenever a database closes**. On a database with **`AUTO_CLOSE` ON** (the default for new databases on **SQL Server Express**, and occasionally inherited elsewhere) the database closes as soon as the last connection drops, so the next collector connection sees them **empty** and `index_usage`/`missing_indexes` capture as all-zero / no rows even though the workload generated activity. Before trusting an "unused index" (`a04`) or "missing index" (`a06`) finding: (1) confirm `is_auto_close_on = 0` for the database (`SELECT is_auto_close_on FROM sys.databases`), and turn it OFF if it is on (`ALTER DATABASE [db] SET AUTO_CLOSE OFF;` — itself a worthwhile fix on a server database); (2) ensure the instance has been up and serving the real workload for a representative period (check `sqlserver_start_time`); and (3) capture the usage/missing-index collectors against a warm cache rather than immediately after a restart. The structural collectors (catalog/space) are unaffected.

## Per-platform notes

Establish `engine_edition` first (`server_info.engine_edition`); it dictates which collectors return full rows.

- **Azure SQL Database (engine_edition 5).** Connect **per database** — there is no instance-wide cross-DB context, so the "loop over `sys.databases`" step is replaced by **one capture per database connection** (`-Database <db>` pointed at each database). Host DMVs are absent/scoped: `host_cpu_count`, `host_physical_memory_mb`, `sql_memory_limit_mb`, `sqlserver_start_time`, and several `config` settings come back NULL or empty — that is expected, the analysis tolerates it. `wait_stats` should use `sys.dm_db_wait_stats` (database-scoped) rather than the instance view; the collector version-guards this. Resource pressure (DTU/vCore) lives in `sys.dm_db_resource_stats` — out of scope here; see `sqlserver-cloud`. This per-database, local-store mode is exactly the situation PerformanceMonitor Lite is built for.
- **Azure SQL Managed Instance (engine_edition 8).** Behaves close to box: instance-wide DMVs and the per-DB loop work normally. Most host fields populate. Capture as you would box.
- **AWS RDS for SQL Server.** Box engine, but **no `sysadmin`** and **restricted host DMVs** — some server-scoped fields (certain `sys.dm_os_sys_info` columns, `sys.dm_server_services`) may be unavailable, so those `server_info`/`config` cells can be NULL. The structural and usage collectors (03–10) work with the read-only permission set; the capture is still fully useful. Connect to the RDS endpoint; the per-DB loop over `database_id > 4` works.
- **Google Cloud SQL for SQL Server.** Similar to RDS — managed box engine with restricted server-level access; expect partial host fields and rely on the structural/usage collectors. Per-DB loop applies.
- **SQL on Azure VM / box on Windows/Linux/containers.** Full surface; all collectors return complete rows with `VIEW SERVER STATE` + `VIEW DATABASE STATE`.

## Multi-run trending — why every row is stamped

Every capture row carries **`captured_at`** (UTC capture time) and **`server_name`**. Capture into a **new dated folder** on a schedule (e.g. weekly), load each into DuckDB (or stack as Parquet — see above), and the analysis can:

- **Trend growth** — diff `tables.total_space_mb` / `row_count` by `captured_at` to see which tables are growing fastest (feeds `a05` Sizing & capacity).
- **Confirm "unused" before dropping** — an index unused across *several* captures spanning restarts is far stronger evidence than one snapshot taken right after a restart.
- **Watch config/compat drift** — compare `config` and `db_inventory` across runs to catch settings that changed.
- **Compare instances** — group by `server_name` to baseline a fleet from one local store.

Because the stamping is uniform and the table-name == file-name contract is stable, multi-run analysis is just an extra `GROUP BY captured_at` / `read_parquet('history/*_*.parquet')` — no schema changes, no re-querying the source.

## Read-only reminder

Every file under `collectors/` is a `SELECT`/export only — no `INSERT`/`UPDATE`/`DELETE`, no `sp_configure`/`RECONFIGURE`, no DDL, no writing `DBCC`. Review any bundled script before running it in production (plugin policy). The **recommendations** that come out of Stage 4 are advisory — validate them in non-production and apply the actual remediation through the deeper skills (`sqlserver-engineering` / `sqlserver-operations` / `sqlserver-infrastructure`), which tag every mutating example with its change class.
