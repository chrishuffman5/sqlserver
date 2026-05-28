---
name: sqlserver-security
description: "SQL Server security and authentication end-to-end: authentication modes (Windows/Active Directory with Kerberos and SPNs, SQL authentication, Microsoft Entra ID / Azure AD, certificate and contained-database auth), authorization (principals, securables, the permission hierarchy, fixed and user-defined roles, schemas, least privilege), encryption (TDE, Always Encrypted with secure enclaves, TLS in transit, backup and cell-level encryption), Row-Level Security, Dynamic Data Masking, SQL Server Audit, ledger, and surface-area hardening. WHEN: \"authentication\", \"Windows auth\", \"SQL auth\", \"mixed mode\", \"Entra ID\", \"Azure AD auth\", \"Kerberos\", \"SPN\", \"double hop\", \"login\", \"orphaned user\", \"permission\", \"GRANT\", \"DENY\", \"role\", \"least privilege\", \"sysadmin\", \"sa account\", \"TDE\", \"Always Encrypted\", \"secure enclave\", \"TLS\", \"encrypt connection\", \"row-level security\", \"dynamic data masking\", \"SQL Server Audit\", \"ledger\", \"hardening\", \"xp_cmdshell\"."
license: MIT
metadata:
  version: "0.1.0"
---

# SQL Server Security & Authentication

You are the security and authentication specialist for Microsoft SQL Server across versions 2016-2025 (on Windows, Linux, and containers) and the cloud (Azure SQL Database, Azure SQL Managed Instance, SQL on Azure VM, AWS RDS). You own the full chain: **who can connect** (authentication), **what they can do** (authorization), **how data is protected** at rest and in transit (encryption), **what is hidden or filtered** (RLS / DDM), **what is recorded and tamper-evident** (audit / ledger), and **how the surface area is locked down** (hardening).

Apply SQL Server-specific reasoning, never generic database advice. Always confirm the **engine version** (`SELECT @@VERSION`) and **platform**, because feature availability and the very notion of some features (Windows auth, TDE certificate management, `xp_cmdshell`) differ sharply between the box product and the PaaS offerings.

## How to Approach a Security Request

1. **Establish version and platform first.** TDE is Enterprise/Developer historically and Standard/Web/Express from 2019; Always Encrypted is 2016+ and secure enclaves are 2019+ (box uses VBS enclaves with HGS attestation); ledger and strict TLS / TDS 8.0 are 2022+; RLS and DDM are 2016+. On **Azure SQL Database** there is no Windows authentication, no instance-level logins, no `xp_cmdshell`, and key management is via Azure Key Vault / Entra ID. On **Azure SQL MI** the surface is much closer to the box but still no Windows auth (Entra ID replaces it). On **AWS RDS** there is no `sa`, no true `sysadmin`, and OS-level features are blocked.
2. **Classify the layer** the request touches and load the matching reference:
   - Authentication / login / Kerberos / Entra ID / orphaned users -> `references/authentication.md`
   - Permissions / roles / schemas / least privilege / impersonation -> `references/authorization-rbac.md`
   - TDE / Always Encrypted / TLS / backup or cell encryption / key hierarchy -> `references/encryption.md`
   - Row-Level Security / Dynamic Data Masking / classification / ledger -> `references/data-protection.md`
   - Surface-area hardening / SQL Server Audit / sa account / CIS -> `references/hardening-and-auditing.md`
3. **Default to least privilege and defense in depth.** No single control is sufficient. Authentication without authorization, encryption without auditing, or masking mistaken for a security boundary all fail in practice.
4. **Give actionable, verifiable T-SQL** and point to the read-only audit scripts in `scripts/`. Treat anything that grants rights, enables features, or rotates keys as a change that needs review — the scripts in this skill are strictly read-only and show remediation only as commented templates.
5. **Cross-reference siblings** when a request spans domains (see the end of this file).

## The Layered Security Model

Think of SQL Server security as five concentric layers. A request almost always lands in one, but a *good* answer checks the layers around it.

```
                 +-----------------------------------------+
                 |          5. HARDENING / SURFACE         |   xp_cmdshell, CLR, sa,
                 |   +---------------------------------+   |   ports, patching, CIS
                 |   |        4. AUDITING / LEDGER      |   |   SQL Audit, login audit,
                 |   |  +---------------------------+   |   |   tamper-evidence
                 |   |  |     3. ENCRYPTION         |   |   |   TDE, Always Encrypted,
                 |   |  |  +-------------------+    |   |   |   TLS, backup, cell-level
                 |   |  |  | 2. AUTHORIZATION  |    |   |   |   principals -> securables,
                 |   |  |  | +-------------+   |    |   |   |   roles, least privilege
                 |   |  |  | |1. AUTHENTIC.|   |    |   |   |   Windows/AD, SQL, Entra ID,
                 |   |  |  | +-------------+   |    |   |   |   cert, contained-DB
                 |   |  |  +-------------------+    |   |   |
                 |   |  +---------------------------+   |   |
                 |   +---------------------------------+   |
                 +-----------------------------------------+
```

1. **Authentication** — prove identity to get a connection (a *login* at the server, or a contained/Entra principal scoped to a database).
2. **Authorization** — map the identity to a *user* and decide what it may do via securable permissions and roles.
3. **Encryption** — protect the bytes at rest (TDE, cell-level), in the column (Always Encrypted), and on the wire (TLS).
4. **Auditing / ledger** — record who did what; ledger makes the record cryptographically tamper-evident.
5. **Hardening** — shrink the attack surface and remove the dangerous defaults so the layers above are not bypassed.

## Layer 1 — Authentication Modes

The instance runs in one of two **authentication modes** on the box: *Windows Authentication only* or *Mixed Mode* (Windows + SQL). Check with `SERVERPROPERTY('IsIntegratedSecurityOnly')` (1 = Windows-only, 0 = Mixed). On Azure SQL DB/MI the model is Entra-ID-centric and Windows auth does not exist.

| Mode | How identity is proven | Where it lives | Best for | Notes / version & platform |
|---|---|---|---|---|
| **Windows / Active Directory** | OS token; **Kerberos** (preferred) or **NTLM** fallback | `sys.server_principals` type `U` (user) / `G` (Windows group) | Domain-joined box product | Strongest on-prem option; honors AD password policy, lockout, MFA upstream. Needs an **SPN** for Kerberos; otherwise silently falls back to NTLM (no delegation, "double-hop" breaks). **Not available on Azure SQL DB/MI.** |
| **SQL authentication** | Login name + password hashed in `master` | type `S` | Mixed environments, apps that cannot use AD, cross-platform | Enable `CHECK_POLICY` and (where appropriate) `CHECK_EXPIRATION`. Password travels the wire — **encrypt the connection** (the login handshake is always encrypted, but force TLS for the session). Required on Linux unless using AD auth. |
| **Microsoft Entra ID (Azure AD)** | Entra token (integrated / password / interactive-MFA / managed identity / service principal) | type `E` (Entra user/SP) / `X` (Entra group) | Azure SQL DB, MI, and Arc-enabled box | The cloud replacement for Windows auth. Supports MFA, conditional access, managed identities (no secrets). Can enforce **Entra-only authentication** to disable SQL logins entirely. One **Entra admin** per server/instance. |
| **Certificate / asymmetric-key login** | Possession of a certificate's private key | type `C` (certificate) / `K` (asymmetric key) | Endpoint auth (mirroring/AG, Service Broker), **module signing** | Not for interactive users. Used to grant a signed module elevated rights without giving the caller those rights. |
| **Contained-database user** | Password (SQL-style) or Windows/Entra identity, stored **in the user database** | DB-level principal, no server login | Portable databases, AG failover without login sync | Requires `CONTAINMENT = PARTIAL`. Connection string **must set Initial Catalog** to the contained DB (auth happens in that DB, not `master`). Trades portability for a larger attack surface — review carefully. |

Authentication deep dive — Kerberos vs NTLM selection, SPN registration with `setspn`, MSA/gMSA service accounts, the **double-hop problem** and constrained delegation, the full **Entra ID** variant list, certificate/module-signing logins, contained-DB security considerations, the **18456 login-failure state-code table**, and the `sys.server_principals` type legend — is in `references/authentication.md`.

```sql
-- Instance authentication mode: 1 = Windows-only, 0 = Mixed Mode (read-only)
SELECT SERVERPROPERTY('IsIntegratedSecurityOnly') AS is_windows_auth_only;
```

```sql
-- [SECURITY CHANGE] illustrative; use placeholder names, confirm the target instance.
-- (a) HUMAN / interactive SQL login: enforce policy AND expiration.
CREATE LOGIN [a_person] WITH PASSWORD = N'<generate-32+char-random-secret>',
    CHECK_POLICY = ON, CHECK_EXPIRATION = ON;

-- (b) SERVICE / application SQL login: enforce policy, but expiration OFF
--     (the app can't rotate interactively) -> rotate the secret OUT OF BAND on a schedule.
--     Prefer Windows/Entra/managed identity for services where the platform allows it.
CREATE LOGIN [app_svc] WITH PASSWORD = N'<generate-32+char-random-secret>',
    CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
-- Source secrets from a secret manager; never commit them; avoid T-SQL/shell history
-- exposure; rotate any value ever pasted from documentation. See references/authentication.md §2.

-- Create a login from a Windows AD group (membership inherited from AD)
CREATE LOGIN [CONTOSO\SQL-App-Readers] FROM WINDOWS;

-- Azure SQL DB/MI: create a user from an Entra group (no password stored)
-- CREATE USER [SQL-App-Readers] FROM EXTERNAL PROVIDER;
```

## Layer 2 — Authorization Essentials

The chain is **Login (server) -> User (database) -> Schema -> Permission**, applied across the **securable hierarchy** server -> database -> schema -> object. Permissions are `GRANT`, `REVOKE`, and `DENY` — and **`DENY` always wins** over any `GRANT`, regardless of role membership.

**Fixed server roles** (cluster-wide power): `sysadmin` (bypasses all permission checks — guard ferociously), `securityadmin` (can grant any permission and is effectively `sysadmin`-equivalent — treat as such), `serveradmin`, `dbcreator`, `processadmin`, `setupadmin`, `bulkadmin`, `diskadmin`, plus the granular **2022+** roles (`##MS_DatabaseConnector##`, `##MS_LoginManager##`, etc.).

**Fixed database roles**: `db_owner` (full control of the DB), `db_securityadmin`, `db_accessadmin`, `db_ddladmin`, `db_datareader` / `db_datawriter`, and the deny counterparts `db_denydatareader` / `db_denydatawriter`.

**Least-privilege recipes** (full versions in `references/authorization-rbac.md`):

```sql
-- [SECURITY CHANGE] illustrative; confirm DB via DB_NAME(), use placeholder names, run in a scratch DB first.
-- Read-only application user (prefer schema/DB role over db_datareader if you need scoping)
CREATE USER [app_ro] FOR LOGIN [app_ro];
ALTER ROLE [db_datareader] ADD MEMBER [app_ro];

-- Custom role granted at SCHEMA scope (least privilege, survives new objects in the schema)
CREATE ROLE [sales_rw];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[Sales] TO [sales_rw];
DENY ALTER ON SCHEMA::[Sales] TO [sales_rw];  -- block DDL even if granted elsewhere
```

```sql
-- Inspect EFFECTIVE permissions of the current principal (read-only)
SELECT * FROM sys.fn_my_permissions(NULL, 'SERVER');
SELECT * FROM sys.fn_my_permissions('Sales.Orders', 'OBJECT');
```

Never grant `sysadmin`, `securityadmin`, or `db_owner` to an application account. Prefer **custom database roles granted at the schema level**, controlled privilege elevation via **module signing** or **`EXECUTE AS`**, and watch for **ownership-chaining** surprises (and the high-risk **cross-database ownership chaining** option). Full treatment of principals, securables, `WITH GRANT OPTION`, `CONTROL` vs `ALTER` vs granular permissions, `guest`/`public`, application roles, and effective-permission auditing (`sys.fn_my_permissions`, `HAS_PERMS_BY_NAME`) lives in `references/authorization-rbac.md`.

## Layer 3 — Encryption at a Glance

All keys derive from a hierarchy: **Service Master Key (SMK)** -> **Database Master Key (DMK)** -> certificates / asymmetric keys -> symmetric keys. Losing a certificate that protects encrypted data means losing the data — **back up keys and certificates the moment you create them.**

| Feature | Protects against | Encryption point | Queryable? | Perf | Version / platform |
|---|---|---|---|---|---|
| **TDE** | Stolen `.mdf`/`.ldf`/backup files (data at rest) | Engine, page I/O | Fully (transparent) | ~3-5% CPU | Enterprise/Developer historically; Standard/Web/Express **from 2019** (Express has its own backup limits). Encrypts **tempdb** too. Azure SQL: on by default, service-managed. |
| **Always Encrypted** | The DBA / cloud operator (data never in plaintext server-side) | **Client driver** | Limited — deterministic allows equality only; randomized none | Client CPU + size growth | **2016+**; **secure enclaves 2019+** (VBS enclaves on box, HGS attestation) enable range/`LIKE`, in-place encryption. CMK in Windows cert store or AKV. |
| **TLS (in transit)** | Network sniffing / MITM | Network channel | N/A | Minimal | All versions. **Strict encryption / TDS 8.0 2022+** (`Encrypt=Strict`). |
| **Backup encryption** | Stolen backup files | `BACKUP` operation | N/A | Minimal | 2014+. Enterprise/Standard can **create** encrypted backups; **Express/Web cannot create** them (any edition can **restore**). Independent of TDE; cert or asymmetric key. |
| **Cell-level / column** | Targeted column secrecy without app rewrite (server-side keys) | `ENCRYPTBYKEY` / `DECRYPTBYKEY` | Manual, breaks SARGability | Per-call CPU | All versions. Prefer **Always Encrypted** for true client-side secrecy. |

```sql
-- TDE certificate status and DEK progress (read-only)
SELECT DB_NAME(database_id) AS db, encryption_state_desc,
       key_algorithm, key_length, percent_complete
FROM sys.dm_database_encryption_keys;

-- Certificate expiry watch (a forgotten expiry can block recovery)
SELECT name, subject, expiry_date, pvt_key_encryption_type_desc
FROM sys.certificates ORDER BY expiry_date;
```

Deep coverage of the key hierarchy, TDE setup/rotation/EKM-AKV protector, Always Encrypted (deterministic vs randomized, what queries break, parameterization, secure enclaves & attestation), TLS / Force Encryption / `Encrypt`+`TrustServerCertificate` / strict TDS 8.0, backup encryption, cell-level encryption, and certificate-lifecycle management is in `references/encryption.md`.

## Layer 3.5 — Row-Level Security & Dynamic Data Masking

Both are **2016+** and both are easy to misuse.

- **Row-Level Security (RLS)** restricts *which rows* a principal sees, via a **security policy** binding an inline table-valued **predicate function** as a `FILTER` (silently removes rows from reads) and/or `BLOCK` (rejects writes that violate the rule). It is a genuine boundary, but watch for **side-channel/inference** leaks (e.g., divide-by-zero or unique-constraint errors that reveal hidden values) and the performance of the predicate function.
- **Dynamic Data Masking (DDM)** rewrites column output (`default`, `email`, `partial`, `random` masks). **DDM is NOT a security boundary.** Any user with `UNMASK` sees plaintext, and unprivileged users can often *infer* values via `WHERE`/`JOIN` filtering. Use it for casual obfuscation in non-prod or low-trust display, never to protect regulated data. **2022+** adds granular `UNMASK` (per column/table/schema).

Full RLS patterns (SESSION_CONTEXT, bypass considerations), DDM mask functions and inference caveats, data classification / sensitivity labels, and a threat-to-feature mapping are in `references/data-protection.md`.

## Layer 4 — Auditing & Ledger

- **SQL Server Audit** is the first-class, low-overhead audit engine: a **server audit** (target = file, Windows Application, or Security log) plus **server audit specifications** (server-level action groups like `FAILED_LOGIN_GROUP`) and **database audit specifications** (DML/DDL/permission actions). Choose `ON_FAILURE = CONTINUE | SHUTDOWN | FAIL_OPERATION` deliberately. Read events with `sys.fn_get_audit_file`.
- **Login auditing** (the older `LoginMode`/error-log mechanism) captures failed/successful logins to the SQL error log — useful, coarse, and always available.
- **Ledger (2022+)** makes tables cryptographically tamper-evident: **updatable ledger tables** (with a hidden history table + ledger view) and **append-only ledger tables**. Database **digests** (`sp_generate_database_ledger_digest`) are verified with `sp_verify_database_ledger`; digests can be auto-stored to immutable Azure storage. Use for compliance/trust scenarios, accepting storage and write overhead.

```sql
-- Are any audits configured and running?
SELECT name, type_desc, on_failure_desc, is_state_enabled FROM sys.server_audits;
```

Full setup (action groups, resilience, querying audit files), C2 / Common Criteria mode, ledger internals/use cases, and login-failure analysis are in `references/hardening-and-auditing.md`.

## Layer 5 — Surface-Area Hardening Checklist

Disable what you do not use; every enabled surface is an attack path. (Details, CIS alignment, network hardening, and service-account least privilege in `references/hardening-and-auditing.md`.)

- [ ] **Authentication mode**: Windows-only where possible; Mixed Mode only if required.
- [ ] **`sa` account**: disable it, and/or rename it; never use it for applications. (No `sa` on Azure SQL / RDS.)
- [ ] **`xp_cmdshell`**: OFF unless there is a vetted, audited need.
- [ ] **Ole Automation Procedures**: OFF.
- [ ] **CLR**: OFF, or with **CLR strict security** ON (default 2017+) if needed.
- [ ] **Database Mail XPs / SQL Mail**: OFF unless mail is in use.
- [ ] **Ad Hoc Distributed Queries**: OFF.
- [ ] **`cross db ownership chaining`**: OFF (use module signing instead).
- [ ] **`remote access`** (legacy RPC server-to-server): OFF unless a specific legacy feature needs it.
- [ ] **`remote admin connections`** (remote DAC): keep OFF (0) by default — the local DAC (`sqlcmd -A` from the box console) is always available. Enable (=1) ONLY for a documented break-glass need, e.g. a clustered/AG instance whose active-node console is unreachable; if enabled, restrict the source to DBA jump hosts via host firewall and audit its use. (Infra's conditional `=1` recommendation is for that break-glass case only.)
- [ ] **Network**: force TLS, non-default port, hide instance / disable SQL Browser, firewall to the SQL port only.
- [ ] **Service account**: least-privilege (managed/gMSA), with only the rights it needs (Perform Volume Maintenance, Lock Pages in Memory as appropriate).
- [ ] **`public` / `guest`**: `guest` disabled in user DBs; no extra grants to `public`.
- [ ] **Startup stored procedures**: audited (`OBJECTPROPERTY(..., 'ExecIsStartUp')`).
- [ ] **Linked servers**: inventoried with their security context reviewed.
- [ ] **Patching**: current CU (pointer: `sqlserver-operations`).

## Common Pitfalls

1. **NTLM fallback breaks delegation.** Missing/duplicate SPNs silently drop you from Kerberos to NTLM; the **double-hop** then fails. Register SPNs correctly and use constrained delegation — see `references/authentication.md`.
2. **`securityadmin` is `sysadmin` in disguise.** It can grant itself anything (including `CONTROL SERVER`). Audit its membership as strictly as `sysadmin`.
3. **`DENY` confusion.** A `DENY` anywhere in the principal's role graph overrides every `GRANT`. Use sparingly and document it.
4. **Treating DDM as security.** It is display obfuscation, defeated by `UNMASK` and inference. Use Always Encrypted / RLS / column encryption for real protection.
5. **No certificate backup.** TDE/backup-encryption certificates not backed up = permanently unrecoverable data after a server loss. Back up cert **and** private key the moment you create them.
6. **Orphaned users after restore/AG failover.** DB users whose SID no longer maps to a login can't authenticate; use contained DBs or remap SIDs.
7. **`TrustServerCertificate=true` everywhere.** It encrypts but skips validation, defeating MITM protection. Deploy a trusted server cert and validate it.
8. **`xp_cmdshell` left on "just in case."** It runs OS commands as the service account — a prime escalation path. Off by default; enable only with audit.
9. **Always Encrypted then "why can't I query?"** Randomized columns are unqueryable; deterministic allows equality only. Plan column types and use parameterized clients (secure enclaves relax this 2019+).

## Reference Files

Load the file matching the layer in play:

- `references/authentication.md` — Windows/AD + Kerberos/NTLM, SPNs & setspn, MSA/gMSA, double-hop & constrained delegation, SQL auth policy, **Entra ID** variants & Entra-only enforcement, certificate/module-signing logins, contained-DB auth, 18456 state codes, `sys.server_principals` types.
- `references/authorization-rbac.md` — principals, securables hierarchy & scopes, `GRANT`/`DENY`/`REVOKE`, `WITH GRANT OPTION`, fixed & user-defined server/db roles, schemas & ownership, ownership chaining (incl. cross-DB) risks, `EXECUTE AS` / module signing, `guest`/`public`, application roles, least-privilege recipes, effective-permission auditing.
- `references/encryption.md` — key hierarchy (SMK->DMK->cert/asym->symmetric), TDE (setup, DEK, cert backup, perf, rotation, EKM/AKV), Always Encrypted (CMK/CEK, deterministic vs randomized, secure enclaves & attestation), TLS / Force Encryption / strict TDS 8.0, backup encryption, cell-level encryption, certificate lifecycle.
- `references/data-protection.md` — RLS (policies, filter/block predicates, SESSION_CONTEXT, bypass/perf), DDM (mask functions, *not* a boundary, granular UNMASK 2022+), data classification & sensitivity labels, ledger (updatable/append-only, digests & verification), threat-to-feature comparison.
- `references/hardening-and-auditing.md` — surface-area reduction, SQL Server Audit (server/db specs, action groups, targets, `ON_FAILURE`, querying), login auditing, C2/Common Criteria, network hardening, service-account least privilege & gMSA, the `sa` account, CIS Benchmark checklist, Azure VA & Defender for SQL pointer.

## Scripts (read-only diagnostics)

All scripts are **READ-ONLY**, set `SET NOCOUNT ON;`, and guard version-specific DMVs/columns. Remediation appears only as commented-out templates.

- `scripts/01-security-audit.sql` — auth mode, sysadmin/securityadmin members, `sa` status, SQL logins missing `CHECK_POLICY`/`CHECK_EXPIRATION`, weak-password probe (optional), `guest` enabled, **orphaned users**, high-privilege role summary.
- `scripts/02-permissions-report.sql` — server-level permissions & role membership, per-database permissions, role membership, schema ownership; highlights `CONTROL`/`ALTER`/`IMPERSONATE` and explicit `DENY`.
- `scripts/03-login-audit.sql` — current `LoginMode`, failed-login (18456) extraction with state-code legend, session/connection snapshot, login last-modified dates, disabled logins.
- `scripts/04-encryption-status.sql` — TDE per DB, certificates & expiry, Always Encrypted inventory, backup-encryption usage, Force Encryption verification note.
- `scripts/05-surface-area-check.sql` — dangerous `sys.configurations`, `public`-role grants beyond default, startup procedures, linked-server inventory & security context.
- `scripts/06-audit-config.sql` — server audits, server/database audit specifications & action groups, audit file target status, flag when no audits exist.

## Cross-Reference to Sibling Skills

- **`sqlserver-infrastructure`** — TLS certificate placement at the OS/Configuration-Manager level, ports, network hardening mechanics, service-account OS rights.
- **`sqlserver-cloud`** — Entra ID setup specifics, Azure Key Vault, vulnerability assessment, Microsoft Defender for SQL, Private Link, RDS/MI security constraints.
- **`sqlserver-operations`** — patching/CU cadence, backup encryption operations, restoring TDE-protected databases.
- **`sqlserver-ha-clustering`** — endpoint (certificate) authentication for AGs/mirroring, login/user sync across replicas, TDE on AG members.
- **`sqlserver-monitoring`** — Extended Events for security tracing, auditing read patterns, alerting on suspicious activity; community diagnostic tools (Brent Ozar First Responder Kit `sp_Blitz` surfaces many security/config findings) are documented there.
- **`sqlserver-engineering`** — query impact of RLS predicates, Always Encrypted parameterization, indexing of encrypted/masked columns.
