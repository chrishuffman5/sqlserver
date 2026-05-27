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
CREATE LOGIN [reporting_app]
WITH PASSWORD = N'<long-random-secret>',
     CHECK_POLICY = ON,        -- enforce Windows password complexity + lockout
     CHECK_EXPIRATION = ON,    -- enforce max-age expiry (turn OFF for service accounts)
     DEFAULT_DATABASE = [ReportDB];
```

- **`CHECK_POLICY`** ties the password to the host Windows password policy (complexity, history, lockout threshold). **Keep ON.** On Linux there is no Windows policy engine, so `CHECK_POLICY` enforces a built-in minimum but not full domain policy.
- **`CHECK_EXPIRATION`** enforces maximum password age. Useful for human accounts; usually **OFF for service/application accounts** that cannot rotate interactively — but then rotate them out of band.
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

For **Azure SQL Database** and **Managed Instance** (and Arc-enabled box product), **Microsoft Entra ID** is the cloud replacement for Windows/AD. It supports MFA, conditional access, and **managed identities** (no secrets to store). Principals are created `FROM EXTERNAL PROVIDER` and appear as type `E` (Entra user/service principal) or `X` (Entra group) in `sys.database_principals` / `sys.server_principals` (MI).

Each logical server / MI has exactly **one Entra administrator** (a user or group) set on the Azure side; that admin then creates contained Entra users in databases.

```sql
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

### 3.2 Entra-only authentication enforcement

You can **disable SQL authentication entirely** so only Entra principals connect — eliminating password-based logins and their rotation burden. Set on the Azure side (Azure portal / CLI / ARM) per server or MI; once enabled, `CREATE LOGIN ... WITH PASSWORD` and connecting as `sa`/SQL logins are blocked. This is a strong hardening control for cloud estates. See `sqlserver-cloud` for the Azure-side configuration.

---

## 4. Certificate & Asymmetric-Key Logins

These authenticate by **possession of a private key**, not a password — and are **not** for interactive users. Two main uses:

1. **Endpoint authentication** — database mirroring, Always On AG, and Service Broker endpoints can authenticate replicas to each other with certificates when Windows auth across the endpoints isn't available (e.g., non-domain or cross-domain). See `sqlserver-ha-clustering`.
2. **Module signing** — sign a stored procedure/function with a certificate, create a login/user *from that certificate*, and grant **that** principal the elevated permission. The module then runs with the certificate's rights **without** granting them to callers and **without** the ownership-chaining / `EXECUTE AS` pitfalls. (Full pattern in `authorization-rbac.md`.)

```sql
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
-- Instance: allow contained databases (run once)
-- EXEC sp_configure 'contained database authentication', 1; RECONFIGURE;

-- Database: make it partially contained
-- ALTER DATABASE [SalesDB] SET CONTAINMENT = PARTIAL;

-- Contained user with its own password (no login in master)
-- CREATE USER [contained_app] WITH PASSWORD = N'<secret>';
-- Contained Windows user
-- CREATE USER [CONTOSO\svc] ;   -- maps to Windows identity, still no server login
```

Key behaviors and **security considerations**:

- **Connection string must set Initial Catalog / Database** to the contained DB. Authentication is attempted **in that database first**; if you omit it, the connection lands in `master` and fails (there is no login there).
- `AUTHENTICATION_TYPE` in `sys.database_principals` distinguishes `DATABASE` (contained password), `WINDOWS`, `EXTERNAL` (Entra), and `INSTANCE` users.
- A `db_owner` of a contained DB can create users with passwords that connect to the *instance* — so granting `db_owner` on a contained DB is closer to granting server access than usual. **Limit `db_owner` and `ALTER ANY USER`** on contained DBs.
- Password-policy enforcement for contained SQL users is weaker than instance logins; rely on the host policy where possible.
- Connecting to a contained DB can be used to enumerate other databases on the instance in some configurations — review the threat model before enabling broadly.

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
| **11 / 12** | Login valid but **server access denied** — usually permission/role/SPN/Kerberos issue (12 = also at connect time) |
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

The most common real-world states: **8** (wrong password), **38** (no access to default DB), **58** (SQL login but server is Windows-only), and **11/12** (Kerberos/SPN or access-denied — cross-check `auth_scheme`).

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
| `E` | EXTERNAL_LOGIN_FROM_AAD | Microsoft Entra ID user or service principal (Azure SQL / MI) |
| `X` | EXTERNAL_GROUPS_FROM_AAD | Microsoft Entra ID **group** (Azure SQL / MI) |
| `R` | SERVER_ROLE | Fixed or user-defined **server role** (a principal, not a login) |

```sql
SELECT name, type, type_desc, is_disabled, create_date, modify_date
FROM sys.server_principals
WHERE type IN ('S','U','G','C','K','E','X')
ORDER BY type, name;
```

(Database-level principals in `sys.database_principals` add `SQL_USER` `S`, `WINDOWS_USER` `U`, `WINDOWS_GROUP` `G`, `DATABASE_ROLE` `R`, `APPLICATION_ROLE` `A`, `EXTERNAL_USER` `E`/`X`, and `CERTIFICATE_MAPPED_USER` `C` — covered in `authorization-rbac.md`.)

---

## Quick Decision Guide

- **Domain-joined box product?** Windows/AD auth with AD groups + Kerberos (verify SPNs). 
- **App can't use AD, or Linux/cross-org?** SQL auth with `CHECK_POLICY = ON`, forced TLS.
- **Azure SQL DB/MI?** Entra ID — managed identity for apps, MFA-interactive for humans, consider Entra-only enforcement.
- **Replica/endpoint or controlled privilege elevation?** Certificate auth / module signing.
- **Portable DB / AG without login sync?** Contained-DB auth — but tighten `db_owner`/`ALTER ANY USER`.
- **Middle-tier "double hop" failing?** Kerberos + **constrained** delegation, correct SPNs, confirm `auth_scheme = KERBEROS`.
