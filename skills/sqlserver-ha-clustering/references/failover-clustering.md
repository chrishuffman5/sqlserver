# Failover Clustering (FCI) & WSFC / Quorum Reference

Deep reference for Windows Server Failover Clustering (WSFC), quorum design, and SQL Server Failover Cluster Instances (FCI), SQL Server 2016–2025. AGs also ride on WSFC — for AG specifics see `availability-groups.md`; for endpoints see `mirroring-endpoints.md`.

## 1. WSFC Fundamentals

A **Windows Server Failover Cluster** is a group of independent servers (**nodes**) that cooperate to keep clustered roles (an FCI, an AG's network-name resource, a file share) available. Key concepts:

- **Node** — a server that is a member of the cluster. Each node may hold a **vote** toward quorum.
- **Cluster role / resource group** — a unit that fails over together (e.g., a SQL FCI = its network name + IP + storage + the SQL Server service).
- **Resource** — an individually monitored entity (IP address, disk, service). Resources have **dependencies** and **health checks**; a failed resource can restart in place or fail the group over.
- **Cluster shared / cluster network** — heartbeat and client networks. WSFC sends heartbeats between nodes to detect failures.
- **Cluster name object (CNO)** and **virtual computer objects (VCO)** — AD computer accounts WSFC creates; permissions issues here are a common AG/FCI listener failure.
- **Cluster validation** — `Test-Cluster` (or the Validate a Configuration wizard) must pass before a supported cluster is built.

WSFC does **not** know what SQL Server is — SQL Server registers resources and provides `sp_server_diagnostics` health to WSFC, which decides failover based on resource health and quorum.

## 2. Quorum — Avoiding Split-Brain

**Quorum** is the rule set that decides whether the surviving partition of a cluster has enough **votes** to keep running. Without quorum a partition shuts its clustered roles down to prevent **split-brain** (two partitions both believing they own the role and diverging).

### Quorum models

| Model | Voting members | Best for | Notes |
|---|---|---|---|
| **Node Majority** | Nodes only | Odd node counts (3, 5, 7…) | Survives loss of < half the nodes. No witness. |
| **Node & Disk Majority** | Nodes + a shared **disk witness** | Even node counts with shared storage | The disk holds a vote (and a copy of the cluster DB). |
| **Node & File Share Majority** | Nodes + a **file share witness** | Even node counts, multi-site, no shared disk | Lightweight SMB share as tie-breaker. |
| **Disk Only** (legacy) | The witness disk only | **Avoid** | Single point of failure; cluster lives/dies with the disk. |
| **Cloud Witness** (2016+) | Nodes + an **Azure Blob** witness | Multi-site / no third datacenter | Tiny blob; ideal when you lack a reliable third site. |

General rule: **always have an odd total number of votes.** With an even node count, add a witness (file share, disk, or cloud) so ties can be broken.

### Dynamic quorum & dynamic witness (2012 R2+ / current Windows Server)

Modern WSFC manages votes automatically:
- **Dynamic quorum** — WSFC removes a node's vote when it leaves so the cluster can keep running down to the **last surviving node** (the cluster "drops" votes to maintain a workable majority).
- **Dynamic witness** — WSFC automatically decides whether the witness gets a vote based on the current number of voting nodes (witness votes when node count is even, doesn't when odd) — so you can **always configure a witness** and let WSFC decide when it counts.
- **Node votes** — you can manually remove a vote from a node (`(Get-ClusterNode X).NodeWeight = 0`) to keep multi-site vote counts sane (e.g., zero out votes at the DR site so the primary site retains majority during a WAN partition).

Inspect from SQL Server: `sys.dm_hadr_cluster` (`quorum_type_desc`, `quorum_state_desc`) and `sys.dm_hadr_cluster_members` (`number_of_quorum_votes`, `member_state_desc`). See `scripts/05-cluster-health.sql`.

## 3. FCI Architecture (Instance-Level HA)

A **Failover Cluster Instance** is a single SQL Server instance installed across multiple WSFC nodes that share storage:

- **One installation, multiple possible owner nodes.** At any moment exactly **one node** owns and runs the instance; the others are passive standbys for that instance.
- **Shared storage** — the data/log/tempdb files live on storage reachable by all nodes: traditional **SAN**, **Storage Spaces Direct (S2D)**, or an **SMB 3.0 file share**. There is **one copy** of the data (no redundant data copies — that's the difference from AG).
- **Virtual Network Name (VNN)** + virtual IP — clients connect to the VNN regardless of which node currently owns the instance. Failover moves the instance's resource group (network name, IP, disks, service) to another node; clients reconnect to the same VNN.
- **No readable secondary** — there is only one running instance; passive nodes run nothing for that instance. (You do not pay for a readable copy, but you get no read scale-out.)
- **Failover is fast** (no reseeding — same storage), bounded mainly by recovery/redo of the database on the new owner. **Accelerated Database Recovery** (2019+) shortens this.

### FCI failover triggers
Node failure, OS crash, storage path failure, a failed health check (`FailureConditionLevel`), or a manual move. WSFC restarts the instance on a healthy node.

## 4. FCI vs AG

| Dimension | FCI | Always On AG |
|---|---|---|
| Protects | The **instance** (and everything in it) | A **group of databases** |
| Data copies | **One** (shared storage) | **Many** (one per replica) |
| Storage | Shared (SAN/S2D/SMB) | Non-shared (each replica independent) |
| Readable secondary | **No** | Yes (Enterprise) |
| Backups offload | No | Yes (secondary) |
| Failover unit | Whole instance | Database group |
| Min edition | Standard (2 nodes) | Enterprise (Basic AG on Standard) |
| Common combo | Often used **as a replica inside an AG** | Can contain FCI replicas |

Choose **FCI** when you want simple instance-level HA, can't/won't maintain multiple data copies, and don't need read scale or per-database failover. Choose **AG** when you want data redundancy, readable secondaries, per-database/group failover, or cross-site DR with independent copies.

## 5. Multi-Subnet FCI / AG — `RegisterAllProvidersIP` & `HostRecordTTL`

In a multi-subnet (stretched) cluster, the FCI VNN or the AG listener has **one IP per subnet** and DNS holds multiple A records:

- **`RegisterAllProvidersIP = 1`** (default for AG listeners) — all of the network name's IPs are registered in DNS. Clients then try them per `MultiSubnetFailover`.
- **`HostRecordTTL`** — lower it (e.g., **300s** instead of the 1200s default) so stale IPs age out of client/DNS caches quickly after a cross-subnet failover.
- **Connection string**: set **`MultiSubnetFailover=True`** so the client tries all listener IPs **in parallel** and connects to the first that answers (fast cross-subnet failover). Without it, older clients try IPs serially and can hang until timeout.
- Set these with PowerShell on the cluster resource:
  ```powershell
  Get-ClusterResource "AG1-LISTENER_<name>" | Set-ClusterParameter RegisterAllProvidersIP 1
  Get-ClusterResource "AG1-LISTENER_<name>" | Set-ClusterParameter HostRecordTTL 300
  # then take the network-name resource offline/online to apply
  ```

## 6. FCI + AG Combined Topologies

A robust enterprise pattern layers both:

- **Per site: FCI** for instance-level HA (automatic, fast, shared storage local to the site).
- **Across sites: an AG** whose replicas are the FCIs, giving cross-site DR with independent data copies.

Rules and caveats:
- An **FCI cannot be an *automatic* failover target** for the AG (the AG can fail *to* an FCI replica only manually; *within* the FCI, WSFC still does automatic node failover). Set `FAILOVER_MODE = MANUAL` for FCI replicas in the AG.
- All FCIs and standalone replicas in the AG live in the **same WSFC** (or distributed AGs across separate WSFCs).
- This avoids needing readable secondaries *and* gives you both layers — but it's more moving parts; document the failover decision tree carefully (see `dr-planning.md`).

## 7. FCI on Linux

- Classic **Windows-style shared-storage FCI does not exist** on Linux. Instead, **Pacemaker** manages a shared-storage SQL Server instance via the `ocf:mssql:fci` resource agent (storage is mounted by the cluster on the active node), or — far more commonly — you use **AGs under Pacemaker** (`CLUSTER_TYPE = EXTERNAL`) for HA.
- **Fencing (STONITH) is mandatory** for any production Linux cluster to prevent split-brain.
- See `availability-groups.md` §10 for Linux AG operational details.

## 8. Installation Overview (FCI on Windows)

1. **Provision nodes & storage** — identical Windows builds, shared storage presented to all nodes, networks for heartbeat + client traffic.
2. **Add the Failover Clustering feature** on each node (`Install-WindowsFeature Failover-Clustering -IncludeManagementTools`).
3. **Validate** — run `Test-Cluster` and fix every error (warnings may be acceptable with justification).
4. **Create the WSFC** — `New-Cluster` with a cluster name and IP; **configure quorum/witness** (Cloud Witness or file share).
5. **Install SQL Server as a new FCI** on the first node (Setup → *New SQL Server failover cluster installation*) — specify the SQL network name (VNN), instance, shared disks, and service accounts.
6. **Add Node** — run Setup → *Add node to a SQL Server failover cluster* on each additional node.
7. **Test failover** — move the instance between nodes and validate client reconnection (VNN), then patch test (FCI patching is per-node, rolling).

## 9. Quick DMV / Tool Map

| Source | Purpose |
|---|---|
| `sys.dm_hadr_cluster` | Cluster name, quorum type/state |
| `sys.dm_hadr_cluster_members` | Node names, state, quorum votes |
| `sys.dm_hadr_cluster_networks` | Cluster networks visible to the instance |
| `SERVERPROPERTY('IsClustered')` | Is this instance an FCI? |
| `SERVERPROPERTY('IsHadrEnabled')` | Is Always On enabled? |
| `Get-Cluster` / `Get-ClusterNode` / `Get-ClusterQuorum` (PowerShell) | OS-level WSFC inspection |
| `Test-Cluster` | Validation |
