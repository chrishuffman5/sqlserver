# Database Mirroring & Endpoints Reference

This is a **headline topic**. It has two halves:

- **(A) Database Mirroring** — deprecated since SQL Server 2012 but still widespread in the field; you need to operate and migrate it.
- **(B) Endpoints in depth** — the **database-mirroring-type endpoint** is the TCP transport for **BOTH** database mirroring **AND** Always On Availability Groups. Getting endpoints right (especially **certificate-based authentication** for cross-domain/workgroup/Linux replicas) is essential for any AG or mirroring setup.

For AG specifics see `availability-groups.md`; for migrating mirroring → AG and DR planning see `dr-planning.md`.

---

# Part A — Database Mirroring

## A1. What It Is

Database mirroring maintains a **single hot standby copy of one database** by shipping transaction-log records from a **principal** to a **mirror** over a database-mirroring endpoint. It is per-database (not instance, not a group). **Deprecated since SQL Server 2012** — Microsoft recommends Always On AGs (or Basic AG on Standard) instead — but it is still removed-in-some-future-version, present through 2022/2025 builds and very common in legacy estates.

## A2. Roles

| Role | Responsibility |
|---|---|
| **Principal** | The live, read-write copy. Ships log to the mirror. |
| **Mirror** | Continuously restoring the log in `NORECOVERY` (not readable except via a database snapshot). |
| **Witness** (optional) | A lightweight third instance that enables **automatic failover** by forming a quorum with the principal/mirror. Holds no data. |

A mirror is **not directly readable**; you can create a **database snapshot** against the mirror for point-in-time reporting.

## A3. Operating Modes

| Mode | Transaction safety | Witness | Failover | Edition |
|---|---|---|---|---|
| **High Safety with automatic failover** | `FULL` (synchronous) | **Yes** | **Automatic** (principal+witness or mirror+witness form quorum) | Standard+ |
| **High Safety without automatic failover** | `FULL` (synchronous) | No | **Manual** (`ALTER DATABASE … SET PARTNER FAILOVER`) | Standard+ |
| **High Performance** | `OFF` (asynchronous) | No (ignored) | **Forced only** (possible data loss) | **Enterprise** |

- **Synchronous (High Safety)**: principal waits for the mirror to harden the log → zero data loss. Automatic failover requires the **witness** (so a surviving partner + witness = majority).
- **Asynchronous (High Performance)**: principal does not wait → possible data loss; only **forced service** failover (`ALTER DATABASE … SET PARTNER FORCE_SERVICE_ALLOW_DATA_LOSS`).

## A4. Monitoring — `sys.database_mirroring`

```sql
SELECT DB_NAME(database_id)              AS database_name,
       mirroring_state_desc,             -- SYNCHRONIZED / SYNCHRONIZING / SUSPENDED / DISCONNECTED / PENDING_FAILOVER
       mirroring_role_desc,              -- PRINCIPAL / MIRROR
       mirroring_safety_level_desc,      -- FULL (sync) / OFF (async)
       mirroring_partner_name,
       mirroring_partner_instance,
       mirroring_witness_name,
       mirroring_witness_state_desc,     -- CONNECTED / DISCONNECTED / UNKNOWN
       mirroring_failover_lsn,
       mirroring_connection_timeout,
       mirroring_redo_queue
FROM sys.database_mirroring
WHERE mirroring_guid IS NOT NULL;        -- only mirrored databases
```
Send/redo throughput comes from the **`SQLServer:Database Mirroring`** performance object (`sys.dm_os_performance_counters`) — see `scripts/03-mirroring-health.sql`.

## A5. Setup (Windows, sketch)

1. Principal in `FULL` recovery; take a **full + log backup**, restore both on the mirror `WITH NORECOVERY`.
2. Create the **database-mirroring endpoint** on **every** instance (principal, mirror, witness) — Part B.
3. Set partners (each side points at the other's endpoint):
   ```sql
   -- On the MIRROR first:
   ALTER DATABASE [AppDB] SET PARTNER = N'TCP://principal.contoso.com:5022';
   -- On the PRINCIPAL:
   ALTER DATABASE [AppDB] SET PARTNER = N'TCP://mirror.contoso.com:5022';
   -- Optional witness (on the principal), for automatic failover:
   ALTER DATABASE [AppDB] SET WITNESS = N'TCP://witness.contoso.com:5022';
   ```
4. Choose safety: `ALTER DATABASE [AppDB] SET SAFETY FULL;` (sync) or `SET SAFETY OFF;` (async, EE).

### Failover commands (templates — run deliberately)
```sql
-- Planned manual failover (sync, no data loss) — run on the PRINCIPAL:
-- ALTER DATABASE [AppDB] SET PARTNER FAILOVER;

-- Forced failover (async / partner unreachable, POSSIBLE DATA LOSS) — run on the MIRROR:
-- ALTER DATABASE [AppDB] SET PARTNER FORCE_SERVICE_ALLOW_DATA_LOSS;

-- Resume a suspended session:
-- ALTER DATABASE [AppDB] SET PARTNER RESUME;
```

## A6. Migrating Mirroring → Always On AG

1. Validate edition/version supports AGs (or Basic AG on Standard for a single DB).
2. Stand up WSFC (or Pacemaker / `CLUSTER_TYPE = NONE`), enable Always On on each instance.
3. **Reuse the existing database-mirroring endpoint** (same port 5022, same auth) — that's the key continuity point; AGs use the identical endpoint type.
4. Remove mirroring (`ALTER DATABASE … SET PARTNER OFF`), then create the AG and add the database (automatic seeding or restore-with-norecovery).
5. Repoint applications from the mirroring "failover partner" connection-string attribute to the **AG listener**.

---

# Part B — Endpoints In Depth (the HA transport)

The endpoint is the network door log blocks travel through. **One database-mirroring endpoint per instance**, shared by all mirroring sessions and all AGs on that instance. Get auth/encryption/permissions right and most of the AG/mirroring "1418" pain disappears.

## B1. Endpoint Types (focus: DATABASE_MIRRORING)

| Endpoint type / payload | Purpose | Relevance here |
|---|---|---|
| **`DATABASE_MIRRORING`** | Transport for mirroring **and** Always On AGs | **Primary focus** |
| `SERVICE_BROKER` | Service Broker messaging | Mentioned for completeness |
| `TSQL` (default) | Client connections (TDS) | Always present; not HA |
| `SOAP` | Legacy web services (removed in 2012+) | Historical only |

Only **one** `DATABASE_MIRRORING` endpoint may exist per instance. Both mirroring partners/witness and all AG replicas connect through it.

## B2. CREATE ENDPOINT — Full Syntax

```sql
CREATE ENDPOINT [Hadr_endpoint]
    STATE = STARTED                          -- STARTED | STOPPED | DISABLED
    AS TCP (LISTENER_PORT = 5022)            -- the mirroring/AG port (open in firewall)
    FOR DATABASE_MIRRORING (
        ROLE = ALL,                          -- ALL | PARTNER | WITNESS
        AUTHENTICATION = WINDOWS NEGOTIATE,  -- WINDOWS [KERBEROS|NTLM|NEGOTIATE] | CERTIFICATE <cert>
                                             --   | WINDOWS … CERTIFICATE …  (negotiate then fall back)
        ENCRYPTION = REQUIRED ALGORITHM AES  -- REQUIRED | SUPPORTED | DISABLED ; AES | RC4 | AES RC4 | RC4 AES
    );
```

### Option meanings

- **`ROLE`**:
  - `PARTNER` — instance can be a principal or mirror (mirroring) / a replica (AG).
  - `WITNESS` — instance can only act as a mirroring witness.
  - `ALL` — both. **Use `ALL` for AG replicas** and for instances that may also be witnesses. Most AG setups use `ROLE = ALL`.
- **`AUTHENTICATION`**:
  - `WINDOWS [NEGOTIATE|KERBEROS|NTLM]` — uses the SQL Server **service account** as a Windows principal. Requires all replicas to authenticate via AD (same/trusted domains). `NEGOTIATE` tries Kerberos then NTLM. **Kerberos** needs correct **SPNs** on the service account.
  - `CERTIFICATE <cert_name>` — uses X.509 certificates instead of Windows identity. **Required when replicas are in different/untrusted domains, in workgroups, or on Linux** (no AD). See B5.
  - You can combine: `WINDOWS NEGOTIATE CERTIFICATE [c]` (try Windows, fall back to cert) or the reverse.
- **`ENCRYPTION`**: `REQUIRED` (both ends must encrypt — recommended), `SUPPORTED` (encrypt if peer can), `DISABLED`. Algorithm `AES` is the modern choice (RC4 is legacy/deprecated). **Both ends must agree** on the algorithm or the connection fails (a classic 1418 cause).
- **`LISTENER_PORT`** — default **5022**; must be unique per instance on a host and **open in the firewall** between all replicas.

### Altering / starting / stopping
```sql
ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
ALTER ENDPOINT [Hadr_endpoint] FOR DATABASE_MIRRORING (ENCRYPTION = REQUIRED ALGORITHM AES);
-- DROP ENDPOINT [Hadr_endpoint];   -- breaks all AGs/mirroring on the instance — do not run casually
```

## B3. Granting CONNECT on the Endpoint

Each replica/partner must let the **other** replicas' service identity connect to its endpoint:

```sql
-- Windows-auth: grant the partner's SQL Server service account login
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [CONTOSO\SqlSvc];

-- Certificate-auth: grant the login mapped to the partner's certificate (see B5)
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [Login_From_Node2_Cert];
```

If the service accounts differ per node, grant **each** partner account `CONNECT` on the local endpoint. Missing this grant is the most common AG-join / mirroring-1418 failure.

## B4. Windows (Kerberos/NTLM) Authentication

When all replicas share an AD domain (or trusted domains):
- Run the SQL Server services under **domain accounts** (or `gMSA`).
- `AUTHENTICATION = WINDOWS NEGOTIATE` is the simplest.
- For **Kerberos** specifically, register SPNs for the service account on the SQL Server instances (`MSSQLSvc/host:port` and `MSSQLSvc/fqdn:port`) — without correct SPNs, NEGOTIATE silently falls back to NTLM (works for endpoints but can mask delegation issues).
- Grant `CONNECT` to each partner's domain service account (B3).

## B5. Certificate-Based Endpoint Authentication (cross-domain / workgroup / Linux)

Use certificates when there is **no shared AD trust** — different domains, workgroups, or **Linux** replicas. Each instance proves its identity with a certificate; you exchange the **public-key** portion of each instance's cert to every other instance. Do this on **every** replica/partner.

### Step 1 — On EACH instance: create a master key + a local endpoint certificate
```sql
USE master;
-- Database master key (protects the cert's private key). Use a strong, stored secret.
CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'Str0ng!MasterKeyPwd';

-- This instance's identity certificate (private key stays here).
CREATE CERTIFICATE [Node1_Cert]
    WITH SUBJECT = N'Node1 DBM/AG Endpoint Certificate',
         EXPIRY_DATE = N'2035-12-31';

-- Export the PUBLIC key only, to share with the other replicas:
BACKUP CERTIFICATE [Node1_Cert]
    TO FILE = N'/var/opt/mssql/certs/Node1_Cert.cer';   -- (Windows: C:\HADR\Node1_Cert.cer)
```
Repeat on Node2 (`Node2_Cert`), Node3, etc. Each instance keeps its own private key; you only ship the `.cer` (public) files between hosts.

### Step 2 — Create the endpoint using the LOCAL certificate
```sql
CREATE ENDPOINT [Hadr_endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022)
    FOR DATABASE_MIRRORING (
        ROLE = ALL,
        AUTHENTICATION = CERTIFICATE [Node1_Cert],   -- local cert on Node1
        ENCRYPTION = REQUIRED ALGORITHM AES);
```
On Node2 the endpoint uses `AUTHENTICATION = CERTIFICATE [Node2_Cert]`, etc.

### Step 3 — On EACH instance: import the OTHER instances' public certs and map a login
For Node1 to accept Node2, on **Node1** create a login + user, import Node2's public cert under that user, then grant CONNECT:
```sql
-- On NODE1, set up access for NODE2:
CREATE LOGIN [Node2_Login] WITH PASSWORD = N'An0ther!Str0ngPwd';   -- placeholder; never actually used to log in
CREATE USER  [Node2_User]  FOR LOGIN [Node2_Login];

CREATE CERTIFICATE [Node2_Cert]
    AUTHORIZATION [Node2_User]                       -- owned by the mapped user
    FROM FILE = N'/var/opt/mssql/certs/Node2_Cert.cer';   -- Node2's PUBLIC cert, copied here

GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [Node2_Login];
```
Do the symmetric setup on **Node2** for Node1's cert, and for every other replica pair. (For a 3-replica AG, each node imports the other two nodes' public certs and grants CONNECT to each mapped login.)

### Step 4 — Build the AG/mirroring as usual
The `CREATE AVAILABILITY GROUP` / `SET PARTNER` commands are unchanged; the endpoints now authenticate by certificate. This is the standard pattern for **Linux AGs** and **cross-domain DR replicas**.

### Tips
- The mapped login's password is irrelevant to endpoint auth (the cert does the work) — but it must exist.
- Watch **certificate expiry** (`EXPIRY_DATE`); an expired endpoint cert silently breaks the session. Rotate before expiry by creating a new cert, re-exporting/re-importing, and altering the endpoint.
- Back up the **master key** and certificates; losing them means rebuilding endpoints.

## B6. Firewall

Open the endpoint **TCP port (default 5022)** between **all** replicas/partners/witness (bidirectional). On Windows:
```powershell
New-NetFirewallRule -DisplayName "SQL DBM/AG Endpoint 5022" -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow
```
On Linux open 5022 in `firewalld`/`ufw`. The **listener/instance** port (1433) is separate and also needs to be reachable by clients.

## B7. Troubleshooting Endpoint Connectivity

| Symptom | Check |
|---|---|
| AG join / mirroring fails, **error 1418** | Endpoint not started, port blocked, encryption-algorithm mismatch, or missing `CONNECT` grant. The most common single cause. |
| Endpoint exists but DISCONNECTED | `SELECT name, state_desc FROM sys.endpoints;` — must be `STARTED`. `ALTER ENDPOINT … STATE = STARTED;` |
| Encryption mismatch | Compare `encryption_algorithm_desc` across replicas in `sys.database_mirroring_endpoints`. Both ends must match. |
| Wrong auth | `connection_auth_desc` in `sys.database_mirroring_endpoints` (e.g., one side WINDOWS, other CERTIFICATE). |
| Port not listening | `sys.dm_tcp_listener_states` — confirm the DATABASE_MIRRORING listener is `ONLINE` on the expected port. |
| Permission denied | `sys.server_permissions` joined to `sys.server_principals` — confirm each partner login has `CONNECT` on the endpoint. |
| Cert issue (cert auth) | `sys.certificates` — confirm the partner's public cert is imported and owned by the mapped user; check expiry. |

Diagnostic catalog views (used by `scripts/04-endpoints.sql`):
```sql
SELECT e.name, e.type_desc, e.state_desc, e.protocol_desc,
       dme.role_desc, dme.encryption_algorithm_desc, dme.connection_auth_desc,
       te.port, dme.certificate_id
FROM sys.endpoints e
LEFT JOIN sys.database_mirroring_endpoints dme ON e.endpoint_id = dme.endpoint_id
LEFT JOIN sys.tcp_endpoints te ON e.endpoint_id = te.endpoint_id
WHERE e.type_desc = 'DATABASE_MIRRORING';
```
