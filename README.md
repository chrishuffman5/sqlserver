# SQL Server Plugin

A dedicated Claude Code plugin for **Microsoft SQL Server**, covering the full database-management lifecycle: operations, monitoring, high availability / clustering, availability groups, mirroring endpoints, engineering, infrastructure, cloud offerings, security / authentication, and an offline DuckDB-powered analysis & recommendations advisor.

Scope spans the box product (**SQL Server 2016 → 2025** on Windows, Linux, and containers) and the cloud families (**Azure SQL Database**, **Azure SQL Managed Instance**, **SQL Server on Azure VM**, **AWS RDS for SQL Server**, **Google Cloud SQL**).

The skills use the open **Agent Skills** (`SKILL.md`) standard, so besides installing as a native Claude Code plugin they also work in **OpenAI Codex CLI** and **GitHub Copilot CLI** — see [Installation](#installation).

## Skills

| Skill | Covers | Triggers on |
|-------|--------|-------------|
| **`sql-server`** | Router + cross-cutting fundamentals, version/edition/platform matrices | "SQL Server", "MSSQL", "T-SQL", "DBA", general questions |
| **`sqlserver-operations`** | Backup & recovery, restore testing, maintenance, DBCC, SQL Agent jobs, alerts, Database Mail, patching/CUs, capacity | "backup", "restore", "recovery model", "DBCC CHECKDB", "maintenance", "Agent job", "patch" |
| **`sqlserver-monitoring`** | Wait stats, DMVs, Query Store, Extended Events, blocking & deadlock analysis, performance counters, baselining | "slow", "wait stats", "Query Store", "blocking", "deadlock", "high CPU" |
| **`sqlserver-ha-clustering`** | Always On Availability Groups, Failover Cluster Instances, database mirroring & endpoints, log shipping, replication, quorum, DR | "Always On", "availability group", "FCI", "mirroring endpoint", "log shipping", "failover" |
| **`sqlserver-engineering`** | T-SQL best practices, indexing, execution plans, query optimization, statistics/CE, parameter sniffing, partitioning, columnstore, schema design | "T-SQL", "index", "execution plan", "query tuning", "parameter sniffing" |
| **`sqlserver-infrastructure`** | Instance/OS config, memory, MAXDOP, tempdb, trace flags, NUMA, storage layout, Linux/containers, network/protocols | "max server memory", "MAXDOP", "tempdb config", "trace flag", "SQL on Linux" |
| **`sqlserver-cloud`** | Azure SQL DB/MI, SQL on Azure VM, AWS RDS, Cloud SQL, feature parity, geo-replication, failover groups, migration tooling | "Azure SQL", "Managed Instance", "Hyperscale", "RDS SQL Server", "cloud migration" |
| **`sqlserver-security`** | Authentication modes, authorization/RBAC, encryption (TDE, Always Encrypted, TLS), RLS, DDM, auditing, ledger, hardening | "authentication", "Entra ID", "Kerberos", "TDE", "Always Encrypted", "audit", "hardening" |
| **`sqlserver-advisor`** | Offline analysis & recommendations — capture read-only system views → DuckDB → prioritized findings (table design, indexing, sizing & capacity, statistics staleness, query hotspots, waits, configuration, file/tempdb layout, backup cadence, identity runway) | "analyze my database", "recommendations to improve", "what indexes am I missing", "unused/duplicate indexes", "database health report", "backup review" |

## Installation

All **9 skills** (the `sql-server` router, seven domain skills, and the `sqlserver-advisor` analyzer) are written in the open **Agent Skills** (`SKILL.md`) standard, so they work in any agent CLI that supports it. Claude Code can additionally install the whole repo as a native **plugin**.

### Claude Code — native plugin

```text
/plugin marketplace add chrishuffman5/sqlserver   # register this repo as a marketplace
/plugin install sqlserver@sqlserver               # plugin-name @ marketplace-name
```

Start a new session and Claude auto-routes to the right skill. To develop against a local clone instead of GitHub, point the marketplace at the path: `/plugin marketplace add /path/to/sqlserver`. Manage installed plugins anytime with `/plugin`.

### OpenAI Codex CLI — Agent Skills

Codex loads skills from `~/.agents/skills/` (personal, all projects) or `.agents/skills/` (per-repo). Clone this repo and copy the skill folders in:

```bash
git clone https://github.com/chrishuffman5/sqlserver.git
mkdir -p ~/.agents/skills && cp -r sqlserver/skills/* ~/.agents/skills/
```

```powershell
# Windows PowerShell
git clone https://github.com/chrishuffman5/sqlserver.git
$d = "$HOME\.agents\skills"; New-Item -ItemType Directory -Force $d > $null
Copy-Item -Recurse -Force sqlserver\skills\* $d
```

Run `/skills` in Codex to confirm they loaded; reference one explicitly with `$sql-server`, or just describe the task and Codex matches automatically. Restart Codex if a change doesn't appear.

### GitHub Copilot CLI — Agent Skills

Install the CLI, then place the skills in a Copilot skills directory — personal (`~/.copilot/skills` or `~/.agents/skills`) or per-repo (`.github/skills`, `.claude/skills`, or `.agents/skills`):

```bash
npm install -g @github/copilot
git clone https://github.com/chrishuffman5/sqlserver.git
mkdir -p ~/.copilot/skills && cp -r sqlserver/skills/* ~/.copilot/skills/
```

In a Copilot CLI session run `/skills reload`, then `/skills list` (or `/skills info sql-server`) to verify. The GitHub CLI's `gh skill` can also search / install / update skills from repos — run `gh skill --help` for current syntax.

> **Tip:** `~/.agents/skills/` is read by **both** Codex and Copilot, so copying the skills there once covers both tools.
>
> **Note:** each skill folder carries its own `references/` and read-only `scripts/`, so those travel with the skill in every tool — no extra setup.

## How to use

Just describe what you need — the agent routes to the right skill automatically (Claude Code, OpenAI Codex, or GitHub Copilot). Examples:

- *"My SQL Server 2019 instance has high `PAGEIOLATCH` waits"* → `sqlserver-monitoring`
- *"Design a backup strategy with a 5-minute RPO"* → `sqlserver-operations`
- *"Set up a contained availability group on SQL 2022"* → `sqlserver-ha-clustering`
- *"How do I configure a database mirroring endpoint with certificate auth?"* → `sqlserver-ha-clustering`
- *"Migrate an on-prem DB to Azure SQL Managed Instance"* → `sqlserver-cloud`
- *"Lock this instance down to least privilege with Entra ID auth"* → `sqlserver-security`
- *"Analyze my database and recommend design/index improvements"* → `sqlserver-advisor`

## Diagnostic scripts

Every operational domain ships a `scripts/` folder of **read-only** T-SQL diagnostics (health, waits, blocking, AG/mirroring health, security audits, cloud checks). Each script has a header documenting its purpose, target versions, and safety. Review before running in production.

## Layout

```
sqlserver/
  .claude-plugin/
    plugin.json                 # plugin manifest (v0.2.0)
    marketplace.json            # marketplace manifest (for /plugin marketplace add)
  README.md
  CLAUDE.md
  skills/
    sql-server/                 # router + fundamentals
    sqlserver-operations/
    sqlserver-monitoring/
    sqlserver-ha-clustering/
    sqlserver-engineering/
    sqlserver-infrastructure/
    sqlserver-cloud/
    sqlserver-security/
    sqlserver-advisor/          # offline DuckDB analysis & recommendations
```

Each domain skill contains a `SKILL.md`, deep `references/` documents, and (where applicable) a `scripts/` library.

## License

MIT
