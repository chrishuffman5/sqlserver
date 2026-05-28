# Community Diagnostic Tools Reference

This skill ships its own dependency-free, **read-only** diagnostic scripts (`scripts/01`–`11`) and a strict **waits-first** workflow. The two tool families below are **optional, widely used, freely licensed community projects** that *complement* — never replace — those scripts and that discipline. They map cleanly onto the five-step methodology (waits → top queries → blocking → plan → config); use them where you are permitted to install third-party objects and want richer triage or always-on history.

**Plugin policy (applies to everything here):**

- We **document and point to** these tools; we do **not** copy their third-party code into this repository. Install them from their official repositories.
- All of them are read-only diagnostics **except** the two mutating procedures called out below (`sp_kill`, `sp_DatabaseRestore`) and PerformanceMonitor's installer.
- **Installing** any of these (creating procs in a utility DB, or PerformanceMonitor's database/jobs/XE sessions) is itself a `[CONFIG CHANGE]` — it creates objects on the instance. Review the scripts and **run in a non-production instance first**, consistent with this plugin's bundled-script policy.
- They require the usual monitoring permission (`VIEW SERVER STATE`, or on 2022+ the least-privilege `VIEW SERVER PERFORMANCE STATE` — see `references/dmv-reference.md`).

---

## Brent Ozar First Responder Kit (sp_Blitz family)

- **License / source:** MIT — <https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit>
- **Install:** run `Install-All-Scripts.sql` into a dedicated **DBA/utility database** (e.g. `[DBA]`/`[master]` per your standard). This `[CONFIG CHANGE]` creates the stored procedures only — no jobs, no background collection. Update by re-running the latest installer.
- **Nature:** point-in-time, on-demand diagnostics. You run a proc, read the prioritized output. Read-only except `sp_kill` and `sp_DatabaseRestore` (below).

### What each proc is for, and where it fits the workflow

| Proc | Purpose | Workflow step / routing |
|---|---|---|
| `sp_Blitz` | Overall server health & configuration audit; prioritized findings with explanations | Cross-cutting health check; config issues route to `sqlserver-infrastructure` |
| `sp_BlitzFirst` | "What is happening **right now**" — samples ~5 seconds of waits/activity. `@SinceStartup = 1` gives since-startup waits + file stats. Can **log to tables** for trends. | **Step 1 (waits) / right-now triage** |
| `sp_BlitzWho` | Active queries right now (a richer `sp_who2`) with plans and memory grants | **Right-now / blocking** — pairs with this skill's `10-active-requests.sql` |
| `sp_BlitzCache` | Most resource-intensive cached plans; sort by CPU / reads / duration / executions; flags warnings (implicit conversions, spills, missing indexes) | **Step 2 (top queries)** |
| `sp_BlitzLock` | Deadlock analysis from the `system_health` XE session or a chosen target | **Deadlocks** — see the Blocking & Deadlock workflow + `06-deadlocks.sql` |
| `sp_BlitzIndex` | Index health: missing / unused / duplicate / overly-wide indexes and heaps. `@Mode = 4` for full detail | Index *design* lives in **`sqlserver-engineering`** — triage here, fix there |
| `sp_BlitzBackups` | RPO/RTO estimate from `msdb` backup history | Backup/recovery → **`sqlserver-operations`** |
| `sp_BlitzAnalysis` | Trend analysis over previously logged `sp_BlitzFirst` output | Baselining / historical review |
| `sp_ineachdb` | Helper: run a command in each database | Utility |

### Mutating members — treat with care

- **`sp_kill`** — emergency session kill with safety checks. **Mutating / destructive** — treat as **`[DATA-LOSS RISK]`**: killing a session rolls back its open transaction (can be a long, blocking rollback). Confirm you have the **head blocker** (walk the chain — see the Blocking workflow), confirm the business impact, and prefer fixing the root cause over killing.
- **`sp_DatabaseRestore`** — scripted multi-file restore (pairs with Ola Hallengren backups). **Mutating** — treat as **`[DATA-LOSS RISK]`**: it overwrites/creates databases. Use the pre-flight discipline for restores (confirm target instance/DB, verified backups, business approval); restore mechanics belong to **`sqlserver-operations`**.

> Everything else in the kit (`sp_Blitz`, `sp_BlitzFirst`, `sp_BlitzWho`, `sp_BlitzCache`, `sp_BlitzIndex`, `sp_BlitzLock`, `sp_BlitzBackups`, `sp_BlitzAnalysis`, `sp_ineachdb`) is **read-only**.

---

## Erik Darling PerformanceMonitor

- **License / source:** MIT — <https://github.com/erikdarlingdata/PerformanceMonitor>
- **Nature:** a **continuous background performance collector / monitor**. Where `sp_Blitz*` and this plugin's scripts give *point-in-time* snapshots, PerformanceMonitor gives **historical baselining, trending, and always-on capture** — the "what did last Tuesday at 2 a.m. look like?" question.
- **Supported targets:** SQL Server 2016–2025, Azure SQL Managed Instance, AWS RDS; Azure SQL Database via the Lite edition. Ships a **read-only MCP server** for LLM integration.

### Full Edition (server-side install) — this is a `[CONFIG CHANGE]`, not a read-only diagnostic

The installer creates:

- a **`PerformanceMonitor` database** (~32 collector procedures),
- **3 SQL Agent jobs** — collection (~1 min), retention (daily), and a hung-job monitor (~5 min),
- **Extended Events sessions** for deadlock and blocked-process capture.

Installation requires **sysadmin**. After install, the collectors can run under a **least-privilege login with `VIEW SERVER STATE`** (or 2022+ `VIEW SERVER PERFORMANCE STATE`). Because it persists objects, schedules jobs, and runs continuously, **say plainly that this is an install/`[CONFIG CHANGE]`** — review it and stage it in non-production first, and account for the (small, by design) standing overhead of continuous collection.

### Lite Edition

A standalone **desktop app** that stores data locally (DuckDB / Parquet) rather than in the monitored instance — useful when you cannot or should not create objects on the server, and the only option for **Azure SQL Database** (where you cannot install server-side jobs).

---

## When to reach for which

| Need | Reach for |
|---|---|
| Ad-hoc "what's happening right now" | `sp_BlitzFirst` / `sp_BlitzWho`, or bundled `10-active-requests.sql` / `sp_whoisactive` |
| One-shot server health / config audit | `sp_Blitz`, or bundled `01-server-health.sql` |
| Heaviest cached queries on demand | `sp_BlitzCache`, or bundled `03`/`04` |
| Deadlock post-mortem | `sp_BlitzLock`, or bundled `06-deadlocks.sql` |
| **Historical baselining / always-on trending** | **PerformanceMonitor** (Full server-side, or Lite for Azure SQL DB) |
| Point-in-time triage with zero install | This skill's bundled `scripts/` (always available, read-only) |

The decision is simple: **`sp_Blitz*` and the bundled scripts for point-in-time triage; PerformanceMonitor when you need history and continuous capture.** None of them removes the need to start with waits and drill down methodically.
