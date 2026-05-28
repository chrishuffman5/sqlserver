# Azure SQL Managed Instance (PaaS) — Reference

Azure SQL Managed Instance (MI) is a fully managed **SQL Server instance** with near-100% surface-area parity to the box product. It is the lift-and-shift target for instance-level workloads that Azure SQL Database cannot host (anything needing SQL Agent, cross-database queries, CLR, Service Broker, linked servers, or instance-scoped objects). `EngineEdition = 8`.

MI is deployed **inside your virtual network** — it is private by default, not internet-facing like an Azure SQL DB logical server. Microsoft owns the OS, patching, and built-in HA; you own the databases, security, Agent jobs, and the vNet/connectivity around it.

---

## 1. Architecture

- An MI is provisioned into a **dedicated subnet** of your vNet (the subnet may host one instance or an **instance pool**). The subnet must be delegated to MI and cannot hold other resource types.
- It presents a **host name** (`<mi-name>.<dns-zone>.database.windows.net`) resolvable inside the vNet; clients connect on port **1433** (private) or **3342** (public endpoint, if enabled).
- Microsoft manages the underlying gateway/control-ring, storage, and HA orchestration. You never see the OS.
- The instance has its own `master`, `msdb`, `model`, and `tempdb` (real system databases, unlike Azure SQL DB's logical `master`), and a real **SQL Server Agent**.

---

## 2. Service Tiers

| Tier | Storage / architecture | HA | Max instance storage* | When to use |
|---|---|---|---|---|
| **General Purpose (GP)** | Compute separated from **remote** Azure premium storage (one file per DB file) | Built-in: failover reattaches storage to a new node; backed by Azure storage redundancy | up to 16 TB (classic GP) | Most workloads; balanced cost; IO latency higher than BC |
| **Business Critical (BC)** | **Local SSD**, built-in **Always On AG** (4 replicas) | Highest; includes one **free readable secondary**; in-memory OLTP supported; zone-redundant option | up to 16 TB (premium-series, enough vCores, supported region); Standard-series caps at 4 TB | Low-latency IO, high availability, read offload |
| **Next-gen General Purpose** | Re-architected GP: **flexible storage scaling**, **separately provisioned IOPS** (above a built-in baseline), and a **changed IO billing model** (you pay for IOPS over the free quota) | Same model as GP | up to 32 TB | New GP deployments wanting better performance/scaling levers and pay-for-what-you-provision IO |

\* **Max storage scales with vCores and hardware generation, and is not a flat number.** On BC, 16 TB requires premium-series (or memory-optimized premium-series) hardware with a high-enough vCore count in a region that offers it — smaller regions or vCore counts cap at 5.5 TB (Standard-series BC tops out at 4 TB). Per-tier/per-vCore tables move; **verify the current limits on Microsoft Learn** ([MI resource limits](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/resource-limits)) for your hardware generation and region.

**Next-gen GP, concretely:** storage scales flexibly (in 32-GB multiples), IOPS are provisioned separately — every instance gets a built-in baseline (~3 IOPS per GB of reserved storage, min ~300) and you can buy additional IOPS up to a per-vCore cap; throughput scales with IOPS (~IOPS/30 MB/s). Unlike classic GP/BC, **IOPS over the free quota are billed** — model that when costing it.

Choose **BC** when you need local-SSD latency, the free readable secondary, or In-Memory OLTP. Choose **GP / Next-gen GP** for cost-balanced general workloads.

---

## 3. Instance Pools

**Instance pools** let you pre-provision a shared block of compute (vCores) into a subnet and then deploy multiple small managed instances into it.

- Lowers the entry cost/footprint for **small** instances (a standalone MI has a minimum vCore floor that is uneconomical for tiny workloads).
- Instances in a pool can be **stopped/started** independently — a cost lever for non-production environments.
- Useful for consolidating many small legacy instances during migration.

---

## 4. Surface-Area Parity — What MI Has That Azure SQL DB Lacks

This is the core reason to pick MI over Azure SQL Database:

| Feature | Azure SQL Database | Azure SQL Managed Instance |
|---|---|---|
| SQL Server Agent (jobs, schedules, operators) | No | **Yes** |
| Cross-database queries (3-part names within instance) | No | **Yes** |
| Cross-database transactions (within instance) | No | **Yes** |
| Distributed transactions (MSDTC across MIs / via Azure) | No | **Yes** (between MIs, and to on-prem via configured DTC) |
| CLR (SAFE/EXTERNAL_ACCESS, with restrictions) | No | **Yes** |
| Service Broker (within the instance) | No | **Yes** |
| Linked servers (to SQL/other sources) | No | **Yes** |
| Database Mail | No | **Yes** |
| Real `master`/`msdb`/`model`/`tempdb` | No (logical master) | **Yes** |
| Global temp tables (`##temp`) | Limited/scoped | **Yes** |
| Resource Governor | No | **Yes** (with caveats) |
| Server-level logins, roles, credentials | Limited | **Yes** |
| Native cross-instance Service Broker | No | **No** (Broker is within-instance only) |

The practical implication: an instance with hundreds of Agent jobs, cross-DB stored procedures, and linked servers can move to MI with minimal refactoring — to Azure SQL DB it would require a rewrite.

---

## 5. vNet & Connectivity

- **Private endpoint (default):** MI lives in your vNet subnet; reach it from peered vNets, ExpressRoute, or VPN. This is the recommended, secure default.
- **Public endpoint (optional):** can be enabled for connectivity from outside the vNet on port **3342**, locked down with NSG rules — used for SaaS/management scenarios. Disabled by default.
- **DNS:** MI uses a private DNS zone; cross-vNet resolution may require custom DNS forwarding.
- **Connection types:** redirect vs proxy connection policy exists as on Azure SQL DB (redirect = lower latency, needs ports 11000–11999 within the vNet).
- Outbound: MI needs specific service-tag/NSG and route-table rules for the management plane — these are a common deployment gotcha.

See `sqlserver-security` for Entra ID auth, Windows-auth-over-Kerberos-to-Entra (incoming trust), and TDE/BYOK on MI.

---

## 6. Backups, PITR, LTR & Restore from URL

- **Automatic backups** managed by Microsoft (full/diff/log) to Azure storage, like Azure SQL DB.
- **PITR**: restore to a point in time within the retention window (configurable up to **35 days**); always restores as a **new database**.
- **LTR**: weekly/monthly/yearly retention up to **10 years**.
- **Restore from URL (the migration path):** MI can `RESTORE DATABASE ... FROM URL` directly from a **native .bak in Azure Blob Storage** — this is the standard way to bring an on-prem database into MI. Use a **`COPY_ONLY`** full backup on the source so you don't disturb the source's backup chain, upload it to blob, then restore on MI.
- MI **cannot** restore a backup taken from a *newer* engine version, and it cannot `BACKUP` to a local path — `COPY_ONLY` backup to URL is the supported outbound path (for moving a copy out, e.g. for dev refreshes).

---

## 7. Auto-Failover Groups

- MI supports **auto-failover groups** for cross-region DR (the same mechanism described in `azure-sql-database.md`, but at **instance scope** — the *entire* instance's databases fail over together).
- Provides read-write and read-only **listener endpoints** that follow the primary, so the application connection string is unchanged on failover.
- The secondary MI is a full readable instance; system databases (logins, Agent jobs) are *not* automatically synchronized — you must script/replicate server-level objects and jobs to the secondary instance yourself.
- Failover is automatic (policy-driven, with a grace period) or manual.

---

## 8. MI Link Feature (SQL Server 2022)

**Managed Instance link** establishes near-real-time replication from an on-prem (or VM) SQL Server **to** Azure SQL Managed Instance, built on distributed availability groups under the covers.

- **Source versions:** SQL Server **2022** natively; **2016, 2019** (and 2017/2019 SP/CU levels) supported as a source with the required cumulative updates. Always confirm the source build.
- **Uses:**
  - **Migration** with near-zero downtime — seed MI continuously, then cut over.
  - **Read offload** — run read-only/reporting workloads on the MI replica while the on-prem stays primary.
  - **DR** — MI as a cloud disaster-recovery target for an on-prem primary.
- **Direction:** originally one-way (on-prem → MI); newer releases support **bidirectional** failover/failback (failover to MI and back to on-prem), making it a true two-way DR/migration tool.
- It replicates at the **database** level (one DB per link, or multiple links). It does **not** carry instance-level objects — recreate logins/jobs/linked servers at the target.

This is often the best **near-zero-downtime** path to MI; compare with Log Replay Service (cutover-only) and Azure DMS in `references/cloud-migration.md`.

---

## 9. Limitations — What's NOT Supported on MI

Even with near-full parity, these gaps remain (the common DMA blockers for an MI target):

- **FILESTREAM / FileTable** — not supported.
- **Buffer pool extension** — not supported (MI manages memory).
- **Most trace flags** — only a small allow-listed set; startup trace flags are not generally available.
- **`sp_configure`** — only a limited subset of options is settable.
- **Cross-instance Service Broker** routes (Broker works only *within* the instance).
- **Replication:** MI can be a subscriber/publisher in limited topologies; some configurations (e.g. merge replication, certain publisher roles) are restricted.
- **No OS access**, no `xp_cmdshell` to the host filesystem in the usual sense, no Windows file shares, no Stretch DB.
- **PolyBase / data virtualization** and **Machine Learning Services (R/Python)** **are now supported on MI** (this changed — they were historically unavailable; on MI, ML Services supports only R/Python, not external Java). Re-verify the current surface on Microsoft Learn for your scenario rather than assuming the old "not supported" answer.
- **Instance (server) collation** is **chosen at creation and immutable thereafter** — the **default** (not a forced value) is `SQL_Latin1_General_CP1_CI_AS`, and **`tempdb` follows the instance collation**. Database-level collation remains flexible. To avoid the classic migration gotcha, match the source instance's collation (`SERVERPROPERTY('Collation')`) when you create the MI; a mismatch can throw unexpected query errors after migration.
- Backup/restore are **automatic** — you can't manage the chain or restore arbitrary external .bak files except `RESTORE ... FROM URL`.

---

## 10. Cost Levers

- **Azure Hybrid Benefit (AHB):** apply existing SQL Server licenses with Software Assurance to cut the compute rate substantially — usually the biggest single saving.
- **Reserved capacity (1- or 3-year):** commit to vCores for a large discount over PAYG.
- **Instance pools + stop/start:** consolidate small instances and stop non-production instances when idle.
- **Right-size the tier:** GP (or **Next-gen GP**) instead of BC unless you genuinely need local-SSD latency, the free readable secondary, or In-Memory OLTP.
- **Storage:** GP bills reserved storage; size it with headroom but don't over-provision — and watch log/IO billing on next-gen GP.
- **Dev/Test pricing** and shutting down non-prod instances overnight.

> Use `scripts/02-managed-instance-checks.sql` for a resource/tier/tempdb/Agent/backup health check on an MI, and `scripts/03-geo-replication-status.sql` for failover-group/geo state.
