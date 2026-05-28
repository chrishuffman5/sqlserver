# SQL Server Storage and tempdb Reference

Disk subsystem layout, latency/throughput targets, file-system and file-growth settings, instant file initialization, and the deep tempdb configuration that prevents the most common platform bottleneck. Diagnostics: `scripts/04-tempdb-config.sql` and `scripts/05-storage-layout.sql`.

**Scope:** box product 2016–2025 on Windows/Linux/containers. Cloud managed-disk selection (Premium SSD v2, Ultra Disk, gp3/io2, etc.) and storage-tiering economics are **sqlserver-cloud**; this reference covers the engine-side layout and the physical/VM disk principles.

---

## Storage Layout

Separate the four I/O personalities onto **separate volumes** — for throughput isolation, failure isolation, and because their access patterns differ:

| Volume | Access pattern | Priority | Notes |
|---|---|---|---|
| **Data (.mdf/.ndf)** | Mostly random read/write | High IOPS | The buffer pool absorbs reads; writes come from checkpoint/lazywriter |
| **Transaction log (.ldf)** | **Sequential write**, latency-critical | Lowest latency | WAL means commit latency = log write latency; one log per DB |
| **tempdb** | Mixed, often bursty/heavy | Fast, low-latency | Recreated at startup; durability not required → local NVMe is ideal |
| **Backups** | Sequential write (and read on restore) | Throughput | Keep off the data/log spindles; ideally a different failure domain |

- **Log wants the lowest latency**, not the most space — every commit waits for the log write to harden (Write-Ahead Logging). Put the log on the fastest, most consistent low-latency device available.
- **Data wants IOPS** for random access; size the device for the working set that does not fit in the buffer pool.
- **tempdb** can be ephemeral local NVMe (on a VM/cloud, a local temp disk) because it is rebuilt every restart — but make sure the engine can still start if that disk is wiped (the tempdb path must exist).

### Latency targets (from `sys.dm_io_virtual_file_stats`)

| File type | Read latency | Write latency |
|---|---|---|
| **Log** | n/a (writes dominate) | **< 5 ms** (ideally < 3 ms) |
| **Data** | **< 10–20 ms** | **< 20 ms** |
| **tempdb** | < 10–20 ms | < 20 ms |

```sql
-- Per-file average latency since startup (script 05 formats this fully)
SELECT
    DB_NAME(vfs.database_id)                AS database_name,
    mf.name                                 AS logical_name,
    mf.type_desc,
    CASE WHEN vfs.num_of_reads  = 0 THEN 0
         ELSE vfs.io_stall_read_ms  / vfs.num_of_reads  END AS avg_read_ms,
    CASE WHEN vfs.num_of_writes = 0 THEN 0
         ELSE vfs.io_stall_write_ms / vfs.num_of_writes END AS avg_write_ms,
    vfs.num_of_reads, vfs.num_of_writes,
    LEFT(mf.physical_name, 3)               AS drive
FROM   sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN   sys.master_files AS mf
  ON   vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
ORDER BY avg_write_ms DESC;
```

These averages are **since service start** — a one-off spike during startup/backup skews them. Sustained breaches indicate a storage problem (or an under-provisioned cloud disk), not a SQL bug. Real-time latency trending is **sqlserver-monitoring**.

### IOPS and queue depth

- Size the device for the **peak** IOPS the workload demands, not the average — checkpoints and backups are bursty.
- A persistently deep **disk queue** (current vs avg queue length in perfmon) with high latency means the storage cannot keep up. On SANs, check HBA queue depth and multipathing; on cloud, you may simply be at the provisioned IOPS/throughput cap (raise the tier — **sqlserver-cloud**).

---

## File System and File Settings (Windows)

- **NTFS allocation unit (cluster) size = 64 KB** for volumes hosting data/log/tempdb files. This matches SQL's 64 KB extent and is the long-standing recommendation. (You must format with `/A:64K`; it cannot be changed in place.)
- **Disable 8.3 short-name generation** on dedicated SQL data volumes (`fsutil 8dot3name set <vol> 1`) — minor, removes per-create overhead on directories with many files.
- **NTFS** for the engine; **ReFS** is supported and useful for some scenarios (large files, integrity streams) but verify per workload — NTFS remains the default recommendation for data/log.
- Exclude SQL data/log/backup paths and the `sqlservr.exe`/`sqlagent.exe` processes from real-time **antivirus** scanning, or AV will intercept every I/O.

### File system on Linux (parallel to the NTFS guidance)

On SQL Server on Linux there is no NTFS 64 KB allocation-unit knob; the equivalent tuning is:

- Use **XFS** or **ext4** (both supported); **XFS** is commonly preferred for large database files. SQL data lives under `/var/opt/mssql` by default — `chown mssql:mssql` the data/log paths.
- Mount data/log volumes appropriately (e.g., `noatime` to avoid access-time writes); align/format per your storage vendor's guidance. There is no 8.3-name concept.
- Exclude SQL paths from any host antivirus/security agent, same as on Windows. Verify the supported filesystem matrix for your version on Microsoft Learn.

### Autogrowth

- **Never percentage growth.** A 10% growth on a 100 GB file is a 10 GB event mid-business-hours, and successive growths get ever larger.
- Use a **fixed MB increment** scaled to the file (e.g., 256 MB for small DBs, 512 MB–1 GB for large), and **pre-size** files to their expected steady state so autogrowth is a safety net, not a routine event.
- Each growth that is not IFI-eligible (i.e., **log** growth) zeroes the new space — a stall. Many small log growths also create excessive **VLFs**; grow the log in larger chunks. (VLF management itself is **sqlserver-operations**.)

---

## Instant File Initialization (IFI)

By default, when a **data** file is created, grown, or restored, Windows zeroes the new space before SQL can use it — a stall proportional to the size. **IFI** skips the zeroing for data files.

- **Grant**: assign the *Perform Volume Maintenance Tasks* (SeManageVolumePrivilege) user-right to the SQL Server **service account** (via secpol.msc / group policy, or check the box in the 2016+ setup wizard).
- **Effect**: instant data-file growth and dramatically faster restores/file creation.
- **Log files cannot use IFI** — the log is always zero-initialized for crash-recovery correctness. This is why right-sizing the log up front (and growing it in deliberate chunks) matters.
- **Check it** (2017+ reports this directly):

```sql
-- 2017+: instant_file_initialization_enabled on the Database Engine service row
SELECT servicename, service_account, instant_file_initialization_enabled
FROM   sys.dm_server_services
WHERE  servicename LIKE 'SQL Server (%';
```

On pre-2017 there is no direct column — verify via the security policy or a startup trace flag 1806 (which *disables* IFI) check. Granting IFI is also touched on in **sqlserver-operations** (restore speed) and is a service-account privilege decision shared with **sqlserver-security**.

---

## tempdb Configuration (deep)

tempdb is the single most common platform misconfiguration and the source of the classic **allocation-page contention** bottleneck. It is shared by every database for: temp tables (`#t`, `##t`), table variables, sort/hash **spills**, the **version store** (RCSI/snapshot isolation, online index builds, triggers, MARS), and internal worktables (cursors, spools, LOBs).

### File count and sizing

| Logical cores | tempdb **data** files (starting point) |
|---|---|
| ≤ 8 | one file per core (e.g., 4 cores → 4 files) |
| > 8 | **8** files to start; add in groups of 4 only if contention persists |

- **`file count = min(logical cores, 8)`** is the rule. More than 8 rarely helps and is added only in response to measured, persistent allocation contention.
- **Modern nuance (2019+):** allocation improvements — concurrent PFS updates (2019+) and **memory-optimized tempdb metadata** — have reduced how much extra files matter, so `min(cores, 8)` plus metadata optimization usually resolves contention without piling on files; only add more (in groups of 4) on *measured* PAGELATCH contention. Verify the current allocation behavior for your build on Microsoft Learn.
- **All data files equal size and equal growth** — proportional fill only balances allocations across files of equal size; one larger file becomes a hotspot and defeats the purpose.
- **Pre-size** to the expected steady-state high-water mark so tempdb never autogrows during business hours; fixed-MB growth, never percent.
- **One log file** is sufficient (logs do not benefit from multiple files).
- Place tempdb on its **own fast, low-latency device** (local NVMe ideal).

```sql
-- Current tempdb files: sizes, growth, even-sizing check (script 04 flags unevenness)
SELECT
    mf.file_id, mf.name, mf.type_desc,
    mf.size * 8 / 1024              AS size_mb,
    CASE WHEN mf.is_percent_growth = 1
         THEN CONCAT(mf.growth, ' %  ← change to fixed MB')
         ELSE CONCAT(mf.growth * 8 / 1024, ' MB') END AS growth,
    mf.is_percent_growth
FROM   sys.master_files AS mf
WHERE  mf.database_id = DB_ID('tempdb')
ORDER BY mf.type_desc DESC, mf.file_id;
```

### Uniform extents (2016+)

Allocations to tempdb objects use **uniform extents by default from SQL Server 2016+** — the behavior that pre-2016 required trace flags **1117** (grow all files in a filegroup together) and **1118** (uniform extents). For tempdb you no longer set these flags; the engine does it. (For *user* databases, autogrow-all-files is now controlled per-filegroup with `ALTER DATABASE ... MODIFY FILEGROUP ... AUTOGROW_ALL_FILES`.)

### Memory-optimized tempdb metadata (2019+)

A major remaining contention point was the tempdb **system metadata** tables (allocation/object metadata) under heavy temp-object churn. SQL Server **2019+** can move that metadata to **memory-optimized** (latch-free) structures:

```sql
-- Check current state (2019+) — read-only
SELECT SERVERPROPERTY('IsTempdbMetadataMemoryOptimized') AS is_memopt_tempdb_metadata;  -- 1 = on

-- [CONFIG CHANGE] enabling REQUIRES A SERVICE RESTART to take effect. Confirm the target instance; rollback = set OFF + restart.
-- ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;
```

This is highly effective for workloads that hammer temp objects. Caveats: requires a restart; a single transaction cannot access memory-optimized tables in tempdb *and* a user database's memory-optimized tables in some cross-feature cases — validate against your workload. The script guards the property check for 2019+.

### Allocation-page contention symptoms

The fingerprint is **`PAGELATCH_UP` / `PAGELATCH_EX`** waits on specific tempdb allocation pages:

| Page | Structure |
|---|---|
| `2:1:1` | **PFS** (Page Free Space) |
| `2:1:2` | **GAM** (Global Allocation Map) |
| `2:1:3` | **SGAM** (Shared Global Allocation Map) |

(`2` is tempdb's database_id, `1` is the file_id, the last number is the page.) These waits, *not* `PAGEIOLATCH`, indicate metadata/allocation contention. Remedies, in order: enough equally-sized files (`min(cores,8)`), then memory-optimized tempdb metadata (2019+), then more files in groups of 4. Script 04 checks for live `PAGELATCH` waits on tempdb resources; ongoing wait analysis is **sqlserver-monitoring**.

### Version store (a tempdb consumer that catches people out)

When RCSI/snapshot isolation, online index rebuilds, triggers, or MARS are in play, SQL keeps **row versions** in tempdb's version store. A long-running transaction (or an orphaned open transaction) holds the version-store tail open, so it **grows without bound** and can fill tempdb. Symptoms: tempdb filling with no obvious temp-table culprit; `log_reuse_wait` is irrelevant here — look at the version store directly.

```sql
-- Version store space and the oldest transaction keeping it alive (2017+ for the per-DB DMV)
SELECT * FROM sys.dm_tran_version_store_space_usage;     -- per-database version-store size
SELECT * FROM sys.dm_db_file_space_usage;                -- tempdb: user/internal/version-store extents
SELECT TOP 5 transaction_id, elapsed_time_seconds
FROM   sys.dm_tran_active_snapshot_database_transactions
ORDER BY elapsed_time_seconds DESC;                      -- the long transaction to chase down
```

The fix is operational/engineering (kill or fix the long transaction, shorten transaction scope) — the infrastructure decision is to **size tempdb for the worst-case version-store footprint** if you run RCSI/snapshot heavily.

### ADR and the Persistent Version Store (PVS) — shifts version storage out of tempdb (2019+)

**Accelerated Database Recovery (ADR)**, available from SQL Server **2019+** (and in Azure SQL DB/MI), keeps row versions in a **Persistent Version Store (PVS)** that lives **in the user database itself** (by default the PRIMARY filegroup; movable to another filegroup) rather than in tempdb's version store. When ADR is enabled on a database, that database's versioning load moves **off tempdb and into the user DB's PVS** — so the tempdb version-store component shrinks, while the user database's data files must absorb (and be sized for) the PVS.

- Sizing implication: with ADR on, lower the tempdb headroom you reserve for the version store, and add it to the user-database data-file budget instead. Watch PVS size with `sys.dm_tran_persistent_version_store_stats`; a stuck PVS (oldest open transaction) bloats the user DB, not tempdb.
- **Optimized locking** (SQL Server **2025** / Azure SQL DB/MI) builds on ADR/PVS and RCSI; it reduces lock memory and escalation (see `memory-and-cpu.md`) but, because it relies on row versioning, reinforces the need to size the **PVS** in the user database. Verify version/edition support on Microsoft Learn for your build.

### tempdb sizing worked example

8 logical cores, expected peak temp usage ~24 GB: create **8** data files at **3 GB each (= 24 GB)**, equal `FILEGROWTH = 512 MB` fixed, on a dedicated low-latency volume; one log file pre-sized to a few GB. Pre-sizing means proportional fill starts balanced and you never autogrow mid-day.

### tempdb checklist

1. Data file count = `min(logical cores, 8)`; add in groups of 4 only on measured contention.
2. All data files **equal size and equal fixed-MB growth**.
3. **Pre-size** to the steady-state high-water mark; never rely on autogrowth in business hours.
4. Dedicated **fast/low-latency** volume (local NVMe ideal; ephemeral is fine).
5. Uniform extents are automatic (2016+) — do **not** set TF 1117/1118 for tempdb.
6. Consider **memory-optimized tempdb metadata** (2019+) under heavy temp-object churn.
7. Size for the **version store** if RCSI/snapshot isolation is in use.
8. Grant **IFI** so tempdb file creation/growth at startup is instant.

---

## RAID, SAN, Local NVMe, and Cloud

| Component | RAID guidance (physical/VM) |
|---|---|
| **Transaction log** | **RAID 10** — write-heavy and latency-critical; avoid RAID 5/6 (write penalty) |
| **Data** | **RAID 10** for write-heavy OLTP; RAID 5/6 acceptable for read-mostly/DW where the write penalty is tolerable |
| **tempdb** | **RAID 10** or local NVMe; ephemeral so durability is not the concern, speed is |
| **Backups** | RAID 5/6 fine — throughput over latency, and a separate failure domain |

- **SAN**: ensure correct multipathing, HBA queue depth, and that the LUNs are not sharing spindles/cache with noisy neighbors. Align partition offset on legacy systems (modern Windows aligns at 1 MB automatically).
- **Local NVMe**: excellent for tempdb and for buffer-pool-extension/temp scenarios; on physical servers it can host data/log if the HA model tolerates node-local storage.
- **Cloud disks**: managed-disk tier selection, host caching (ReadOnly for data, None for log), and disk striping for IOPS are **sqlserver-cloud** topics — the latency/throughput *targets* above still apply, but you reach them by choosing the right tier rather than by buying spindles.
