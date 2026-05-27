# SQL Server Plugin

Dedicated Microsoft SQL Server expertise across the full management lifecycle and all deployment targets (box 2016-2025 on Windows/Linux/containers; Azure SQL Database, Azure SQL Managed Instance, SQL on Azure VM, AWS RDS, Google Cloud SQL).

## Skills

- **`sql-server`** — top-level router + cross-cutting fundamentals (version/edition/platform matrices, storage engine, recovery models, isolation levels). Start here for general or cross-domain SQL Server questions.
- **`sqlserver-operations`** — backup/recovery, maintenance, DBCC, SQL Agent, patching, capacity.
- **`sqlserver-monitoring`** — waits, DMVs, Query Store, Extended Events, blocking, deadlocks.
- **`sqlserver-ha-clustering`** — Always On AGs, FCI/WSFC, mirroring + endpoints, log shipping, replication, DR.
- **`sqlserver-engineering`** — T-SQL, indexing, plans, query optimization, statistics, partitioning, schema design.
- **`sqlserver-infrastructure`** — instance/OS config, memory, MAXDOP, tempdb, trace flags, storage, Linux/containers, network.
- **`sqlserver-cloud`** — Azure SQL DB/MI, SQL on VM, AWS RDS, Cloud SQL, geo-replication, migration.
- **`sqlserver-security`** — authentication, authorization, encryption, RLS/DDM, auditing, ledger, hardening.

## Conventions

- Always establish **engine version** (`SELECT @@VERSION`) and **database compatibility level** before giving version-sensitive advice.
- Identify the **deployment platform** — feature surface differs sharply between box, Azure SQL DB, Managed Instance, and RDS.
- Bundled `.sql` scripts under each skill's `scripts/` folder are **read-only diagnostics**. They carry headers documenting purpose, target versions, and safety. Recommend review before running in production.
