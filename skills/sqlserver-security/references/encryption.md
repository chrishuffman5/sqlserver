# SQL Server Encryption Reference

Encryption protects the **bytes** of your data in three places: **at rest** (the files and backups — TDE, cell-level), **in the column even from the DBA** (Always Encrypted), and **on the wire** (TLS). None of these replace authentication or authorization; they are the third defense layer. The unifying concept is the **encryption key hierarchy** — get that wrong (especially key/certificate backup) and you lose data permanently.

---

## 1. The Key Hierarchy

Each level protects (encrypts) the level below it:

```
  Windows DPAPI  /  Azure Key Vault (EKM)         <- root of trust
        │
   SERVICE MASTER KEY (SMK)                        instance-wide, in master, auto-created
        │   (protects the DMK and instance-level secrets)
        ▼
   DATABASE MASTER KEY (DMK)                       per database, protected by a password AND/OR the SMK
        │   (protects certificates & asymmetric keys in that DB)
        ▼
   CERTIFICATES  /  ASYMMETRIC KEYS                e.g., the TDE certificate, backup-encryption cert
        │   (protect symmetric keys)
        ▼
   SYMMETRIC KEYS                                  the keys that actually encrypt data (DEK, cell keys)
```

- **Service Master Key (SMK)** — created automatically on first startup, encrypted by the Windows Data Protection API (DPAPI) using the service account + machine credentials. **Back it up** (`BACKUP SERVICE MASTER KEY ...`) — needed for disaster recovery and for moving encrypted DBs.
- **Database Master Key (DMK)** — created per database with `CREATE MASTER KEY ENCRYPTION BY PASSWORD`; by default also encrypted by the SMK so it opens automatically. **Back it up** too.
- **Certificates / asymmetric keys** protect symmetric keys; the **TDE certificate** in particular must be backed up *with its private key*.

```sql
BACKUP SERVICE MASTER KEY TO FILE = N'...smk.bak'
    ENCRYPTION BY PASSWORD = N'<secret>';
BACKUP MASTER KEY TO FILE = N'...dmk.bak'
    ENCRYPTION BY PASSWORD = N'<secret>';
```

---

## 2. Transparent Data Encryption (TDE)

**TDE encrypts data at rest** — the `.mdf`/`.ndf`/`.ldf` files and every backup — transparently to applications. It defeats the "someone stole the drive / the backup file" threat. It does **not** protect against an authorized user querying the data, nor data in memory, nor data on the wire.

**Availability:** Enterprise (and Developer) historically; **all editions from SQL Server 2019**. On **Azure SQL DB/MI** TDE is **on by default** with a service-managed key (or bring-your-own AKV key).

**How it works:** a per-database symmetric **Database Encryption Key (DEK)** encrypts the data pages; the DEK is protected by a **certificate** (or asymmetric key) in `master`. Encryption/decryption happens at the page-I/O layer.

### Setup (box product)
```sql
-- 1. Master key + certificate in MASTER
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'<strong>';
CREATE CERTIFICATE TDECert WITH SUBJECT = 'TDE Certificate';

-- 2. >>> BACK UP THE CERTIFICATE + PRIVATE KEY IMMEDIATELY <<<  (CRITICAL)
BACKUP CERTIFICATE TDECert
    TO FILE = N'C:\keys\TDECert.cer'
    WITH PRIVATE KEY (FILE = N'C:\keys\TDECert.pvk',
                      ENCRYPTION BY PASSWORD = N'<different-strong>');

-- 3. DEK in the user database, protected by the certificate
USE MyDB;
CREATE DATABASE ENCRYPTION KEY
    WITH ALGORITHM = AES_256
    ENCRYPTION BY SERVER CERTIFICATE TDECert;

-- 4. Turn it on
ALTER DATABASE MyDB SET ENCRYPTION ON;
```

### Critical facts
- **Certificate backup is non-negotiable.** Without the certificate + private key you cannot restore the database or its backups on another server — the data is gone. Back it up the moment you create it, store it separately from the data backups.
- **tempdb gets encrypted** as soon as *any* database on the instance uses TDE (shared resource). This adds a small overhead even to non-TDE databases.
- **Performance:** roughly **3-5% CPU**. Mostly affects scans and cold reads.
- **Backup compression interaction:** encrypted data compresses poorly. Historically TDE + `COMPRESSION` gave little benefit; **2016+** improved this (with `MAXTRANSFERSIZE` ≥ 65537 the engine compresses then encrypts). Expect smaller gains than on unencrypted DBs.
- **Key rotation:** rotate the DEK (`ALTER DATABASE ENCRYPTION KEY ... REGENERATE`) and/or re-protect it with a new certificate periodically; re-back-up the new certificate.
- **EKM / Azure Key Vault as protector:** with the SQL Server Connector for Azure Key Vault (Extensible Key Management), the TDE protector can live in **AKV/HSM** instead of a local certificate — centralizing key custody and rotation. This is the standard pattern in cloud/regulated environments.

### Monitor (read-only)
```sql
SELECT DB_NAME(database_id) AS db, encryption_state, encryption_state_desc,
       key_algorithm, key_length, percent_complete
FROM sys.dm_database_encryption_keys;   -- state 3 = ENCRYPTED, 2 = in progress
```

---

## 3. Always Encrypted

**Always Encrypted (AE)** encrypts specific **columns on the client side**, so the data is never in plaintext on the server — defeating the **DBA / cloud-operator / instance-compromise** threat that TDE does not. **2016+**; **secure enclaves 2019+**.

**Two keys, both client-controlled:**
- **Column Master Key (CMK)** — a wrapping key in a **trusted store the server cannot read**: Windows Certificate Store, Azure Key Vault, or a hardware HSM. The server only stores metadata pointing to it.
- **Column Encryption Key (CEK)** — encrypts the column data; the CEK is itself encrypted by the CMK and stored (encrypted) in the database.

The **client driver** (e.g., .NET `Column Encryption Setting=Enabled`, or ODBC/JDBC equivalents) transparently encrypts parameters on writes and decrypts results on reads. The server only ever sees ciphertext.

### Deterministic vs Randomized
| | **Deterministic** | **Randomized** |
|---|---|---|
| Same plaintext -> | same ciphertext | different ciphertext each time |
| Equality lookups / joins / grouping / equality-PK | **Yes** | No |
| Range, `LIKE`, ordering, arithmetic | No (unless enclave) | No (unless enclave) |
| Leakage | Patterns/frequency observable | None |

Use **deterministic** only where equality search is required and the leakage is acceptable; **randomized** otherwise.

### What queries break
- No server-side computation on encrypted columns (no `WHERE col > x`, `LIKE`, functions, implicit casts).
- **Parameterization is required** — the driver can only encrypt *parameters*, not inline literals. `WHERE ssn = '123'` fails; `WHERE ssn = @ssn` works.
- Joining/comparing two encrypted columns requires the **same CEK and same encryption type**.
- Bulk/ETL tooling must be AE-aware.

### Secure enclaves (2019+)
A **secure enclave** is a protected memory region inside the engine the driver can trust (via **attestation**, historically Host Guardian Service; **2022+** supports Microsoft Azure Attestation and VBS enclaves). With enclaves you gain:
- **Rich computations** on encrypted columns — `LIKE`, range comparisons — even on **randomized** columns.
- **In-place encryption / key rotation** without moving data out to the client.

Enable per CMK with `ENCLAVE_COMPUTATIONS (SIGNATURE = ...)` and configure the instance's attestation. The driver still controls keys; the enclave just lets it delegate computation securely.

```sql
-- Inventory AE configuration (read-only)
SELECT name, key_store_provider_name FROM sys.column_master_keys;
SELECT c.name AS cek FROM sys.column_encryption_keys c;
SELECT t.name AS tbl, col.name AS col, col.encryption_type_desc
FROM sys.columns col JOIN sys.tables t ON col.object_id = t.object_id
WHERE col.encryption_type IS NOT NULL;
```

**TDE vs Always Encrypted:** TDE protects files at rest and is transparent but the DBA can read data; AE hides data from the DBA but constrains queries. They are complementary — many regulated systems use both.

---

## 4. TLS / Encryption in Transit

Protects data on the network from sniffing and MITM. Two halves: the **server** must present a certificate, and the **client** must request/validate encryption.

- **Force Encryption** (SQL Server Configuration Manager -> Protocols -> Properties) makes the server require TLS for *all* connections, using a certificate bound to the service. The certificate's **subject/SAN must match the name clients connect by**, must be trusted by clients, and the service account needs read access to its private key. (OS-side placement: see `sqlserver-infrastructure`.)
- Even without a configured cert, SQL Server uses a **self-signed certificate to encrypt the login packet** — but not necessarily the whole session. Deploy a real, trusted certificate for full-session, validated encryption.

**Client connection options:**
| Setting | Behavior |
|---|---|
| `Encrypt=false` (legacy default) | Encrypt login only, session plaintext unless server forces |
| `Encrypt=true` / `yes` | Encrypt the session; **validates** the server certificate |
| `TrustServerCertificate=true` | Encrypt but **skip validation** — vulnerable to MITM. Use only with a known/self-signed cert in dev. |
| **`Encrypt=Strict` (TDS 8.0, 2022+)** | Mandatory TLS 1.2+ negotiated *before* the TDS handshake, full validation, no downgrade. The strongest option. |

**Strict encryption / TDS 8.0 (2022+):** wraps the entire TDS conversation in TLS from the first byte (like HTTPS), eliminating the pre-login plaintext window and supporting modern cipher governance. Prefer `Encrypt=Strict` for new deployments and anything internet-exposed. Newer drivers (recent .NET/ODBC/JDBC/Go) default `Encrypt=true`, so plan certificates accordingly.

```sql
-- Confirm the current session is actually encrypted (read-only)
SELECT session_id, encrypt_option, auth_scheme, net_transport
FROM sys.dm_exec_connections WHERE session_id = @@SPID;
```

Force Encryption itself is a **registry/Configuration-Manager** setting and cannot be read directly from T-SQL — verify per-session with the query above and check the certificate at the OS level (`scripts/04` notes this).

---

## 5. Backup Encryption

Encrypts the **backup file** itself, independent of TDE (useful when the DB isn't TDE-encrypted but the backups leave the building). **2014+, all editions.**

```sql
-- Requires a certificate or asymmetric key in master (back it up too!)
BACKUP DATABASE MyDB TO DISK = N'...MyDB.bak'
WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = BackupCert),
     COMPRESSION, CHECKSUM, INIT;
```

- Supported algorithms: AES_128/192/256 and (deprecated) TRIPLE_DES_3KEY. Use **AES_256**.
- The certificate/key used to encrypt must be backed up and available to **restore** — same hard rule as TDE.
- If the DB is **already TDE-encrypted**, its backups are encrypted via the DEK; explicit backup encryption is then redundant (and you still need the TDE cert to restore).

Audit what's been encrypted (read-only):
```sql
SELECT database_name, backup_start_date, type,
       encryptor_type, key_algorithm
FROM msdb.dbo.backupset
WHERE key_algorithm IS NOT NULL OR encryptor_type IS NOT NULL
ORDER BY backup_start_date DESC;
```

---

## 6. Cell-Level / Column Encryption

The original, manual approach: encrypt individual values with **`ENCRYPTBYKEY` / `DECRYPTBYKEY`** (or `...BYCERT`/`...BYPASSPHRASE`) using a symmetric key opened in the session. Server-side keys, so unlike Always Encrypted the **engine can see plaintext** when the key is open.

```sql
CREATE SYMMETRIC KEY CardKey WITH ALGORITHM = AES_256
    ENCRYPTION BY CERTIFICATE DataCert;

OPEN SYMMETRIC KEY CardKey DECRYPTION BY CERTIFICATE DataCert;
UPDATE dbo.Cards SET card_enc = ENCRYPTBYKEY(KEY_GUID('CardKey'), card_number);
SELECT CONVERT(varchar(20), DECRYPTBYKEY(card_enc)) FROM dbo.Cards;
CLOSE SYMMETRIC KEY CardKey;
```

- Stores ciphertext in `varbinary` columns; **breaks SARGability** (no index seeks on encrypted values) and requires explicit `OPEN`/`CLOSE` and app changes.
- **Prefer Always Encrypted** when you need true client-side secrecy from the DBA. Use cell-level encryption only for legacy/back-compat or when keys must stay server-side under DBA control.

---

## 7. Certificate Lifecycle & Expiry

Certificates have an `expiry_date`. An **expired TDE/backup certificate still decrypts existing data** (SQL Server does not enforce expiry for these internal uses) — but expiry is a governance signal, and expired endpoint/connection certificates *will* cause failures. Track them:

```sql
SELECT name, subject, start_date, expiry_date,
       pvt_key_encryption_type_desc, thumbprint
FROM sys.certificates
ORDER BY expiry_date;
```

Lifecycle hygiene:
- **Back up every certificate + private key** at creation and after any change/rotation; store off-box.
- **Rotate** TDE certificates periodically; the DEK can be re-encrypted by a new certificate without re-encrypting all data (`ALTER DATABASE ENCRYPTION KEY ... ENCRYPTION BY SERVER CERTIFICATE NewCert`).
- Keep **old certificates** until every backup that depends on them has aged out of retention — a restore needs the certificate that was current when that backup was taken.
- In cloud/regulated estates, prefer **Azure Key Vault** (TDE protector / AE CMK) for centralized custody, audit, and rotation.

`scripts/04-encryption-status.sql` reports TDE state, certificate expiry, Always Encrypted inventory, and backup-encryption usage.

---

## Choosing an Encryption Feature

| Threat | Feature |
|---|---|
| Stolen data/backup files | **TDE** (+ **backup encryption** if DB isn't TDE) |
| Untrusted DBA / cloud operator / memory scraping | **Always Encrypted** (enclaves for richer queries) |
| Network sniffing / MITM | **TLS** (`Encrypt=Strict` / TDS 8.0 on 2022+) |
| A few sensitive columns, server-side keys acceptable | **Cell-level encryption** (or AE) |

Combine layers: TDE for at-rest + TLS for in-transit is the baseline; add Always Encrypted for the most sensitive columns.
