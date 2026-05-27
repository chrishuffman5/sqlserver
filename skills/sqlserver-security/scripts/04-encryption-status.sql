/*******************************************************************************
 * SQL Server Encryption Status
 *
 * Purpose : Report encryption posture: TDE state per database, certificate
 *           inventory & expiry, Always Encrypted configuration, backup-
 *           encryption usage, and a note on verifying Force Encryption.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box) and Azure SQL MI. On Azure SQL Database TDE
 *           is service-managed; some columns/DMVs differ. Always Encrypted
 *           catalog views require 2016+.
 * Safety  : READ-ONLY. No keys, certificates, or encryption settings changed.
 *
 * Sections:
 *   1. TDE Status Per Database
 *   2. Certificates & Expiry (master + current DB)
 *   3. Always Encrypted Inventory (CMK / CEK / encrypted columns)
 *   4. Backup Encryption Usage (msdb.backupset)
 *   5. Force Encryption (in-transit) - how to verify
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: TDE Status Per Database
  encryption_state: 0 none, 1 unencrypted, 2 in progress, 3 ENCRYPTED,
                    4 key change, 5 decryption in progress, 6 protection change.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME(dek.database_id)                        AS database_name,
    d.is_encrypted                                  AS db_flag_is_encrypted,
    dek.encryption_state,
    dek.encryption_state_desc,
    dek.key_algorithm,
    dek.key_length,
    dek.percent_complete,
    dek.encryptor_type,
    dek.create_date                                 AS dek_create_date,
    dek.regenerate_date                             AS dek_last_regenerated
FROM sys.dm_database_encryption_keys AS dek
JOIN sys.databases AS d ON dek.database_id = d.database_id
ORDER BY DB_NAME(dek.database_id);

-- Databases WITHOUT a DEK (no TDE) for completeness
SELECT name AS database_name, is_encrypted
FROM sys.databases
WHERE database_id NOT IN (SELECT database_id FROM sys.dm_database_encryption_keys)
  AND database_id > 4
ORDER BY name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Certificates & Expiry (run in master and any DB holding keys)
  An expired TDE/backup certificate still decrypts, but expiry is a governance
  signal; ensure every certificate + private key is backed up off-box.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME()                                       AS database_context,
    name                                            AS certificate_name,
    subject,
    start_date,
    expiry_date,
    DATEDIFF(DAY, SYSUTCDATETIME(), expiry_date)    AS days_until_expiry,
    pvt_key_encryption_type_desc                    AS private_key_protection,
    CASE WHEN expiry_date < SYSUTCDATETIME() THEN 'EXPIRED'
         WHEN expiry_date < DATEADD(DAY, 90, SYSUTCDATETIME()) THEN 'Expires < 90 days'
         ELSE 'OK' END                              AS expiry_status,
    thumbprint
FROM sys.certificates
ORDER BY expiry_date;
-- Repeat USE [SomeDB]; before re-running to inspect certificates in other databases.

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Always Encrypted Inventory (2016+)
  Column master keys, column encryption keys, and encrypted columns.
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('sys.column_master_keys') IS NOT NULL
BEGIN
    SELECT name AS column_master_key, key_store_provider_name,
           key_path, create_date
    FROM sys.column_master_keys
    ORDER BY name;

    SELECT name AS column_encryption_key, create_date
    FROM sys.column_encryption_keys
    ORDER BY name;

    -- Encrypted columns with their encryption type and the keys involved
    SELECT
        OBJECT_SCHEMA_NAME(c.object_id)             AS schema_name,
        OBJECT_NAME(c.object_id)                    AS table_name,
        c.name                                      AS column_name,
        c.encryption_type,
        c.encryption_type_desc,                     -- DETERMINISTIC / RANDOMIZED
        cek.name                                    AS column_encryption_key,
        c.encryption_algorithm_name
    FROM sys.columns AS c
    LEFT JOIN sys.column_encryption_keys AS cek
        ON c.column_encryption_key_id = cek.column_encryption_key_id
    WHERE c.encryption_type IS NOT NULL
    ORDER BY schema_name, table_name, column_name;
END
ELSE
    SELECT 'Always Encrypted catalog views not present on this version.' AS info_message;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Backup Encryption Usage (last 90 days)
  key_algorithm / encryptor_type are NULL when the backup is NOT encrypted.
──────────────────────────────────────────────────────────────────────────────*/
IF DB_ID('msdb') IS NOT NULL
BEGIN
    SELECT
        bs.database_name,
        bs.backup_start_date,
        CASE bs.type WHEN 'D' THEN 'Full' WHEN 'I' THEN 'Differential'
                     WHEN 'L' THEN 'Log'  ELSE bs.type END AS backup_type,
        bs.encryptor_type,
        bs.key_algorithm,
        CASE WHEN bs.key_algorithm IS NULL THEN 'NOT ENCRYPTED'
             ELSE 'Encrypted' END                   AS backup_encryption_status,
        bs.compressed_backup_size / 1024.0 / 1024.0 AS size_mb
    FROM msdb.dbo.backupset AS bs
    WHERE bs.backup_start_date >= DATEADD(DAY, -90, SYSUTCDATETIME())
    ORDER BY bs.backup_start_date DESC;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Force Encryption (in-transit) - verification note
  Force Encryption is a SQL Server Configuration Manager / registry setting and
  CANNOT be read directly from T-SQL. Verify by either:
    (a) Per-session check below (encrypt_option = TRUE means the session is TLS),
    (b) Reading the registry ForceEncryption value at the OS level, or
    (c) SQL Server Configuration Manager -> Protocols -> Properties -> Flags.
  For SQL Server 2022+, prefer strict encryption (Encrypt=Strict / TDS 8.0).
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    c.session_id,
    c.encrypt_option                                AS this_session_encrypted,
    c.protocol_type,
    c.auth_scheme
FROM sys.dm_exec_connections AS c
WHERE c.session_id = @@SPID;
