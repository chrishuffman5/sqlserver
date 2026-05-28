# SQL Server Authentication Reference

Authentication answers **"who are you, and can you connect?"** — distinct from authorization ("what may you do?", see `authorization-rbac.md`). SQL Server supports several authentication mechanisms; which are available depends on platform: the **box product** (Windows/Linux/containers) supports Windows/AD, SQL, certificate, and contained-DB auth, while **Azure SQL Database / Managed Instance** replace Windows auth with **Microsoft Entra ID** and add their own constraints.

The instance-level **authentication mode** is either *Windows Authentication only* or *Mixed Mode* (Windows + SQL). Check it without touching the registry:

```sql
-- 1 = Windows Authentication only; 0 = Mixed Mode (Windows + SQL)
SELECT SERVERPROPERTY('IsIntegratedSecurityOnly') AS is_windows_auth_only;
```

Changing the mode requires editing `LoginMode` (registry) and a service restart — covered in `hardening-and-auditing.md`. Azure SQL DB/MI do not expose this toggle.

---

## 1. Windows / Active Directory Authentication

When a domain (or local Windows) account connects with `Integrated Security=SSPI` / `Trusted_Connection=yes`, SQL Server trusts the OS-validated identity. No password crosses to SQL Server; the OS already proved the identity. This is the **preferred** mechanism on the box product because it inherits AD password policy, account lockout, expiration, group management, and (upstream) MFA.

Logins of this kind are stored in `sys.server_principals` as type `U` (Windows user) or `G` (Windows group). **Prefer mapping logins to AD groups, not individual users** — membership is then managed in AD and survives staff changes.

```sql
-- [SECURITY CHANGE] illustrative; use placeholder principals, confirm the target instance.
CREATE LOGIN [CONTOSO\jsmith]          FROM WINDOWS;          -- individual user
CREATE LOGIN [CONTOSO\SQL-DBAs]        FROM WINDOWS;          -- AD group (preferred)
CREATE LOGIN [BUILTIN\Administrators]  FROM WINDOWS;          -- local group (avoid in prod)
```

A user who is a member of a granted **Windows group** authenticates through the group login even with no individual login — `SUSER_SNAME()` returns their account, but the access path is the group. This is invisible in per-login reports, so audit group membership in AD too.

### 1.1 Kerberos vs NTLM — how the protocol is chosen

Windows auth uses one of two protocols, negotiated automatically:

| | **Kerberos** | **NTLM** |
|---|---|---|
| Trigger | A valid **SPN** exists for the SQL service and the client can reach a KDC (domain controller) | No usable SPN, or connecting by IP, or workgroup/cross-untrusted-domain |
| Delegation | Supported (enables the **double hop**) | **Not** supported — credentials cannot be forwarded |
| Mutual auth | Yes (client and server both verified) | Server-to-client only |
| Strength | Stronger, ticket-based | Challenge/response, weaker |

The negotiation is silent: a misconfigured SPN does not error — it **falls back to NTLM**, and the failure only surfaces later as a broken double hop. Verify what was actually used:

```sql
SELECT session_id, net_transport, auth_scheme   -- KERBEROS / NTLM / SQL / DIGEST
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;
```

`auth_scheme = 'KERBEROS'` confirms Kerberos; `'NTLM'` means the SPN/delegation path is not in effect.

### 1.2 Service Principal Names (SPNs)

Kerberos requires a correctly registered SPN that maps the SQL service's network name + port to the **service account** running SQL Server. Format:

```
MSSQLSvc/fqdn:port            (default or named instance reached by port)
MSSQLSvc/fqdn:instancename    (named instance by instance name)
```

Register/inspect with `setspn` (run by a domain admin, or auto-registered if the service account has `Write servicePrincipalName` on itself):

```text
:: List SPNs currently on the service account
setspn -L CONTOSO\sqlsvc

:: Register an SPN (FQDN + port) to the service account
setspn -S MSSQLSvc/sql01.contoso.com:1433 CONTOSO\sqlsvc

:: Find duplicate SPNs across the forest (duplicates BREAK Kerberos -> NTLM fallback)
setspn -X
```

**Duplicate SPNs are the most common Kerberos failure** — if the same SPN is registered on two accounts, the KDC refuses to issue a ticket and you silently drop to NTLM. Check the SQL error log at startup: SQL Server logs whether SPN registration succeeded ("The SQL Server Network Interface library successfully registered the Service Principal Name").

### 1.3 Service accounts: MSA / gMSA

The account SQL Server runs under determines who registers/owns the SPN:

- **Managed Service Account (MSA)** — domain-managed password, single server.
- **Group Managed Service Account (gMSA)** — domain-managed password, usable across multiple servers (ideal for FCI/AG nodes). The account auto-registers its own SPN and auto-rotates its password. **Strongly preferred** for production.
- **Virtual account / NT SERVICE\\MSSQLSERVER** — local, simple, but cannot delegate across machines and registers SPNs under the *computer* account.

gMSA setup (high level — OS side): create the gMSA with `New-ADServiceAccount -KdsRootKeyId ... -PrincipalsAllowedToRetrieveManagedPassword`, install it on each node, then set it as the SQL service account in SQL Server Configuration Manager (never via services.msc, which won't grant the right permissions).

### 1.4 The double-hop problem & constrained delegation

The **double hop**: a user connects to a middle tier (IIS/SSRS/a linked-server hop), which then connects to SQL Server **as the user**. NTLM cannot forward the user's credential past the first hop, so the second hop arrives as anonymous and fails (classic `Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'`). Solving it requires **Kerberos + delegation**:

- **Unconstrained delegation** — the middle tier can impersonate the user to *any* service. Powerful and **dangerous**; avoid.
- **Constrained delegation (KCD)** — the middle tier may delegate only to specific listed services (e.g., just `MSSQLSvc/sql01.contoso.com:1433`). The supported, least-privilege choice.
- **Resource-based constrained delegation (RBCD)** — the *target* (SQL) controls who may delegate to it; works across domains and avoids needing domain-admin rights on the front-end account.

Prerequisites for any KCD: valid SPNs on both the middle-tier service and SQL Server, the middle-tier account marked "Trust this user for delegation to specified services," and Kerberos actually in use end-to-end. Confirm each hop's `auth_scheme` is `KERBEROS`.

---

## 2. SQL Authentication

A **SQL login** stores a name and a salted-hashed password in `master` (type `S` in `sys.server_principals`). Required when AD is unavailable (workgroup servers, many Linux deployments, cross-org apps). It must be enabled at the instance level (Mixed Mode).

```sql
-- [SECURITY CHANGE] illustrative; use placeholder names, confirm the target instance.
-- (a) HUMAN / interactive login: enforce policy AND expiration.
CREATE LOGIN [a_person]
WITH PASSWORD = N'<generate-32+char-random-secret>',
     CHECK_POLICY = ON,        -- enforce host password complexity + lockout
     CHECK_EXPIRATION = ON,    -- enforce max-age expiry (humans can rotate interactively)
     DEFAULT_DATABASE = [AppDB];

-- (b) SERVICE / application login: enforce policy, but expiration OFF (no interactive rotation)
--     -> rotate the secret OUT OF BAND on a schedule. Prefer Windows/Entra/managed identity
--        for services where the platform allows it.
CREATE LOGIN [reporting_app]
WITH PASSWORD = N'<generate-32+char-random-secret>',
     CHECK_POLICY = ON,
     CHECK_EXPIRATION = OFF,
     DEFAULT_DATABASE = [ReportDB];
-- Source secrets from a secret manager; never commit them; avoid T-SQL/shell history exposure;
-- rotate any value ever pasted from documentation.
```

- **`CHECK_POLICY`** ties the password to the host **Windows** password policy (complexity, history, lockout threshold) via the OS. **Keep ON.** On **Linux** there is no Windows policy engine, so complexity enforcement is **limited and version-dependent** — recent builds enforce a basic built-in minimum (length/complexity) but not full domain policy, and historically `CHECK_POLICY` enforcement on Linux was partial. Don't assume Windows-equivalent policy on Linux; supplement with external controls.
- **`CHECK_EXPIRATION`** enforces maximum password age. Useful for **human** accounts that can rotate interactively; usually **OFF for service/application accounts** — but then **rotate them out of band** on a schedule.
- Passwords are stored as a salted hash (`sys.sql_logins.password_hash`); the algorithm strengthened over versions (SHA-512 since 2012). Never reversible.
- The login handshake is always encrypted by SQL Server even without a configured certificate, but **force TLS for the whole session** (see `encryption.md`) so the rest of the traffic is protected too.

Audit weak/misconfigured SQL logins:

```sql
SELECT name, is_disabled, is_policy_checked, is_expiration_checked,
       LOGINPROPERTY(name, 'PasswordLastSetTime') AS pwd_last_set
FROM sys.sql_logins
WHERE (is_policy_checked = 0 OR is_expiration_checked = 0) AND is_disabled = 0;

-- Probe for a blank/known-weak password (optional, intrusive-ish; PWDCOMPARE is read-only)
-- SELECT name FROM sys.sql_logins WHERE PWDCOMPARE('', password_hash) = 1;  -- blank password
```

**When Mixed Mode is genuinely required:** third-party apps hard-coded to SQL auth, non-domain-joined hosts, cross-platform/Linux clients, and most cloud apps. Otherwise prefer Windows/Entra auth.

---

## 3. Microsoft Entra ID (Azure AD) Authentication

For **Azure SQL Database** and **Managed Instance** (and Arc-enabled box product), **Microsoft Entra ID** is the cloud replacement for Windows/AD. It supports MFA, conditional access, and **managed identities** (no secrets to store). Principals are created `FROM EXTERNAL PROVIDER` and carry type `E` (external user/login) or `X` (external group). The exact `type_desc` differs by catalog view and platform: in **`sys.database_principals`** (contained users — Azure SQL DB and MI) `E` = `EXTERNAL_USER` and `X` = `EXTERNAL_GROUPS`; in **`sys.server_principals`** (server logins — MI, and in preview for Azure SQL DB) `E` = `EXTERNAL_LOGIN` and `X` = `EXTERNAL_GROUP`. (`authentication_type_desc = 'EXTERNAL'` marks Entra authentication.) Verify the strings for your platform on Microsoft Learn.

Each logical server / MI has exactly **one Entra administrator** (a user or group) set on the Azure side; that admin then creates contained Entra users in databases.

```sql
-- [SECURITY CHANGE] illustrative; use placeholder identities, confirm the target DB via DB_NAME().
-- Azure SQL DB: create contained users mapped to Entra identities (run in the user DB)
CREATE USER [alice@contoso.com]              FROM EXTERNAL PROVIDER;  -- Entra user
CREATE USER [SQL-App-Writers]                FROM EXTERNAL PROVIDER;  -- Entra group
CREATE USER [my-webapp]                      FROM EXTERNAL PROVIDER;  -- managed identity / app
ALTER ROLE db_datareader ADD MEMBER [SQL-App-Writers];
```

### 3.1 Entra connection / authentication variants

| Variant | How it works | Use for |
|---|---|---|
| **Entra Integrated** | Uses the signed-in Windows/SSO session silently | Domain-joined / Entra-joined client workstations |
| **Entra Password** | Entra username + password | Scripts where SSO isn't available (weaker; avoid for MFA-required tenants) |
| **Entra Universal / Interactive with MFA** | Browser/device-code prompt, supports MFA & conditional access | Interactive admin/user sessions |
| **Entra Managed Identity** | The Azure resource's system- or user-assigned identity — **no secret** | App Service / Functions / VMs calling SQL. Best practice. |
| **Entra Service Principal** | App registration with client ID + secret/certificate | Automation, CI/CD, non-Azure compute |

Connection-string hints: `Authentication=Active Directory Integrated|Password|Interactive|Managed Identity|Service Principal`. Managed identity and service principal are the right choices for unattended app-to-DB auth — they avoid embedding SQL passwords.

**Managed identity guidance (preferred for Azure-hosted apps):**
- **System-assigned** identity is tied to the lifecycle of one Azure resource (deleted with it) — simplest for a single app. **User-assigned** identity is a standalone resource you can share across several apps/resources and manage centrally — better for fleets and blue/green deployments. Create the DB user `FROM EXTERNAL PROVIDER` against the identity's name (system-assigned uses the resource name; user-assigned uses the identity's name and you must specify its client ID when there are multiple).
- Modern drivers expose **`Authentication=Active Directory Default`** (the "DefaultAzureCredential" chain), which transparently tries managed identity, then Azure CLI / environment / interactive — letting the same code run unchanged from a dev box and in Azure. Prefer it over hard-wiring `Managed Identity` where portability matters.
- Entra **tokens are cached** by the driver and are short-lived (typically ~1 hour) and auto-refreshed; design retry/connection logic to tolerate a refresh, and don't cache a token longer than its lifetime. Azure-side specifics are in `sqlserver-cloud`.

### 3.2 Entra-only authentication enforcement

You can **disable SQL authentication entirely** so only Entra principals connect — eliminating password-based logins and their rotation burden. Set on the Azure side (Azure portal / CLI / ARM) per server or MI; once enabled, `CREATE LOGIN ... WITH PASSWORD` and connecting as `sa`/SQL logins are blocked. This is a strong hardening control for cloud estates. See `sqlserver-cloud` for the Azure-side configuration.

---

## 4. Certificate & Asymmetric-Key Logins

These authenticate by **possession of a private key**, not a password — and are **not** for interactive users. Two main uses:

1. **Endpoint authentication** — database mirroring, Always On AG, and Service Broker endpoints can authenticate replicas to each other with certificates when Windows auth across the endpoints isn't available (e.g., non-domain or cross-domain). See `sqlserver-ha-clustering`.
2. **Module signing** — sign a stored procedure/function with a certificate, create a login/user *from that certificate*, and grant **that** principal the elevated permission. The module then runs with the certificate's rights **without** granting them to callers and **without** the ownership-chaining / `EXECUTE AS` pitfalls. (Full pattern in `authorization-rbac.md`.)

```sql
-- [SECURITY CHANGE] illustrative; confirm the target instance, back up any certificate + private key on creation.
-- Certificate-mapped login (e.g., for an endpoint or signed module), type 'C'
CREATE CERTIFICATE [EndpointCert] WITH SUBJECT = 'AG endpoint auth';
CREATE LOGIN [EndpointLogin] FROM CERTIFICATE [EndpointCert];

-- Asymmetric-key-mapped login, type 'K'
-- CREATE LOGIN [AsymLogin] FROM ASYMMETRIC KEY [MyAsymKey];
```

---

## 5. Contained-Database Authentication

A **contained database** authenticates users **inside the user database** with no corresponding server login — the credential (SQL password, or a Windows/Entra identity) lives in the DB itself. This makes the database **portable**: moving or failing it over (AG) carries its users along, eliminating orphaned-user remapping.

Enable at the instance, then at the database:

```sql
-- [CONFIG CHANGE] + [SECURITY CHANGE] templates; confirm the target instance/DB before running.
-- Instance: allow contained databases (run once)
-- EXEC sp_configure 'contained database authentication', 1; RECONFIGURE;

-- Database: make it partially contained
-- ALTER DATABASE [MyDB] SET CONTAINMENT = PARTIAL;

-- Contained user with its own password (no login in master)
-- CREATE USER [contained_app] WITH PASSWORD = N'<generate-32+char-random-secret>';  -- source from a secret manager
-- Contained Windows user
-- CREATE USER [CONTOSO\svc] ;   -- maps to Windows identity, still no server login
```

Key behaviors and **security considerations**:

- **Connection string must set Initial Catalog / Database** to the contained DB. Authentication is attempted **in that database first**; if you omit it, the connection lands in `master` and fails (there is no login there).
- `AUTHENTICATION_TYPE` in `sys.database_principals` distinguishes `DATABASE` (contained password), `WINDOWS`, `EXTERNAL` (Entra), and `INSTANCE` users.
- A `db_owner` of a contained DB can create users with passwords that connect to the *instance* — so granting `db_owner` on a contained DB is closer to granting server access than usual. **Limit `db_owner` and `ALTER ANY USER`** on contained DBs.
- Password-policy enforcement for contained SQL users is weaker than instance logins; rely on the host policy where possible.
- Connecting to a contained DB can be used to enumerate other databases on the instance in some configurations — review the threat model before enabling broadly.

### 5.1 Orphaned users & the login-reconciliation playbook (AG / restore / migration)

A database user mapped to a **SQL login by SID** breaks when the database moves to an instance where that login is absent or has a different SID — the classic **orphaned user** (detected in `scripts/01-security-audit.sql`). Windows/Entra users orphan when the underlying AD/Entra identity changes. This bites after a restore to a new server, an AG failover to a replica missing the login, or a migration. The playbook:

1. **Pre-stage logins on every target/replica before they're needed.** Script the source logins with their **SIDs and hashed passwords** so the recreated SQL login keeps the same SID and password (use `sp_help_revlogin` / a scripted `CREATE LOGIN ... WITH PASSWORD = 0x... HASHED, SID = 0x...`). Matching SIDs means the existing DB users map automatically — no remap needed. Keep this in source control and run it as part of AG seeding and DR runbooks.
2. **Remap an already-orphaned user** to the correct login:
   ```sql
   -- [SECURITY CHANGE] illustrative; confirm DB via DB_NAME(), use placeholder names.
   ALTER USER [app_user] WITH LOGIN = [app_user];   -- re-point a user to its (same-named) login
   ```
   `ALTER USER ... WITH LOGIN` is the supported remap. The old `sp_change_users_login` is **deprecated** — don't use it for new work.
3. **Or avoid the problem entirely** with **contained databases** (§5), whose users travel with the DB and never orphan on failover.

---

## 6. Login Failure (Error 18456) — State-Code Cheat Sheet

A failed login returns generic **error 18456** to the client (to avoid leaking detail to attackers), but the SQL **error log** records a precise **state** code. Extract and decode it (`scripts/03-login-audit.sql` automates this):

| State | Meaning |
|---|---|
| **2 / 5** | User ID not valid / login does not exist |
| **6** | Attempted Windows login with a SQL login name (or vice versa mismatch) |
| **7** | Login disabled **and** password mismatch |
| **8** | Password mismatch (correct user, wrong password) |
| **9** | Password is not valid (e.g., expired-style condition) |
| **11 / 12** | Login is **valid but denied server access** — typically a valid login that can't get in: UAC token filtering for a local Windows admin (the elevated token isn't presented), a `DENY CONNECT`/disabled login, or missing `CONNECT SQL`. Not primarily an SPN/Kerberos symptom (cross-check `auth_scheme` only to rule those out). 12 = the same, evaluated at connection time |
| **13** | SQL Server service is paused |
| **18** | Password **expired** / must be changed (`CHECK_EXPIRATION`) |
| **38 / 40** | Login valid but the **default/target database** is unavailable or login lacks access to it |
| **58** | SQL login used while server is in **Windows-only** mode (Mixed Mode not enabled) |
| **102-104** | Entra ID / Azure AD authentication failures (token/conditional-access) |

```sql
-- Read the error log for 18456 events (also see scripts/03)
-- EXEC sp_readerrorlog 0, 1, N'18456';
-- EXEC xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, NULL, N'desc';
```

The most common real-world states: **8** (wrong password), **38** (no access to default DB), **58** (SQL login but server is Windows-only), and **11/12** (valid login denied server access — most often UAC token filtering for a local admin, a denied/disabled login, or missing `CONNECT SQL`; cross-check `auth_scheme` only to rule out a Kerberos/SPN edge case).

---

## 7. `sys.server_principals` Type Codes

Every server principal carries a one-letter `type` (and matching `type_desc`):

| `type` | `type_desc` | What it is |
|---|---|---|
| `S` | SQL_LOGIN | SQL authentication login (password in `master`) |
| `U` | WINDOWS_LOGIN | Windows/AD **user** login |
| `G` | WINDOWS_GROUP | Windows/AD **group** login |
| `C` | CERTIFICATE_MAPPED_LOGIN | Login mapped to a certificate (endpoints / module signing) |
| `K` | ASYMMETRIC_KEY_MAPPED_LOGIN | Login mapped to an asymmetric key |
| `E` | EXTERNAL_LOGIN | Microsoft Entra ID user/login or service principal (MI; in preview for Azure SQL DB at server scope) |
| `X` | EXTERNAL_GROUP | Microsoft Entra ID **group** (MI; in preview for Azure SQL DB at server scope) |
| `R` | SERVER_ROLE | Fixed or user-defined **server role** (a principal, not a login) |

```sql
SELECT name, type, type_desc, is_disabled, create_date, modify_date
FROM sys.server_principals
WHERE type IN ('S','U','G','C','K','E','X')
ORDER BY type, name;
```

(Database-level principals in `sys.database_principals` add `SQL_USER` `S`, `WINDOWS_USER` `U`, `WINDOWS_GROUP` `G`, `DATABASE_ROLE` `R`, `APPLICATION_ROLE` `A`, `EXTERNAL_USER` `E`, `EXTERNAL_GROUPS` `X`, and `CERTIFICATE_MAPPED_USER` `C` — note the `type_desc` strings differ from the server-level view above; covered in `authorization-rbac.md`.)

---

## Quick Decision Guide

- **Domain-joined box product?** Windows/AD auth with AD groups + Kerberos (verify SPNs). 
- **App can't use AD, or Linux/cross-org?** SQL auth with `CHECK_POLICY = ON`, forced TLS.
- **Azure SQL DB/MI?** Entra ID — managed identity for apps, MFA-interactive for humans, consider Entra-only enforcement.
- **Replica/endpoint or controlled privilege elevation?** Certificate auth / module signing.
- **Portable DB / AG without login sync?** Contained-DB auth — but tighten `db_owner`/`ALTER ANY USER`.
- **Middle-tier "double hop" failing?** Kerberos + **constrained** delegation, correct SPNs, confirm `auth_scheme = KERBEROS`.
