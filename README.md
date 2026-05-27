# SQL Server Plugin

A dedicated Claude Code plugin for **Microsoft SQL Server**, covering the full database-management lifecycle: operations, monitoring, high availability / clustering, availability groups, mirroring endpoints, engineering, infrastructure, cloud offerings, and security / authentication.

Scope spans the box product (**SQL Server 2016 → 2025** on Windows, Linux, and containers) and the cloud families (**Azure SQL Database**, **Azure SQL Managed Instance**, **SQL Server on Azure VM**, **AWS RDS for SQL Server**, **Google Cloud SQL**).

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

## How to use

Just describe what you need — Claude routes to the right skill automatically. Examples:

- *"My SQL Server 2019 instance has high `PAGEIOLATCH` waits"* → `sqlserver-monitoring`
- *"Design a backup strategy with a 5-minute RPO"* → `sqlserver-operations`
- *"Set up a contained availability group on SQL 2022"* → `sqlserver-ha-clustering`
- *"How do I configure a database mirroring endpoint with certificate auth?"* → `sqlserver-ha-clustering`
- *"Migrate an on-prem DB to Azure SQL Managed Instance"* → `sqlserver-cloud`
- *"Lock this instance down to least privilege with Entra ID auth"* → `sqlserver-security`

## Diagnostic scripts

Every operational domain ships a `scripts/` folder of **read-only** T-SQL diagnostics (health, waits, blocking, AG/mirroring health, security audits, cloud checks). Each script has a header documenting its purpose, target versions, and safety. Review before running in production.

## Layout

```
sqlserver/
  .claude-plugin/plugin.json
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
```

Each domain skill contains a `SKILL.md`, deep `references/` documents, and (where applicable) a `scripts/` library.

## License

MIT
