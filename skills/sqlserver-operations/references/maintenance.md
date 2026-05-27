# Maintenance Reference

Routine maintenance keeps the optimizer well-informed (statistics), keeps physical structures efficient (index reorg/rebuild), and proves the data is intact (DBCC CHECKDB). This reference covers thresholds, the correct T-SQL, the corruption decision tree, the Ola Hallengren solution, and scheduling. Box 2016–2025 unless noted; PaaS differences inline.

## Index Maintenance

### Why fragmentation matters (and when it doesn't)

Two kinds: **logical/external fragmentation** (leaf pages out of physical order — hurts range scans/read-ahead) and **internal fragmentation / low page density** (pages partly empty — wastes buffer pool and I/O). It only matters at scale: a 50-page index that is 90% fragmented is irrelevant. Filter on `page_count` (commonly ≥ 1,000, often ≥ 8,000 / 64 MB) before acting.

### Thresholds

| `avg_fragmentation_in_percent` | Action | Statement | Logging / locking |
|---|---|---|---|
| < 10% | None | — | — |
| 10–30% | Reorganize | `ALTER INDEX … REORGANIZE` | Always online, minimally logged, interruptible (keeps work done) |
| > 30% | Rebuild | `ALTER INDEX … REBUILD` | Offline by default; ONLINE with edition support; fully logged unless Bulk-logged |

These are guidelines, not laws. For some workloads, updating statistics matters more than defragmenting; for ever-increasing clustered keys with append-only inserts, fragmentation barely accrues.

### Finding fragmentation

```sql
SELECT
    DB_NAME()                               AS database_name,
    OBJECT_SCHEMA_NAME(ips.object_id)       AS schema_name,
    OBJECT_NAME(ips.object_id)              AS table_name,
    i.name                                  AS index_name,
    ips.index_type_desc,
    ips.avg_fragmentation_in_percent,
    ips.avg_page_space_used_in_percent,     -- page density
    ips.page_count,
    CASE
        WHEN ips.page_count < 1000 THEN 'none (too small)'
        WHEN ips.avg_fragmentation_in_percent < 10 THEN 'none'
        WHEN ips.avg_fragmentation_in_percent < 30 THEN 'reorganize'
        ELSE 'rebuild'
    END                                     AS recommended_action
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN sys.indexes i
    ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.index_id > 0           -- skip heaps
ORDER BY ips.avg_fragmentation_in_percent DESC;
```

Use `LIMITED` (cheapest, reads only level above leaf), `SAMPLED`, or `DETAILED` (most expensive, full scan). Always `LIMITED` for routine assessment.

### Reorganize

```sql
ALTER INDEX [IX_Orders_CustomerId] ON dbo.Orders REORGANIZE;
-- Compact LOB pages too:
ALTER INDEX ALL ON dbo.Orders REORGANIZE WITH (LOB_COMPACTION = ON);
```

Reorganize is always online and minimally logged, and is safely interruptible — it keeps the reordering done so far. It uses the existing `FILLFACTOR`; it does not change it.

### Rebuild

```sql
-- Basic offline rebuild (recreates the index; resets fill factor; updates stats with FULLSCAN as a side effect)
ALTER INDEX [IX_Orders_CustomerId] ON dbo.Orders REBUILD WITH (FILLFACTOR = 90);

-- Online + resumable, with a time box
ALTER INDEX [IX_Orders_CustomerId] ON dbo.Orders
REBUILD WITH (ONLINE = ON, RESUMABLE = ON, FILLFACTOR = 90, MAX_DURATION = 90 MINUTES);
```

A rebuild fully recreates the index. Online rebuilds use extra space (a shadow copy) and a brief schema-modification lock at start/finish; offline rebuilds hold the lock throughout. A rebuild updates that index's statistics with the equivalent of FULLSCAN as a byproduct — do **not** also re-run `UPDATE STATISTICS WITH FULLSCAN` on the same index afterward (wasted work; and a `RESAMPLE` could *lower* the quality).

#### Edition / version gates

- **ONLINE rebuild**: Enterprise on 2016–2019. **Standard gained ONLINE index rebuild in 2019+** (with caveats), and it is broadly available in **2022+**. Always verify for the exact build/edition. `ONLINE` cannot be used when the index has certain LOB columns on older versions.
- **RESUMABLE rebuild**: **2017+** (and Azure SQL DB). Resumable lets you `PAUSE`/`RESUME`/`ABORT` and survive failovers, processing in chunks:

  ```sql
  ALTER INDEX [IX_Big] ON dbo.BigTable PAUSE;
  ALTER INDEX [IX_Big] ON dbo.BigTable RESUME;
  ALTER INDEX [IX_Big] ON dbo.BigTable ABORT;
  -- Monitor resumable operations:
  SELECT * FROM sys.index_resumable_operations;
  ```

- **RESUMABLE create** (`CREATE INDEX ... WITH (RESUMABLE = ON)`): **2019+**.

### Fill factor

Fill factor reserves free space on leaf pages at build time to absorb future inserts/updates without page splits. Lower fill factor (e.g., 80–90) reduces splits for volatile indexes but wastes space and reads for static ones. Leave 0/100 for read-mostly and ever-increasing keys; lower only for indexes that demonstrably split a lot. It is applied at rebuild (not reorganize).

### Heaps

Heaps (no clustered index) can become bloated by forwarded records. `ALTER TABLE … REBUILD` rebuilds a heap, but the better long-term fix is usually to add an appropriate clustered index — see **sqlserver-engineering** for clustered-key design.

## Statistics Maintenance

Statistics feed the optimizer's cardinality estimates. Stale or poorly sampled stats produce bad row estimates → bad plans → slow queries. Statistics and index maintenance are *separate* concerns: rebuilding fixes physical layout; updating stats fixes the optimizer's view.

### Auto vs manual

- Keep **`AUTO_CREATE_STATISTICS`** and **`AUTO_UPDATE_STATISTICS`** ON (defaults).
- Enable **`AUTO_UPDATE_STATISTICS_ASYNC`** for OLTP so the triggering query doesn't stall waiting for the stats update (the update runs in the background; that query uses the old stats once).

  ```sql
  ALTER DATABASE [MyDB] SET AUTO_UPDATE_STATISTICS_ASYNC ON;
  ```

- The **auto-update threshold** historically required ~20% of rows to change before a refresh. **Trace flag 2371** lowers this dynamically for large tables and is the **default behavior from 2016+** (compat level 130+) — only set TF 2371 manually on **2014 and earlier**.

### Manual updates

```sql
-- Full scan: most accurate, most expensive — use for important large tables in the window
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;

-- Specific statistic, sampled
UPDATE STATISTICS dbo.Orders [IX_Orders_OrderDate] WITH SAMPLE 50 PERCENT;

-- All stats in a DB (Ola's IndexOptimize / sp_updatestats do this intelligently)
EXEC sp_updatestats;
```

Prefer `FULLSCAN` for skewed/large tables where auto-sampling misestimates. Avoid blindly `sp_updatestats` everywhere nightly on huge databases — it can be very heavy; let Ola's modification-counter-aware logic choose.

### Inspecting statistics

```sql
SELECT
    OBJECT_SCHEMA_NAME(s.object_id) AS schema_name,
    OBJECT_NAME(s.object_id)        AS table_name,
    s.name                          AS stats_name,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    sp.modification_counter,        -- rows changed since last update
    CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows,0) AS DECIMAL(5,2)) AS sampled_pct
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
ORDER BY sp.modification_counter DESC;
```

`sys.dm_db_stats_properties` is **2008 R2 SP2 / 2012 SP1+** — universally available on supported versions. `sys.dm_db_stats_histogram` (2016 SP1 CU2+) exposes the histogram programmatically.

## Integrity: DBCC CHECKDB

`DBCC CHECKDB` is the authoritative integrity check. Run it regularly (weekly is the common baseline; more often for critical DBs). It checks allocation consistency, table/index/system-table structures, indexed-view integrity, and (with `DATA_PURITY`) that column values are valid for their type.

```sql
DBCC CHECKDB ([MyDB]) WITH NO_INFOMSGS, ALL_ERRORMSGS, DATA_PURITY;
```

| Option | Effect |
|---|---|
| `NO_INFOMSGS` | Suppresses the thousands of informational rows; show only problems. Always use. |
| `ALL_ERRORMSGS` | Show all error messages (not just the first 200 per object). |
| `DATA_PURITY` | Validate column values. Automatic for DBs created on 2005+; explicitly request for upgraded older DBs. |
| `PHYSICAL_ONLY` | Faster check (allocation + page integrity, skips deep logical checks). Use on huge DBs between full checks. |
| `ESTIMATEONLY` | Estimate tempdb needed, don't run the check. |
| `WITH TABLOCK` | Use locks instead of an internal DB snapshot (smaller footprint, but blocks). Snapshot (default) is preferred. |
| `EXTENDED_LOGICAL_CHECKS` | Deeper checks on indexed views, XML/spatial indexes. |

Related, narrower commands: **`DBCC CHECKTABLE`** (one table — lets you spread checks across nights for a VLDB), **`DBCC CHECKALLOC`** (allocation only), **`DBCC CHECKCATALOG`** (system catalog consistency). For a VLDB that can't finish a full CHECKDB in the window, a common pattern is `PHYSICAL_ONLY` nightly plus a rotating set of `CHECKTABLE`/filegroup checks (`DBCC CHECKFILEGROUP`).

`DBCC CHECKDB` runs against an internal snapshot, so it needs free space on the data volume; on a volume with little free space it may fall back to `TABLOCK`. CHECKDB is heavy on I/O and tempdb — schedule it in the maintenance window. On read-scale AGs, you can offload integrity checks to a secondary.

> **Platform note:** Azure SQL DB/MI run automated integrity checks behind the scenes and continuously detect corruption (and auto-repair via replicas), but you can still run `DBCC CHECKDB` yourself. On RDS you can run CHECKDB; the OS-level repair paths differ.

## Corruption Handling Decision Tree

When CHECKDB reports errors:

1. **Stay calm; do not run REPAIR yet.** Record the full output: database, object IDs, page IDs, and the specific error numbers. Re-run `DBCC CHECKDB (...) WITH NO_INFOMSGS, ALL_ERRORMSGS` to confirm it's reproducible.
2. **Suspect the hardware/I/O subsystem first.** Corruption is almost always caused by storage. Check the SQL error log and OS event log for **823** (I/O failed), **824** (logical consistency error), **825** (read had to be retried — early warning). Query `msdb.dbo.suspect_pages`.
3. **Assess scope.** A few pages in one nonclustered index? You can often rebuild that index to fix it. Pages in a clustered index/heap (the data itself) or system tables? That's data loss territory — go to backups.
4. **Restore from backup — the correct fix.** If you have a good chain:
   - **Page restore** for a small number of corrupt pages (Enterprise online / Standard offline) — minimal downtime, zero data loss. See `backup-recovery.md`.
   - **Full restore + log roll-forward + tail-log** to recover the database with zero data loss.
5. **`REPAIR_ALLOW_DATA_LOSS` is the last resort.** It is *not* a fix — it makes the database *consistent again* by **deallocating the corrupt pages and the data on them**. Requires `SINGLE_USER`. Procedure:
   - Take a backup of the corrupt database first (so you can try other recovery later).
   - `ALTER DATABASE [MyDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;`
   - `DBCC CHECKDB ([MyDB], REPAIR_ALLOW_DATA_LOSS) WITH ALL_ERRORMSGS;`
   - `ALTER DATABASE [MyDB] SET MULTI_USER;`
   - Re-run `DBCC CHECKDB` to confirm clean, then **figure out what data was lost** (restore a copy elsewhere to compare) and reconcile.
   - `REPAIR_REBUILD` (no data loss) only fixes minor nonclustered-index issues — try it before the data-loss option when applicable.
6. **Root-cause the storage.** A repair/restore that doesn't fix the failing disk just buys time until the next corruption.

```sql
-- Pages flagged as suspect (corruption history)
SELECT DB_NAME(database_id) AS database_name, file_id, page_id,
       event_type,   -- 1=823/824, 2=bad checksum, 3=torn page, 4=restored, 5=repaired, 7=deallocated
       error_count, last_update_date
FROM msdb.dbo.suspect_pages
ORDER BY last_update_date DESC;
```

### Last-known-good CHECKDB date

SQL Server stamps the date of the last clean `DBCC CHECKDB` into the database boot page (`dbi_dbccLastKnownGood`). Reading it directly requires `DBCC PAGE` / `DBCC DBINFO` with trace flag 3604, which is **intrusive and undocumented** — avoid in routine scripts. Safer operational signals: parse the error log for the "DBCC CHECKDB ... found 0 errors" message, track CHECKDB job success in `msdb` job history, or run CHECKDB on a known schedule and alert on failure. `scripts/07-integrity-status.sql` uses the safe approaches and documents the `dbi_dbccLastKnownGood` method in comments.

## Ola Hallengren's Maintenance Solution

The free, industry-standard maintenance toolkit (`MaintenanceSolution.sql` from ola.hallengren.com). Three core procedures plus a `CommandExecute` helper and logging table:

- **`IndexOptimize`** — fragmentation- and page-count-aware: reorganizes 5–30%, rebuilds >30% (configurable), updates statistics by modification counter, supports ONLINE/RESUMABLE, time limits, and per-database/-table targeting. Far smarter than GUI Maintenance Plans, which rebuild everything blindly.
- **`DatabaseIntegrityCheck`** — runs `DBCC CHECKDB` (with `PHYSICAL_ONLY` option, filegroup rotation, etc.) and logs results.
- **`DatabaseBackup`** — full/diff/log to DISK or URL with COMPRESSION/CHECKSUM/VERIFY/encryption, retention-based cleanup, and chain-safe deletion.

```sql
-- Typical IndexOptimize invocation (assessment + action, fragmentation-aware)
EXEC dbo.IndexOptimize
    @Databases = 'USER_DATABASES',
    @FragmentationLow = NULL,
    @FragmentationMedium = 'INDEX_REORGANIZE,INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
    @FragmentationHigh = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
    @FragmentationLevel1 = 5, @FragmentationLevel2 = 30,
    @PageCountLevel = 1000,
    @UpdateStatistics = 'ALL', @OnlyModifiedStatistics = 'Y';
```

Schedule the procedures as SQL Agent jobs (the solution can create them). On **Managed Instance** Ola works as on box. On **Azure SQL Database** (no Agent, no cross-DB) use the single-database variants via Elastic Jobs — see `agent-jobs.md`. On **RDS**, Ola works with RDS's permission constraints (use the RDS backup procs rather than `DatabaseBackup` for native backups when required).

## Maintenance Windows and Scheduling

- **Sequence:** integrity check → index maintenance → statistics → backups (so a backup captures the freshly maintained DB, and you don't back up a corrupt DB unknowingly — though CHECKDB on the *restored copy* is the real safety net).
- **Right-size to the window.** Use RESUMABLE rebuilds and `MAX_DURATION` / Ola time limits so a long rebuild doesn't bleed into business hours. Prefer reorganize (interruptible) when time is tight.
- **Frequency baseline:** index/stats nightly or weekly per write volume; `DBCC CHECKDB` weekly; test restore monthly; full DR drill quarterly.
- **Watch log and backup growth:** heavy rebuilds generate large transaction-log volume (and large log backups). On Full recovery, ensure log backups keep pace; consider Bulk-logged just for a massive one-off rebuild window, then back to Full.
- **HA:** offload `DBCC CHECKDB` and even backups to a readable secondary where licensing/feature allows (set the AG's `automated_backup_preference`) — see **sqlserver-ha-clustering**.
