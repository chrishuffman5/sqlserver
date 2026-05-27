# SQL Server Platform and Network Reference

Deploying and configuring SQL Server beyond Windows defaults: the Linux engine and `mssql-conf`, containers on Docker/Kubernetes, the trace-flag catalog, startup parameters, and the network ports/protocols plumbing. Diagnostics: `scripts/06-trace-flags.sql` and `scripts/08-server-properties.sql`.

**Scope:** box product 2017+ on Linux and in containers (Linux support began in SQL Server 2017); Windows for trace flags/startup params/ports across 2016–2025. HA on Linux (Pacemaker) is **sqlserver-ha-clustering**; TLS/encryption-in-transit and service-account hardening are **sqlserver-security**; cloud-specific networking is **sqlserver-cloud**.

---

## SQL Server on Linux

### Supported distributions

SQL Server 2017+ runs on (each version supports specific releases — always check the docs for the exact build/distro matrix):

- **Red Hat Enterprise Linux (RHEL)** — and compatible (e.g., Rocky/Alma on newer versions)
- **Ubuntu** (LTS releases)
- **SUSE Linux Enterprise Server (SLES)**

### Install (RHEL example)

```bash
# Add the Microsoft repo, install the engine, then run setup
sudo curl -o /etc/yum.repos.d/mssql-server.repo \
     https://packages.microsoft.com/config/rhel/8/mssql-server-2022.repo
sudo yum install -y mssql-server
sudo /opt/mssql/bin/mssql-conf setup       # prompts for edition (PID), SA password, accepts EULA

# Optional command-line tools (sqlcmd, bcp)
sudo yum install -y mssql-tools18 unixODBC-devel
```

### `mssql-conf` — the Linux configuration surface

On Linux there is no Windows policy/registry; instance-level platform settings go through **`mssql-conf`** (which writes `/var/opt/mssql/mssql.conf`). Restart the service (`sudo systemctl restart mssql-server`) after changes that require it.

| Setting | Command | Purpose |
|---|---|---|
| Memory limit | `sudo /opt/mssql/bin/mssql-conf set memory.memorylimitmb 49152` | Equivalent of `max server memory` at the OS-process level (MB SQL may use) |
| TCP port | `sudo /opt/mssql/bin/mssql-conf set network.tcpport 1433` | Listening port |
| Trace flags | `sudo /opt/mssql/bin/mssql-conf traceflag 3226 on` | Enable a startup trace flag (durable) |
| Default data dir | `sudo /opt/mssql/bin/mssql-conf set filelocation.defaultdatadir /var/opt/mssql/data` | Where new data files land |
| Default log dir | `sudo /opt/mssql/bin/mssql-conf set filelocation.defaultlogdir /var/opt/mssql/log` | Where new log files land |
| Dump dir | `sudo /opt/mssql/bin/mssql-conf set filelocation.defaultdumpdir ...` | Crash-dump location |
| Telemetry | `sudo /opt/mssql/bin/mssql-conf set telemetry.customerfeedback false` | Opt out of usage telemetry |
| TLS / forced encryption | `sudo /opt/mssql/bin/mssql-conf set network.forceencryption 1` (+ cert settings) | Encryption-in-transit — see **sqlserver-security** |

Inside the engine you still use `sp_configure` for everything else (MAXDOP, cost threshold, etc.); `mssql-conf` covers the OS-/process-level knobs that have no T-SQL equivalent.

### Filesystem and differences vs Windows

- **Filesystem**: XFS or ext4 are the supported/recommended filesystems. Data lives under `/var/opt/mssql` by default.
- **Identity**: SQL runs as the `mssql` user; file ownership/permissions matter (`chown mssql:mssql`).
- **No Windows Authentication out of the box** — AD integration on Linux is configured separately (adutil/SSSD/realmd + Kerberos keytab). Details and Kerberos are **sqlserver-security**.
- **Feature gaps (historical, narrowing each release)**: FILESTREAM/FileTable and some PolyBase scenarios have had parity gaps; Distributed Transactions (MSDTC) and some replication topologies were added over time. Always verify the feature against the specific version on Linux.
- **HA on Linux uses Pacemaker** (corosync/pcs) rather than WSFC — there is no classic shared-storage FCI; you build AGs with an external Pacemaker cluster. Full treatment in **sqlserver-ha-clustering**.

---

## Containers (Docker / Kubernetes)

### Image and environment

The official image is **`mcr.microsoft.com/mssql/server`** (tag by version, e.g., `:2022-latest`).

```bash
docker run -d --name sql2022 \
  -e "ACCEPT_EULA=Y" \
  -e "MSSQL_SA_PASSWORD=Str0ng!Passw0rd" \
  -e "MSSQL_PID=Developer" \
  -p 1433:1433 \
  -v sqlvolume:/var/opt/mssql \
  mcr.microsoft.com/mssql/server:2022-latest
```

| Env var | Required | Purpose |
|---|---|---|
| `ACCEPT_EULA` | **Yes** (`Y`) | Accept the license; the container will not start without it |
| `MSSQL_SA_PASSWORD` | **Yes** | The `sa` password (note: older docs use `SA_PASSWORD`, now deprecated). Must meet strength policy |
| `MSSQL_PID` | recommended | Edition: `Developer` (default), `Express`, `Standard`, `Enterprise`, `EnterpriseCore`, or a product key |
| `MSSQL_COLLATION`, `MSSQL_TCP_PORT`, `MSSQL_AGENT_ENABLED`, `MSSQL_LCID` | optional | Collation, port, enable Agent, locale |

### Persistence

The databases live under **`/var/opt/mssql`**. **Without a persistent volume the data is destroyed when the container is removed.** Mount a named volume (or bind mount) at `/var/opt/mssql` so data survives container restarts/recreations.

### Kubernetes

- Deploy as a **StatefulSet** (stable network identity + a `PersistentVolumeClaim` per pod) — not a Deployment — because SQL Server is stateful.
- Expose via a `Service` (ClusterIP/LoadBalancer) on 1433; put the `sa` password and certs in **Secrets**.
- Set resource **requests/limits** consistent with `memory.memorylimitmb` so the pod is not OOM-killed.
- For HA, use a **Kubernetes operator** that orchestrates Always On AGs across pods (the bare engine in k8s does not self-cluster). HA design is **sqlserver-ha-clustering**.
- Containers are ideal for **dev/test/CI**; production container deployments need deliberate storage classes (low-latency PVs), anti-affinity, and an HA operator.

---

## Trace-Flag Catalog

Trace flags alter engine behavior globally (`-1` / `-T`) or per-session. Many historically useful flags have **become default behavior** or **moved to database-scoped configuration** in modern versions — prefer the modern mechanism where one exists.

| TF | Effect | Modern status / note |
|---|---|---|
| **1117** | Grow all files in a filegroup together | Default for **tempdb** 2016+; for user DBs use `AUTOGROW_ALL_FILES` per filegroup |
| **1118** | Uniform extent allocation (no mixed extents) | Default for **tempdb** 2016+ |
| **3226** | Suppress *successful* backup messages in the error log | Safe and common; stops log spam from frequent log backups |
| **1222** | Write deadlock graphs to the error log (XML) | Prefer the `system_health` Extended Events session — **sqlserver-monitoring** |
| **1204** | Write deadlock info to the error log (older text format) | Superseded by 1222 / system_health |
| **4199** | Enable query-optimizer hotfixes | Now per-DB via `QUERY_OPTIMIZER_HOTFIXES` (DSC, 2016+) |
| **7412** | Lightweight query-profiling infrastructure | **On by default 2019+**; enables `sys.dm_exec_query_profiles` low-overhead |
| **460** | Return column/row detail in string-or-binary truncation error (2628 instead of 8152) | Default behavior 2019+ |
| **3625** | "Limited" mode — hide some details from non-sysadmins | Hardening — cross-ref **sqlserver-security** |
| **8048** | Convert NUMA-partitioned memory objects to CPU-partitioned (legacy spinlock relief) | Rarely needed on modern builds; diagnose before applying |
| **834** | Large-page allocations for the buffer pool (Enterprise, LPIM) | Specialist; can slow startup and complicate memory — measure first |
| **1800** | Optimize log-block I/O for 4 KB-sector disks in log shipping/AG mirrors | Niche; only on specific sector-size mismatches |
| **1806** | **Disables** Instant File Initialization | Diagnostic only — its presence explains slow file growth |

Set a flag **durably** as a `-T` startup parameter (survives restart). `DBCC TRACEON(nnnn, -1)` enables it globally only until the next restart. `DBCC TRACESTATUS(-1)` lists active global flags — captured by `scripts/06-trace-flags.sql`.

```sql
-- Inspect live global trace flags (read-only)
DBCC TRACESTATUS(-1);

-- Enable a flag globally for THIS uptime only (lost on restart) — prefer -T startup param for durability
-- DBCC TRACEON (3226, -1);
```

On **Linux**, enable durable trace flags with `mssql-conf traceflag <n> on` rather than a startup parameter file.

---

## Startup Parameters

Startup parameters are set in **SQL Server Configuration Manager** (Windows, under the service's Startup Parameters) or via `mssql-conf`/the unit file (Linux). The common ones:

| Parameter | Meaning |
|---|---|
| `-d <path>` | Full path of the **master** data file (master.mdf) |
| `-l <path>` | Full path of the **master** log file (mastlog.ldf) |
| `-e <path>` | **Error log** file path |
| `-T <n>` | Enable trace flag `n` at startup (durable) |
| `-E` | Increase the number of extents allocated per file in proportional fill (helps DW/bulk-load file balancing) |
| `-g <MB>` | Reserve `MB` of **virtual address space** outside the buffer pool (Memory-To-Leave) for out-of-pool consumers; raise only on evidence of VAS pressure |
| `-f` | Start in **minimal configuration** (single-user, minimal features) for recovery |
| `-m` | Start in **single-user mode** (e.g., to repair master or change a stuck config); `-m"sqlcmd"` restricts to a named app |
| `-c` | Start without the Service Control Manager (advanced/manual start) |
| `-k <n>` | Throttle checkpoint I/O to `n` MB/sec (smooths checkpoint I/O spikes) |

Use `-f`/`-m` for break-glass recovery (e.g., a bad `max server memory` that prevents startup, or repairing `master`), then remove them and restart normally. Each version's default master/error-log paths differ — read them from `sys.dm_os_server_diagnostics`/the running config rather than assuming.

---

## Ports and Protocols

### Ports

| Port | Protocol | Used by |
|---|---|---|
| **TCP 1433** | TCP/IP | **Default instance** SQL Server listener (the well-known default) |
| **Dynamic TCP** (ephemeral) | TCP/IP | **Named instances** by default — pin to a static port for firewalling |
| **UDP 1434** | UDP | **SQL Server Browser** — hands out named-instance ports to clients |
| **TCP 5022** | TCP/IP | Default **AG / database-mirroring endpoint** (configurable) — see **sqlserver-ha-clustering** |
| **TCP 135 + RPC range** | TCP | **MSDTC** / distributed transactions, if used |

- Pin named instances to a **static port** (Configuration Manager → TCP/IP → IP Addresses → clear TCP Dynamic Ports, set TCP Port) so firewall rules are deterministic and you can disable the Browser.
- Open only the ports you use in the host firewall; the AG endpoint port must be open between replicas.

### SQL Server Browser

The Browser listens on **UDP 1434** and tells clients which dynamic port a named instance is on. If every instance uses a **static port**, you can **disable the Browser** to shrink the attack surface (clients then connect with `server\instance,port` or just `server,port`). Disabling it is a hardening step — cross-ref **sqlserver-security**.

### Protocols (enable/disable in Configuration Manager / `mssql-conf`)

| Protocol | Scope | Typical state |
|---|---|---|
| **Shared Memory** | Same machine only | Enabled (fastest for local connections) |
| **TCP/IP** | Network | **Enabled** — the standard network protocol |
| **Named Pipes** | Network/local | Usually **disabled** (legacy; TCP preferred) |

### Dedicated Admin Connection (DAC)

The **DAC** reserves a dedicated scheduler and memory so you can connect when the instance is otherwise unresponsive. It is local-only by default; allow remote use with `sp_configure 'remote admin connections', 1` (see `instance-configuration.md`). Connect with `sqlcmd -A` (or `ADMIN:` prefix). Only one DAC session at a time; use it for break-glass diagnosis, not routine work.

### Encryption in transit (pointer)

Forcing TLS for client connections (the `ForceEncryption` setting on Windows, `network.forceencryption` on Linux), certificate provisioning, and `Encrypt`/`TrustServerCertificate` client behavior are **sqlserver-security** topics. This reference covers only which ports/protocols the traffic flows over.
