# SQL Server on IaaS & Other Clouds — Reference

This reference covers SQL Server when it runs as the **box engine in someone else's datacenter**: SQL Server on an Azure VM (IaaS), AWS RDS for SQL Server (managed box), and Google Cloud SQL for SQL Server (managed box, brief). It closes with **when to pick IaaS over PaaS**.

These are all the *real* engine (`EngineEdition` 2/3/4), so engine internals, T-SQL, and indexing behave exactly as on-prem — cross-reference `sqlserver-engineering`, `sqlserver-infrastructure`, and `sqlserver-ha-clustering` for those. What differs is **operations, storage, HA wiring, and licensing**.

---

## Part A — SQL Server on Azure VM (IaaS)

The full box product on a Microsoft-managed VM. **You own the OS, patching, HA, storage layout, and backups.** This is the maximum-control option: any feature the box product supports (FILESTREAM, FileTable, PolyBase, every trace flag, third-party agents, full `sa`/RDP) works.

### SQL IaaS Agent extension
Registering the VM with the **SQL IaaS Agent extension** is what turns a plain VM into a *managed* SQL VM and unlocks portal features at no extra cost (full management mode requires the extension). It provides:

- **Automated patching** — schedule a weekly maintenance window for Windows + SQL CUs.
- **Automated backup** (Managed Backup to Azure storage) — full/log backups to a storage account with retention, optional encryption.
- **Azure Key Vault integration** — store TDE / Always Encrypted / backup-encryption keys in Key Vault.
- **License flexibility** — switch between AHB and PAYG from the portal.
- **Storage configuration** assistance and best-practice surfacing, plus health/PerfInsights signals.

There is a **lightweight** management mode (no agent in the guest) and a **full** mode (agent installed). Full mode is needed for automated patching/backup.

### Storage best practices (the #1 IaaS performance lever)
- Use **Premium SSD** (or **Ultra Disk** for the most demanding log/IO) — never Standard HDD for production data/log.
- **Data files:** enable **read caching** (ReadOnly host cache) on the data disks.
- **Log file:** **no caching** (None) on the log disk — write-heavy and latency-sensitive; caching hurts and risks correctness on some configs.
- **tempdb:** place on the VM's **local/ephemeral SSD** (the temporary `D:`/resource disk) where the VM offers one — it's fast and free, and tempdb is recreated on restart anyway.
  - **Ephemeral-disk caveat:** the local/temp disk is **wiped when the VM deallocates, stops, or relocates to a new host** — the tempdb folder *and its NTFS permissions* vanish. SQL Server then **fails to start** because the tempdb path doesn't exist. Mitigate by recreating the folder (with the right permissions) at boot **before** the engine starts: the **SQL IaaS Agent extension** automates this for Marketplace SQL VM images; for a manually installed instance, set the SQL Server + Agent services to **manual** start and run a startup-triggered scheduled task (PowerShell) that creates the folder and then starts the services. See Microsoft Learn, "Place tempdb on Ephemeral Storage."
  - **tempdb metadata contention:** for metadata-heavy tempdb workloads, consider **memory-optimized tempdb metadata** (`ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;`, 2019+; requires a restart) — a `sqlserver-infrastructure` topic; tag it as a `[CONFIG CHANGE]` if you script it.
- **Stripe multiple disks** into a **Storage Spaces** pool (Windows) to aggregate IOPS/throughput beyond a single disk's cap; size the pool to your IOPS target, not just capacity.
- Pick a **VM size** whose uncached/cached IOPS and throughput limits exceed your disk aggregate — the VM cap, not the disk, is often the real ceiling.
- Format data/log volumes with **64 KB allocation unit size**; enable **Instant File Initialization** and **Lock Pages in Memory**; set **max server memory** leaving headroom for the OS (these are box-product tunings — see `sqlserver-infrastructure`).

### HA options on Azure VM
You build HA yourself, with cloud-aware quorum/storage:

- **Always On AG** across VMs in an **availability set** or across **availability zones**; use an **Azure Load Balancer** (or distributed network name, DNN) for the listener. Quorum via **Cloud Witness** (an Azure storage account as the witness — cheap, region-independent) or a file-share witness.
- **Failover Cluster Instance (FCI)** with shared storage backed by **Azure shared disks** (premium/ultra shared) or **Storage Spaces Direct (S2D)** building a software-defined shared volume across nodes; quorum via Cloud Witness.
- **Cloud Witness** is the recommended quorum witness for both AG and FCI in Azure — it removes the need for a third VM/file server.

### Licensing
- **Azure Hybrid Benefit (AHB):** bring existing SQL Server licenses with Software Assurance to pay only the base compute rate (no SQL license uplift) — large saving for owned licenses.
- **Pay-as-you-go (PAYG):** SQL license cost is baked into the per-second VM price; best when you don't own licenses or want no commitment.
- **Reserved VM Instances** + AHB stack for the lowest steady-state cost.

---

## Part B — AWS RDS for SQL Server

A **managed box** engine on AWS. AWS owns the OS, patching, and HA orchestration; you get a database endpoint and a **limited admin login** — never `sa`, never the host.

### HA — Multi-AZ
- **Multi-AZ** provisions a **synchronous** standby in a second availability zone with automatic failover. Under the hood this historically used **database mirroring**; newer/Enterprise deployments use **Always On Availability Groups**. You don't manage the mechanism.
- Failover repoints the **DNS endpoint** to the standby — the connection string (endpoint name) does not change, but the IP does, so apps must not cache DNS aggressively.
- A single-AZ instance has no automatic failover (only restore-from-backup).

### Editions, instance classes & storage
- Supports **Express, Web, Standard, Enterprise** editions (feature/licensing differences mirror on-prem; AWS offers license-included or BYOL/AHB via Dedicated Hosts).
- **Instance classes** (`db.*`) define vCPU/RAM; **storage** is gp3/io1/io2 EBS with provisioned IOPS for performance.
- Max **16 TB** per instance.

### The limited-admin model & limitations
This is the big surprise for DBAs moving from the box product:

- **No `sa`** — you get a *master-style* admin login (created at provision time) with **most** but not all sysadmin rights. Certain server-level actions are reserved to AWS.
- **No OS / RDP / SSH access** to the host — no file system, no Windows Task Scheduler, no third-party agents on the box.
- **`xp_cmdshell`** is **off by default** (can be enabled via option/parameter group in some editions, but the OS context is restricted).
- **No direct backup/restore to local disk** — instead use **native backup/restore to/from Amazon S3** (the `rds_backup_database` / `rds_restore_database` stored procedures via an **option group**) — this is the primary path to move native `.bak` files in and out of RDS.
- **No log shipping**, and **transactional replication as a publisher** was historically unsupported / limited (read up on current support; replication features are gated). Don't assume on-prem replication topologies port over.
- Configuration is via **parameter groups** (engine settings, the `sp_configure`-equivalent) and feature enablement via **option groups** (SQLSERVER_AUDIT, native backup/restore, TDE, etc.). You cannot run arbitrary `sp_configure`/`ALTER SERVER CONFIGURATION` freely — you change the parameter group.
- Other gaps: limited/managed maintenance windows for patching, restricted DBCC/trace-flag use, no FILESTREAM/FileTable historically, no Database Mail to arbitrary SMTP without setup, no distributed transactions across instances in the usual sense.

### Read replicas
RDS for SQL Server supports **read replicas** (Enterprise edition, within and across regions) for read scale-out and as a basis for cross-region DR. They lag asynchronously.

### RDS Custom (escape hatch)
**Amazon RDS Custom for SQL Server** gives you OS and `sa`-level access on a managed RDS instance for workloads that need to install agents or tweak the OS — a middle ground between RDS and self-managed EC2.

---

## Part C — Google Cloud SQL for SQL Server (brief)

A **managed box** engine on Google Cloud, similar in spirit to RDS.

- **HA:** a **regional (HA)** configuration runs a primary plus a **standby in another zone** with automatic failover (synchronous replication of the underlying disk). A non-HA instance has no automatic failover.
- **Read replicas:** asynchronous read replicas (in-region and cross-region) for read scale-out.
- **Limitations:** no OS/host access, a limited admin user (no full `sa`), feature/flag gating via instance flags, automated managed backups + PITR, and the usual managed-box restrictions (no FILESTREAM, restricted extended-stored-procedure use, managed patching windows).
- Editions/sizes are chosen by machine type and storage (SSD/HDD with auto-growth).

Use Cloud SQL when the organization is GCP-resident and wants least-effort managed SQL Server; expect an RDS-like guard-rail profile.

---

## Part D — When to Pick IaaS over PaaS

Choose **SQL on a VM / RDS Custom / self-managed** (IaaS) when you need any of:

- **OS-level access** — third-party backup/monitoring agents, custom scripts, Windows scheduled tasks, host file access.
- **Features PaaS doesn't support** — FILESTREAM/FileTable, every trace flag, unusual `sp_configure`, cross-instance MSDTC, Stretch DB, specific replication topologies. (Note: **PolyBase/data virtualization and ML Services (R/Python) are now available on MI** — don't assume the old "PaaS can't do it" answer; re-verify on Microsoft Learn. Full external-language support, e.g. Java, and the full PolyBase surface still favor the box engine.)
- **Full version/patch control** — pin a build, delay CUs, run an out-of-support version during migration.
- **Specialized configuration** — custom storage layout, NUMA tuning, soft-NUMA, dedicated tempdb hardware, In-Memory OLTP at extreme scale.
- **Existing tooling/automation** built around an instance you can fully control.

Choose **PaaS (MI or SQL DB)** when you want Microsoft to own patching, HA, and backups, and your feature needs fit the offering. **Default to the most managed option that meets your feature requirements** — MI for instance parity, SQL DB for cloud-native scale, VM only when you truly need the control.

> Use `scripts/04-iaas-cloud-readiness.sql` for cloud-IaaS hygiene checks (IFI, storage latency, tempdb, AG/witness, max-memory vs VM size) on a SQL-on-VM or RDS box engine.
