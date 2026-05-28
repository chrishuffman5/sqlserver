# SQL Server Hardening & Auditing Reference

This layer reduces the **attack surface** (disable dangerous defaults) and establishes **accountability** (record who did what, tamper-evidently). Hardening keeps the authentication/authorization/encryption layers from being bypassed; auditing proves they worked. Pair this with the encryption-in-transit material in `encryption.md` and the cloud equivalents in `sqlserver-cloud`.

---

## 1. Surface-Area Reduction

Every enabled feature is a potential attack path. Disable what you don't use. Inspect with `sys.configurations` (`scripts/05` automates this); change with `sp_configure` + `RECONFIGURE` (shown as commented templates — these are *changes*, review first).

| Configuration | Default | Why it's risky | Recommendation |
|---|---|---|---|
| **`xp_cmdshell`** | 0 (off) | Runs **OS shell commands** as the SQL service account — prime privilege escalation | OFF. Enable only with a vetted, audited need; least-privilege the service account. |
| **`Ole Automation Procedures`** | 0 | `sp_OACreate` etc. instantiate COM objects in-process — code execution | OFF. |
| **`clr enabled`** | 0 | Runs .NET assemblies in-engine | OFF unless required; if on, keep **CLR strict security** ON. |
| **`clr strict security`** | 1 (2017+) | When off, `SAFE`/`EXTERNAL_ACCESS` assemblies skip signing checks | Keep ON. Sign assemblies. |
| **`Database Mail XPs`** | 0 | Outbound mail subsystem | OFF unless DB Mail is used. |
| **`Ad Hoc Distributed Queries`** | 0 | `OPENROWSET`/`OPENDATASOURCE` reach external sources ad hoc | OFF. Use defined linked servers if needed. |
| **`cross db ownership chaining`** | 0 | Lets ownership chains cross databases -> cross-DB escalation | OFF (use module signing). |
| **`remote access`** | 1 (legacy) | Legacy server-to-server RPC (`sp_addserver`-era heterogeneous queries) — distinct from remote DAC | OFF unless a specific legacy feature needs it. |
| **`remote admin connections`** (remote DAC) | 0 | Dedicated Admin Connection over the **network** | Keep **OFF (0)** by default — the **local DAC** (`sqlcmd -A` from the box console) is always available. Enable (=1) ONLY for a documented **break-glass** need, e.g. a clustered/AG instance whose active-node console is unreachable. If enabled, restrict the source to **DBA jump hosts via host firewall** and **audit** its use. (`sqlserver-infrastructure`'s conditional `=1` recommendation is for that break-glass case only — the wording is harmonized across both skills.) |
| **`scan for startup procs`** | 0 | Allows auto-run procs at startup | Audit which procs are flagged (below). |

```sql
-- READ-ONLY: current state of the dangerous surface
SELECT name, value_in_use, description
FROM sys.configurations
WHERE name IN ('xp_cmdshell','Ole Automation Procedures','clr enabled',
               'clr strict security','Database Mail XPs','remote access',
               'Ad Hoc Distributed Queries','cross db ownership chaining',
               'remote admin connections','scan for startup procs')
ORDER BY name;

-- CHANGE TEMPLATE (review before running):
-- EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
-- EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE;
```

### Startup stored procedures
A proc marked to run at startup executes as a high-privilege context every time the service starts — a persistence mechanism for attackers. Audit them:
```sql
SELECT name FROM sys.procedures WHERE OBJECTPROPERTY(object_id, 'ExecIsStartUp') = 1;
-- and instance flag:
SELECT value_in_use FROM sys.configurations WHERE name = 'scan for startup procs';
```

### Linked servers
Each linked server carries a **security context** (the mapping that decides which credential is used to the remote). A linked server mapped with a high-privilege remote login is an escalation bridge. Inventory and review:
```sql
SELECT s.name AS linked_server, s.product, s.provider, s.data_source,
       l.uses_self_credential, l.remote_name
FROM sys.servers s
LEFT JOIN sys.linked_logins l ON s.server_id = l.server_id
WHERE s.is_linked = 1;
```

---

## 2. SQL Server Audit

The first-class, low-overhead audit framework. Three objects:

1. **Server Audit** — *where* events go: a **file**, the **Windows Application log**, or the **Windows Security log** (most tamper-resistant). Defines `ON_FAILURE` behavior and the queue/buffering.
2. **Server Audit Specification** — *what server-level* actions to capture (action **groups** like `FAILED_LOGIN_GROUP`, `SUCCESSFUL_LOGIN_GROUP`, `SERVER_ROLE_MEMBER_CHANGE_GROUP`, `SERVER_PERMISSION_CHANGE_GROUP`, `AUDIT_CHANGE_GROUP`).
3. **Database Audit Specification** — *what database-level* actions to capture (action groups **and** specific actions like `SELECT`, `UPDATE`, `EXECUTE` on objects/principals).

```sql
-- 1. Server audit to a file (CHANGE TEMPLATE)
-- CREATE SERVER AUDIT [SecAudit]
--   TO FILE (FILEPATH = N'D:\Audit\', MAXSIZE = 256 MB, MAX_ROLLOVER_FILES = 20)
--   WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
-- ALTER SERVER AUDIT [SecAudit] WITH (STATE = ON);

-- 2. Server-level spec (logins + security changes)
-- CREATE SERVER AUDIT SPECIFICATION [SecAudit_Server] FOR SERVER AUDIT [SecAudit]
--   ADD (FAILED_LOGIN_GROUP),
--   ADD (SUCCESSFUL_LOGIN_GROUP),
--   ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
--   ADD (SERVER_PERMISSION_CHANGE_GROUP),
--   ADD (AUDIT_CHANGE_GROUP)
--   WITH (STATE = ON);

-- 3. Database-level spec (sensitive table access)
-- CREATE DATABASE AUDIT SPECIFICATION [SecAudit_DB] FOR SERVER AUDIT [SecAudit]
--   ADD (SELECT, UPDATE, DELETE ON dbo.Salary BY public),
--   ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP)
--   WITH (STATE = ON);
```

### ON_FAILURE — choose deliberately
| Value | If the audit target can't be written | Use when |
|---|---|---|
| `CONTINUE` | Keep running, lose the events | Availability > completeness |
| `SHUTDOWN` | **Stop the instance** | Compliance demands "no unaudited activity" |
| `FAIL_OPERATION` | Fail the audited statements only | Block the audited action but keep the server up |

### Audit resilience
- The **Security log** target resists tampering by DBAs (needs OS policy: SQL service account granted "generate security audits").
- File targets should live on a separate, access-controlled volume; protect them from the SQL service account where possible.
- `QUEUE_DELAY` trades durability for throughput (0 = synchronous).

### Querying the audit
```sql
-- Read file-target audit records (read-only)
SELECT event_time, action_id, succeeded, server_principal_name,
       database_name, object_name, statement
FROM sys.fn_get_audit_file(N'D:\Audit\*.sqlaudit', NULL, NULL)
ORDER BY event_time DESC;

-- Inventory configured audits & specs (see scripts/06)
SELECT name, type_desc, on_failure_desc, is_state_enabled FROM sys.server_audits;
SELECT * FROM sys.server_audit_specifications;
SELECT * FROM sys.database_audit_specifications;
```

---

## 3. Login Auditing (the older mechanism)

Independent of SQL Server Audit, the instance can log login attempts to the **SQL error log** based on the **`LoginMode`** / login-audit-level setting (None / Failed only / Successful only / Both). At minimum capture **failed** logins. (`scripts/03` extracts and decodes the 18456 events; the state-code table is in `authentication.md`.)

```sql
-- Login audit level (registry value AuditLevel): 0 none,1 success,2 failure,3 both
-- (Read via xp_instance_regread or the error log; changing it needs a restart.)
-- EXEC sp_readerrorlog 0, 1, N'Login failed';   -- failed logins from the current log
```

SQL Server Audit (`FAILED_LOGIN_GROUP`/`SUCCESSFUL_LOGIN_GROUP`) is richer and preferred for compliance; the error-log mechanism is the always-available fallback.

---

## 4. C2 / Common Criteria Compliance Mode

- **C2 audit mode** (deprecated) — legacy all-or-nothing auditing that **shuts down the instance** if it can't write the audit. Superseded by SQL Server Audit; avoid for new work.
- **Common Criteria compliance** (`common criteria compliance enabled`) — enables residual information protection (memory scrubbing), column-level `GRANT`-after-`DENY` behavior, and login-statistics auditing, to meet CC EAL evaluation. Enable only when a certification mandates it; it has behavior and performance implications.

---

## 5. Network Hardening

(Mechanics of TLS/Force Encryption are in `encryption.md`; OS/Configuration-Manager placement is in `sqlserver-infrastructure`.)

- **Force TLS** with a trusted server certificate; prefer **`Encrypt=Strict` / TDS 8.0 (2022+)** for new and internet-facing deployments.
- **Non-default port** — move off 1433 to reduce automated-scan exposure (defense in depth, not a real control by itself).
- **Hide the instance / disable SQL Server Browser** — stops the instance from advertising itself on UDP 1434. For named instances, hardcode the port in clients instead.
- **Firewall** to the SQL port only, from known sources; never expose SQL Server directly to the internet (use VPN/Private Link/bastion — see `sqlserver-cloud`).
- Disable unused **network protocols** (e.g., leave only TCP/IP; disable Named Pipes/Shared Memory exposure where not needed).

---

## 6. Service-Account & OS Least Privilege

- Run SQL Server under a **dedicated, least-privilege** domain account — ideally a **gMSA** (auto-rotating password, auto-SPN; see `authentication.md`). Never `LocalSystem`/Domain Admin.
- Grant only the OS rights the workload needs:
  - **Perform Volume Maintenance Tasks** -> Instant File Initialization (faster file growth/restore; minor info-disclosure trade-off on reused disk space).
  - **Lock Pages in Memory** -> prevents the OS paging out the buffer pool (use judiciously).
  - These are configured per service account; see `sqlserver-infrastructure`.
- Restrict who is a **local administrator** on the SQL host — local admins can read memory and keys and effectively own the instance.

---

## 7. The `sa` Account

`sa` is the built-in SQL `sysadmin` login and a perpetual brute-force target.

- **Disable it**: `ALTER LOGIN [sa] DISABLE;` (and/or **rename** it: `ALTER LOGIN [sa] WITH NAME = [disabled_sa];`).
- Never use `sa` for applications or routine admin; use named, audited sysadmin accounts.
- If Mixed Mode is required and `sa` must exist, give it a long random password and keep it disabled until genuinely needed.
- On **Azure SQL DB/MI** and **AWS RDS** there is **no `sa`** (and no real `sysadmin`); the cloud admin model replaces it.

```sql
SELECT name, is_disabled, modify_date FROM sys.server_principals WHERE name = 'sa';
-- or by well-known SID regardless of rename:
-- SELECT name, is_disabled FROM sys.server_principals WHERE sid = 0x01;
```

---

## 8. CIS Benchmark Alignment Checklist

A condensed, high-value subset of the CIS Microsoft SQL Server Benchmark:

- [ ] Latest service pack / CU applied (pointer: `sqlserver-operations`).
- [ ] `Ad Hoc Distributed Queries` = 0.
- [ ] `clr enabled` = 0 (or strict security on).
- [ ] `cross db ownership chaining` = 0.
- [ ] `Database Mail XPs` = 0 (if mail unused).
- [ ] `Ole Automation Procedures` = 0.
- [ ] `remote access` = 0 (legacy server-to-server RPC); `remote admin connections` (remote DAC) = 0 by default — enable only for a documented break-glass case, then firewall-restrict to DBA jump hosts and audit.
- [ ] `scan for startup procs` = 0 (and startup procs audited).
- [ ] `xp_cmdshell` = 0.
- [ ] `sa` disabled and/or renamed; no blank/weak SQL-login passwords.
- [ ] `CHECK_POLICY` ON for all SQL logins; `CHECK_EXPIRATION` per policy.
- [ ] Windows-only authentication where feasible.
- [ ] `public` server/db permissions = defaults only; `guest` disabled in user DBs.
- [ ] `TRUSTWORTHY` OFF on user databases.
- [ ] Force Encryption / TLS on; modern cipher suites.
- [ ] SQL Server Audit configured for logins + permission/role changes, with appropriate `ON_FAILURE`.
- [ ] SQL Server Browser hidden/disabled where named-instance discovery isn't needed.
- [ ] Service account is least-privilege (gMSA), not a local/domain admin.

`scripts/05-surface-area-check.sql` reports the configuration items, `public` grants, startup procs, and linked servers; `scripts/01` covers `sa`, weak logins, and role membership.

---

## 9. Vulnerability Assessment & Defender for SQL (box *and* cloud)

- **SQL Vulnerability Assessment (VA)** scans against a built-in rule baseline (many CIS-aligned) and tracks drift. **VA is not cloud-only:** it runs **from SSMS against box instances** (right-click a database → Tasks → Vulnerability Assessment) as well as against **Azure SQL DB/MI** — so on-prem DBAs can use it as a built-in alternative to the manual hardening checks here.
- **Microsoft Defender for SQL** adds threat detection (SQL injection, anomalous access, brute force) and surfaces VA findings. It covers **Azure SQL DB/MI** *and* **SQL Server on-premises/other clouds via Azure Arc** (Arc-enabled SQL Server), extending threat protection to box estates.
- **Audit-to-SIEM / immutable storage:** forward SQL Server Audit and login events to a central **SIEM** (e.g. via the Windows Security log → agent, file-target ingestion, or — in Azure — diagnostic settings to Log Analytics/Event Hub). Store the audit trail on **append-only / immutable storage** (WORM, or Azure Blob with an immutability policy) so a compromised DBA cannot rewrite history — the same principle as ledger digest auto-storage (`data-protection.md`).
- Combine with **Entra-only authentication**, **Private Link**, and **AKV-managed keys**.

> **Verify 2025 security additions on Microsoft Learn.** SQL Server 2025 adds/changes security surface (e.g. evolving Entra integration on box, JSON/vector and other new surfaces, and updated defaults). Confirm the exact feature set and edition gates for your build on Microsoft Learn before relying on a 2025-specific control.

Setup and Azure-side specifics live in **`sqlserver-cloud`**. Patching cadence lives in **`sqlserver-operations`**. OS-level network/account configuration lives in **`sqlserver-infrastructure`**.
