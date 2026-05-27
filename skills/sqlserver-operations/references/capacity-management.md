# Capacity and Space Management Reference

Operational space management keeps databases healthy and growth predictable: file sizing and autogrowth, Instant File Initialization, data/log file layout, VLF management, why shrink is harmful (and the rare time it's acceptable), growth trending, and the servicing/patching model (CU cadence, test, rollback, rolling upgrade). Box 2016–2025 unless noted; PaaS differences inline.

## File Growth and Autogrowth

Every data (`.mdf`/`.ndf`) and log (`.ldf`) file has an initial size, a max size, and an autogrowth setting. Autogrowth is a **safety net, not a sizing strategy** — relying on it for routine growth causes stalls and fragmentation.

Best practices:

- **Pre-size files** to their expected size (plus headroom) so autogrowth rarely fires during business hours.
- **Fixed MB growth, not percentage.** Percentage growth means ever-larger, unpredictable growth events as the file grows (e.g., 10% of 500 GB = 50 GB in one stall). Use a fixed increment sized to the database — commonly 256 MB–1 GB for data, 256 MB–1 GB for logs (log increment also drives VLF count, see below).
- **Set a sane max size** so a runaway query can't fill the volume.
- **Match files within a filegroup.** Equal size + equal growth lets SQL Server's proportional-fill algorithm spread writes evenly (especially important for tempdb — see **sqlserver-infrastructure**).

```sql
-- Inspect file sizes and growth settings
SELECT
    DB_NAME(mf.database_id)              AS database_name,
    mf.name                             AS logical_name,
    mf.type_desc,
    mf.size  * 8 / 1024                  AS size_mb,
    mf.max_size,                         -- -1 = unlimited, in 8KB pages otherwise
    mf.is_percent_growth,
    CASE WHEN mf.is_percent_growth = 1
         THEN CAST(mf.growth AS VARCHAR(10)) + ' %'
         ELSE CAST(mf.growth * 8 / 1024 AS VARCHAR(10)) + ' MB' END AS autogrowth
FROM sys.master_files mf
ORDER BY database_name, mf.type_desc;

-- Set a sensible fixed growth (example: 512 MB)
ALTER DATABASE [MyDB] MODIFY FILE (NAME = N'MyDB', FILEGROWTH = 512MB);
```

## Instant File Initialization (IFI)

Normally SQL Server zero-initializes new file space before use. **IFI** lets *data file* allocations (create, autogrow, restore) skip zeroing, turning multi-minute growth/restore into near-instant operations.

- Grant the SQL Server service account the Windows policy **"Perform Volume Maintenance Tasks"** (the SQL Server 2016+ setup wizard offers to do this). On Linux, IFI applies to data files automatically.
- **Log files are always zeroed** — IFI never applies to the transaction log. This is why log growth/creation is slow and why VLF sizing matters.
- IFI has a minor security consideration: previously deleted disk content could be briefly readable in unallocated data pages until overwritten. Acceptable on a properly secured DB server.

Check whether IFI is in effect (2016+):

```sql
SELECT servicename, instant_file_initialization_enabled
FROM sys.dm_server_services
WHERE servicename LIKE N'SQL Server (%';
```

## Data and Log File Management

- **One log file is enough.** Multiple log files give no performance benefit (the log is written sequentially); they only complicate management. Add a second log file only as an emergency to relieve a full-log situation, then remove it.
- **Multiple data files** can help large databases (parallel I/O, manageability, partitioning). For tempdb specifically, multiple equally-sized files reduce allocation contention — see **sqlserver-infrastructure**.
- **Separate log and data onto different volumes** where possible (different I/O patterns: log = sequential write-heavy, data = random). Place tempdb on its own fast storage.
- **Filegroups** group data files for administration (piecemeal backup/restore, read-only archive filegroups, partitioning). Archiving cold data into read-only filegroups (or partitioning it out) is a design technique — see **sqlserver-engineering**.

## VLF (Virtual Log File) Management

The transaction log is internally divided into Virtual Log Files. Their **count and size** depend on how the log was grown:

- **Too many small VLFs** (from many tiny autogrowths) slow database startup/recovery, log backups, and replication/AG redo, and can degrade DML performance.
- **Too few huge VLFs** make log space reuse coarse and can pin large amounts of log.

Growth-size → VLFs added per growth (engine rule; refined in 2014+ to reduce VLF counts on small growths):

| Growth increment | VLFs added |
|---|---|
| ≤ 64 MB | 4 |
| > 64 MB and ≤ 1 GB | 8 |
| > 1 GB | 16 |

So growing a log in **~8 GB chunks** yields 16 VLFs of ~512 MB each — a good balance. To right-size a bloated VLF count: back up the log, shrink the log file to near-empty, then grow it back in deliberate chunks to the target size. Aim for roughly low hundreds of VLFs at most for a large log, not thousands.

```sql
-- VLF count and detail per database (2016 SP2 / 2017+: sys.dm_db_log_info)
SELECT DB_NAME(database_id) AS database_name, COUNT(*) AS vlf_count
FROM sys.dm_db_log_info(NULL)        -- pass DB_ID() for one database
GROUP BY database_id
ORDER BY vlf_count DESC;
-- Pre-2016 SP2 fallback: DBCC LOGINFO('MyDB'); (row count = VLF count)

-- Log space used right now (2016 SP2+/2017+)
SELECT DB_NAME(database_id) AS database_name,
       total_log_size_in_bytes / 1024 / 1024 AS total_log_mb,
       used_log_space_in_bytes  / 1024 / 1024 AS used_log_mb,
       CAST(used_log_space_in_percent AS DECIMAL(5,2)) AS used_pct
FROM sys.dm_db_log_space_usage;       -- one row for the current DB context
-- All-version fallback: DBCC SQLPERF(LOGSPACE);
```

## Shrink: Why to Avoid It

`DBCC SHRINKFILE` / `DBCC SHRINKDATABASE` reclaim space by moving pages to the front of the file and truncating the tail. Problems:

- **Massive index fragmentation.** Shrinking a data file scrambles index physical order — you then have to rebuild indexes (which *regrows the file*), a pointless churn cycle.
- **Heavy I/O and logging** during the operation.
- **The file just regrows** during normal activity, often re-incurring autogrowth stalls.
- **`AUTO_SHRINK`** turns this into a perpetual, automatic disaster. **Never enable it.**

**When shrink is acceptable:** a genuine one-off reclaim after a large *permanent* deletion (e.g., you archived/dropped half the data and won't need that space back). Then:

```sql
-- One-off, deliberate: shrink, then immediately rebuild affected indexes
DBCC SHRINKFILE (N'MyDB_Data', 20480);          -- target size in MB
ALTER INDEX ALL ON dbo.LargeTable REBUILD;       -- repair the fragmentation you just caused
```

For the **log**, shrinking to fix VLF count (as above) is legitimate; routine log shrinking to "save space" is not — size the log for its peak workload and leave it.

## Monitoring Growth Trends

Capacity planning is proactive, not reactive. Track per-file size and free space over time so you can forecast when a volume fills.

- **Snapshot regularly.** A small Agent job can insert `sys.master_files` sizes + used/free into a history table nightly; trend it to project the date a volume reaches capacity. (`scripts/08-database-space-usage.sql` gives the point-in-time picture you'd persist.)
- **Used vs allocated** per file:

  ```sql
  -- Used vs free space within each file of the current database
  SELECT
      f.name AS logical_name, f.type_desc,
      f.size * 8 / 1024 AS allocated_mb,
      FILEPROPERTY(f.name, 'SpaceUsed') * 8 / 1024 AS used_mb,
      (f.size - FILEPROPERTY(f.name, 'SpaceUsed')) * 8 / 1024 AS free_mb
  FROM sys.database_files f;
  ```

- **Watch backup volume growth** too — full/diff/log sizes grow with the data and affect retention storage.
- **PaaS**: Azure SQL DB/MI and RDS expose storage metrics through Azure Monitor / CloudWatch; set alerts on storage % used and (for MI/RDS) on the configured max size / allocated storage.

## Patching and Cumulative-Update Servicing Strategy

(Closely related to capacity because patching needs maintenance windows and disk headroom for installers/rollback.)

### The servicing model

- SQL Server uses a **CU-only model** — there have been **no Service Packs since SQL Server 2017**. Cumulative Updates ship roughly **monthly in the first year** of a release, then about **every two months**, and Microsoft now considers CUs to the same quality bar as the old SPs.
- CUs are **cumulative**: installing the latest includes all prior fixes. **GDR** (security-only) updates exist for environments that must take security fixes without functional CUs.
- **Stay reasonably current** — don't wait for a (no-longer-existent) Service Pack. Lagging far behind accumulates known bugs and complicates support.

### Safe patching procedure

1. **Read the CU KB article** — note fixed issues, any breaking changes, and minimum build prerequisites.
2. **Back up first** — full backup (and on a VM, a snapshot/checkpoint) of the instance/system DBs so you can roll back the whole box if needed.
3. **Test in non-production** that mirrors prod (same edition/build/compat level) — verify the app and run key workloads.
4. **Have the rollback plan staged** — CUs can be uninstalled (Programs & Features → View installed updates), reverting to the prior build; keep the prior installer available. Confirm the build before/after with `SELECT SERVERPROPERTY('ProductVersion'), SERVERPROPERTY('ProductUpdateLevel');`.
5. **Schedule a window** — patching requires a service restart; size the window for install + restart + verification + potential rollback.
6. **Verify post-patch** — instance starts, databases recover (`state_desc = ONLINE`), Agent jobs run, app connects.

### HA rolling upgrade

For Always On AGs and FCIs, patch with a **rolling upgrade** to minimize downtime: patch the **secondary** replicas/nodes first, then **fail over** to a patched node, then patch the former primary. The exact sequence (and the rule that the primary should be on a build ≥ secondaries during the process) is covered in **sqlserver-ha-clustering** — route there for AG/FCI rolling-upgrade and quorum considerations.

### PaaS / platform patching

- **Azure SQL Database / Managed Instance** — patched **by Microsoft**. You only control the **maintenance window** (choose off-peak) and get advance notification; there are no CUs to install.
- **SQL on Azure VM** — box product; you patch, or enable the **SQL IaaS Agent extension automated patching** to apply updates in a defined window.
- **AWS RDS** — you choose a target **engine version**; RDS applies it during the maintenance window (Multi-AZ patches the standby first, then fails over to minimize downtime). No manual CU install; no OS access.

## Capacity / Servicing Checklist

- [ ] Autogrowth = fixed MB (not %), files pre-sized, sane max sizes.
- [ ] IFI enabled (Perform Volume Maintenance Tasks) for fast data-file growth/restore.
- [ ] One log file; log grown in deliberate chunks; VLF count sane (low hundreds, not thousands).
- [ ] `AUTO_SHRINK` OFF everywhere; no routine shrinking.
- [ ] Growth trending persisted; alerts on volume / PaaS storage % used.
- [ ] On a supported, reasonably current CU; rollback installer staged; patching done in a window with verification.
- [ ] HA patching uses a rolling upgrade (see **sqlserver-ha-clustering**).
