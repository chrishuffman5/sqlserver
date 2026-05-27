# SQL Server Authorization & RBAC Reference

Authorization answers **"what may this identity do?"** once authentication (see `authentication.md`) has let it connect. SQL Server's model is **principals** (who) acting on **securables** (what) via **permissions** (how), organized into **roles** for manageability. The governing rule throughout: **permissions are additive, but a single `DENY` overrides every `GRANT`.**

---

## 1. Principals

A **principal** is anything that can request a securable. They exist at two scopes:

**Server-level principals** (`sys.server_principals`):
- **Logins** — SQL, Windows user/group, certificate/asym-key, Entra (see `authentication.md`).
- **Server roles** — fixed (`sysadmin`, etc.) and **user-defined server roles** (2012+).

**Database-level principals** (`sys.database_principals`):
- **Database users** — usually mapped to a login by SID; can also be contained (no login), mapped to a certificate/key, or `WITHOUT LOGIN` (for `EXECUTE AS`).
- **Database roles** — fixed (`db_owner`, etc.) and user-defined.
- **Application roles** — a password-activated role that *replaces* the session's identity for the duration of a connection (see §8).

```sql
-- Server principals and their kind
SELECT name, type_desc, is_disabled FROM sys.server_principals ORDER BY type_desc, name;

-- Database users and how they map
SELECT dp.name, dp.type_desc, dp.authentication_type_desc,
       sp.name AS mapped_login
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type NOT IN ('R')  -- exclude roles for this view
ORDER BY dp.type_desc, dp.name;
```

A database user **mapped to a login by SID** breaks if the login is dropped/recreated with a new SID — the classic **orphaned user** (detected in `scripts/01`). Contained users avoid this entirely.

---

## 2. Securables & the Hierarchy

A **securable** is anything access can be granted on, nested in scopes. Permissions granted at a higher scope cascade downward (covering permissions):

```
SERVER scope
   ├── Logins, Endpoints, Availability Groups, Server roles
   └── DATABASE scope
          ├── Users, DB roles, Schemas, Certificates, Keys, Full-text catalogs
          └── SCHEMA scope
                 └── OBJECT scope (tables, views, procedures, functions, types, ...)
                        └── COLUMN scope (column-level GRANT/DENY)
```

Granting at the **schema** scope is the least-privilege sweet spot: a single `GRANT SELECT ON SCHEMA::Sales` covers all current *and future* objects in that schema without object-by-object maintenance. Granting at the **server** scope (`CONTROL SERVER`) is near-`sysadmin`.

---

## 3. The Permission Model: GRANT / DENY / REVOKE

| Statement | Effect |
|---|---|
| **`GRANT`** | Allow the permission. Additive across all the principal's roles/grants. |
| **`DENY`** | Explicitly forbid. **Overrides every `GRANT`**, including those inherited via roles. (Exception: `sysadmin`/object owner bypass checks.) |
| **`REVOKE`** | Remove a prior `GRANT` *or* `DENY` (returns to neutral/inherited). Not the same as `DENY`. |

```sql
GRANT SELECT ON SCHEMA::Sales TO analyst_role;
DENY  SELECT ON OBJECT::Sales.SalaryAudit TO analyst_role;  -- carve-out wins everywhere
REVOKE SELECT ON OBJECT::Sales.SalaryAudit TO analyst_role; -- back to the schema GRANT
```

**Effective permission = (any GRANT) AND (no DENY anywhere).** Because `DENY` is so absolute, reserve it for deliberate exceptions to a broad grant; do not use `DENY` as the default way to "not grant" — simply omitting the grant is cleaner.

### `WITH GRANT OPTION`

`GRANT ... WITH GRANT OPTION` lets the grantee re-grant that permission to others. Revoking it later requires `REVOKE ... CASCADE` to also strip everyone they granted. Use sparingly — it disperses authority.

```sql
GRANT EXECUTE ON SCHEMA::Reporting TO lead_role WITH GRANT OPTION;
REVOKE EXECUTE ON SCHEMA::Reporting TO lead_role CASCADE;
```

### CONTROL vs ALTER vs granular

- **`CONTROL`** on a securable = ownership-like full power over it *and everything beneath it* (e.g., `CONTROL` on a DB ≈ `db_owner`; `CONTROL SERVER` ≈ `sysadmin`). Grant rarely.
- **`ALTER`** = change the definition/structure (but not necessarily read the data) of the securable and create objects within it.
- **Granular** (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `EXECUTE`, `REFERENCES`, `VIEW DEFINITION`, `IMPERSONATE`, ...) — prefer these; they express intent precisely. `VIEW DEFINITION` controls metadata visibility; `IMPERSONATE` allows `EXECUTE AS` of another principal (audit it — it is a privilege-escalation vector).

---

## 4. Fixed Server Roles

Members get fixed, instance-wide power. Audit membership of the top three as carefully as each other:

| Role | Power | Risk |
|---|---|---|
| **`sysadmin`** | Bypasses **all** permission checks; can do anything | Maximum — minimize membership, never for apps |
| **`securityadmin`** | Manages logins & **can `GRANT` any permission** | **Effectively `sysadmin`** — it can grant itself `CONTROL SERVER`. Treat identically. |
| **`serveradmin`** | Server-wide configuration, shutdown | High |
| **`dbcreator`** | Create/alter/drop/restore any database | High (restore = code execution vector) |
| **`processadmin`** | Kill sessions, manage processes | Medium |
| **`setupadmin`** | Linked servers, startup procs | Medium |
| **`bulkadmin`** | `BULK INSERT` (reads OS files as service acct) | Medium |
| **`diskadmin`** | Manage disk files | Medium |
| **`public`** | Every login is a member; baseline minimal rights | Audit for extra grants (see `hardening-and-auditing.md`) |

**2022+ fixed server roles** add least-privilege building blocks so you needn't grant the heavyweight roles: `##MS_DatabaseConnector##`, `##MS_LoginManager##`, `##MS_DatabaseManager##`, `##MS_ServerStateReader##`, `##MS_ServerPerformanceStateReader##`, `##MS_DefinitionReader##`, `##MS_SecurityDefinitionReader##`, `##MS_ServerStateManager##`. Prefer these over `securityadmin`/`serveradmin` where they fit.

```sql
SELECT r.name AS server_role, m.name AS member
FROM sys.server_role_members rm
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
ORDER BY r.name, m.name;
```

---

## 5. Fixed Database Roles

| Role | Power |
|---|---|
| **`db_owner`** | Full control of the database (incl. drop). App accounts should **never** have it. |
| **`db_securityadmin`** | Manage roles & permissions within the DB |
| **`db_accessadmin`** | Add/remove DB users |
| **`db_ddladmin`** | Run any DDL (create/alter/drop objects) |
| **`db_datareader`** | `SELECT` on all tables/views (all schemas) |
| **`db_datawriter`** | `INSERT`/`UPDATE`/`DELETE` on all tables |
| **`db_denydatareader`** | `DENY SELECT` on all (overrides grants) |
| **`db_denydatawriter`** | `DENY` write on all |
| **`public`** | Every user; keep minimal |

`db_datareader`/`db_datawriter` are convenient but coarse — they cover *every* schema, including future sensitive ones. For real least privilege, prefer **user-defined roles granted at the schema scope** (§6/§9).

```sql
SELECT r.name AS db_role, m.name AS member
FROM sys.database_role_members rm
JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
ORDER BY r.name, m.name;
```

---

## 6. User-Defined Roles

Bundle permissions to manage them once and assign to many principals.

```sql
-- User-defined SERVER role (2012+)
CREATE SERVER ROLE [monitoring];
GRANT VIEW SERVER STATE TO [monitoring];           -- read DMVs, no data access
GRANT VIEW ANY DEFINITION TO [monitoring];
ALTER SERVER ROLE [monitoring] ADD MEMBER [CONTOSO\Monitors];

-- User-defined DATABASE role granted at schema scope
CREATE ROLE [sales_app];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::Sales TO [sales_app];
GRANT EXECUTE ON SCHEMA::Sales TO [sales_app];     -- run procs in the schema
ALTER ROLE [sales_app] ADD MEMBER [app_user];
```

Roles nest (a role can be a member of another role), letting you model hierarchies. Assign **logins/users to roles**, grant **permissions to roles** — never grant directly to individual accounts in production.

---

## 7. Schemas & Ownership; Ownership Chaining

A **schema** is a namespace and a securable; objects have an owner (usually the schema's owner). Two consequences matter for security:

- **Schema-scoped grants** (§6) are the primary least-privilege tool.
- **Ownership chaining**: when object A references object B and **both have the same owner**, SQL Server checks permissions only on A, not B. This is how a view/proc can expose data from a table the caller can't read directly — useful for encapsulation, but a trap if owners drift.

```sql
-- Schemas and their owners
SELECT s.name AS schema_name, p.name AS owner
FROM sys.schemas s JOIN sys.database_principals p ON s.principal_id = p.principal_id
ORDER BY s.name;
```

### Cross-database ownership chaining (CDOC) — high risk

If the **`cross db ownership chaining`** option is ON, chaining extends *across databases*, so an object in DB1 can silently reach data in DB2 based on owner SIDs. A `db_owner` in one DB could then escalate across DBs. **Keep it OFF** (default) and use explicit grants or module signing instead. (See `hardening-and-auditing.md` and `scripts/05`.)

---

## 8. Controlled Privilege Elevation

When code legitimately needs to do more than its caller, **do not** grant the caller the underlying permission. Use one of these, in order of preference:

### Module signing (preferred)
Sign a procedure/function with a certificate, create a principal from that certificate, and grant the elevated permission to **that principal**. The module gains the rights only while executing; callers gain nothing extra; no impersonation context to abuse.

```sql
CREATE CERTIFICATE [sp_cert] WITH SUBJECT = 'elevate sp_purge';
ADD SIGNATURE TO OBJECT::dbo.sp_purge BY CERTIFICATE [sp_cert];
CREATE USER [sp_cert_user] FROM CERTIFICATE [sp_cert];
GRANT DELETE ON SCHEMA::Staging TO [sp_cert_user];  -- the right lives on the cert principal
-- For server-level rights, create a login from the cert in master and grant there.
```

### EXECUTE AS / impersonation
Runs a module (or session) under another principal's context. Simpler but broader, and `IMPERSONATE` is an escalation vector — audit it.

```sql
CREATE PROCEDURE dbo.AdminTask WITH EXECUTE AS OWNER AS BEGIN /* ... */ END;
-- Session-level (revert with REVERT):
-- EXECUTE AS USER = 'limited_user'; SELECT USER_NAME(); REVERT;
```

`EXECUTE AS OWNER` is contained to the DB unless marked trustworthy; avoid setting `TRUSTWORTHY ON` (it lets DB-level impersonation reach the server and is a known escalation path).

---

## 9. `guest`, `public`, and Least-Privilege Recipes

- **`guest`** — a built-in user that lets *any* login without an explicit user access the DB. **Disable it in user databases**: `REVOKE CONNECT FROM guest;` (cannot be dropped). Leave it as-is in `master`/`tempdb`/`msdb`.
- **`public`** — every user/login is implicitly a member. Treat its permission set as the floor everyone gets; audit for accidental grants (a `GRANT ... TO public` exposes the securable to everyone).

**Recipe: read-only reporting user**
```sql
CREATE USER [rpt] FOR LOGIN [rpt];
CREATE ROLE [rpt_read];
GRANT SELECT ON SCHEMA::Reporting TO [rpt_read];
DENY SELECT ON OBJECT::Reporting.PII TO [rpt_read];  -- exception
ALTER ROLE [rpt_read] ADD MEMBER [rpt];
```

**Recipe: application role (schema-scoped) for a 3-tier app**
```sql
CREATE APPLICATION ROLE [appRole] WITH PASSWORD = N'<secret>';
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::App TO [appRole];
-- App connects as a low-priv login, then sp_setapprole 'appRole','<secret>' to assume rights.
```

**Recipe: deployment / DDL role (no data rights)**
```sql
CREATE ROLE [deploy];
GRANT CREATE TABLE, CREATE VIEW, CREATE PROCEDURE TO [deploy];
GRANT ALTER ON SCHEMA::App TO [deploy];
-- Grant db_ddladmin only if broad DDL across all schemas is truly needed.
```

---

## 10. Auditing Effective Permissions

Knowing the *grants* isn't enough — compute the **effective** result (grants minus denies, across roles).

```sql
-- Everything the CURRENT principal can do at a scope
SELECT * FROM sys.fn_my_permissions(NULL, 'SERVER');         -- server scope
SELECT * FROM sys.fn_my_permissions(NULL, 'DATABASE');       -- current DB
SELECT * FROM sys.fn_my_permissions('Sales.Orders','OBJECT');-- a specific object

-- Test a single effective permission (1 = yes) for the current principal
SELECT HAS_PERMS_BY_NAME('Sales.Orders', 'OBJECT', 'SELECT') AS can_select;

-- Check ANOTHER principal's effective permissions: impersonate, test, revert
EXECUTE AS USER = 'app_user';
SELECT * FROM sys.fn_my_permissions('Sales.Orders', 'OBJECT');
REVERT;

-- Raw explicit grants/denies (DB scope)
SELECT pr.name AS principal, p.class_desc, p.permission_name,
       p.state_desc, OBJECT_NAME(p.major_id) AS object_name
FROM sys.database_permissions p
JOIN sys.database_principals pr ON p.grantee_principal_id = pr.principal_id
ORDER BY pr.name, p.permission_name;
```

`scripts/02-permissions-report.sql` reports server- and database-level grants, role membership, and schema ownership, highlighting `CONTROL`/`ALTER`/`IMPERSONATE` and explicit `DENY`.

---

## Authorization Checklist

- [ ] No application account in `sysadmin`, `securityadmin`, or `db_owner`.
- [ ] `securityadmin` membership audited like `sysadmin`.
- [ ] Permissions granted to **roles**, at the **schema** scope, not to individual users on individual objects.
- [ ] `DENY` used only for deliberate carve-outs, documented.
- [ ] `guest` disabled in user databases; `public` carries no extra grants.
- [ ] `cross db ownership chaining` OFF; `TRUSTWORTHY` OFF; module signing used for elevation.
- [ ] `IMPERSONATE` / `EXECUTE AS` / `WITH GRANT OPTION` grants reviewed.
- [ ] Effective permissions validated with `sys.fn_my_permissions` / `HAS_PERMS_BY_NAME`, not assumed.
