/*******************************************************************************
 * Database-Mirroring Endpoints — Inventory & Connectivity
 *
 * Purpose : Inspect the DATABASE_MIRRORING endpoint(s) that transport BOTH
 *           database mirroring AND Always On AG traffic: type/state/role,
 *           encryption algorithm, authentication mode, listener port, the
 *           CONNECT permissions granted on the endpoint, the TCP listener
 *           state, and any certificate used for endpoint authentication.
 * Version : SQL Server 2016+ (build 13.x+). Windows & Linux.
 * Safety  : READ-ONLY. No endpoint, permission, or certificate changes.
 *
 * Sections:
 *   1. All Endpoints (overview) + DATABASE_MIRRORING detail
 *   2. CONNECT Permissions on Endpoints (who may connect)
 *   3. TCP Listener State for the Endpoint Port
 *   4. Certificate-Based Endpoint Authentication (cert + owner)
 *   5. Setup Templates (COMMENTED — for reference only)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: All endpoints overview, then DATABASE_MIRRORING detail.
  sys.database_mirroring_endpoints carries role/encryption/auth; the TCP port
  comes from sys.tcp_endpoints.
──────────────────────────────────────────────────────────────────────────────*/
-- 1a. Overview of all non-system endpoints
SELECT
    e.name                                      AS endpoint_name,
    e.endpoint_id,
    e.type_desc                                 AS endpoint_type,    -- TSQL / DATABASE_MIRRORING / SERVICE_BROKER / SOAP
    e.state_desc                                AS endpoint_state,   -- STARTED / STOPPED / DISABLED
    e.protocol_desc                             AS protocol,
    SUSER_NAME(e.principal_id)                  AS owner
FROM sys.endpoints AS e
WHERE e.endpoint_id > 65535          -- exclude built-in system endpoints
ORDER BY e.type_desc, e.name;

-- 1b. DATABASE_MIRRORING endpoint detail (the HA transport)
IF EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints)
BEGIN
    SELECT
        e.name                                  AS endpoint_name,
        e.state_desc                            AS endpoint_state,
        dme.role_desc                           AS endpoint_role,            -- ALL / PARTNER / WITNESS
        dme.is_encryption_enabled,
        dme.encryption_algorithm_desc           AS encryption_algorithm,     -- must MATCH across replicas
        dme.connection_auth_desc                AS connection_auth,          -- WINDOWS NEGOTIATE/KERBEROS/NTLM / CERTIFICATE / combos
        te.port                                 AS listener_port,            -- default 5022; open in firewall
        te.is_dynamic_port,
        te.ip_address,
        dme.certificate_id,
        c.name                                  AS auth_certificate_name
    FROM sys.database_mirroring_endpoints AS dme
    INNER JOIN sys.endpoints AS e
        ON dme.endpoint_id = e.endpoint_id
    LEFT JOIN sys.tcp_endpoints AS te
        ON e.endpoint_id = te.endpoint_id
    LEFT JOIN sys.certificates AS c
        ON dme.certificate_id = c.certificate_id;
END
ELSE
BEGIN
    SELECT 'No DATABASE_MIRRORING endpoint exists on this instance. '
         + 'Both database mirroring AND Always On AGs require one (default port 5022).' AS info_message;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: CONNECT Permissions on Endpoints
  Each partner/replica login must have CONNECT on the endpoint (missing grant =
  classic AG-join / mirroring error 1418).
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    e.name                                      AS endpoint_name,
    e.type_desc                                 AS endpoint_type,
    sp.permission_name,                                              -- CONNECT
    sp.state_desc                               AS permission_state, -- GRANT / DENY
    grantee.name                                AS granted_to_principal,
    grantee.type_desc                           AS principal_type    -- SQL_LOGIN / WINDOWS_LOGIN / CERTIFICATE_MAPPED_LOGIN
FROM sys.server_permissions AS sp
INNER JOIN sys.endpoints AS e
    ON sp.major_id = e.endpoint_id
   AND sp.class = 105                           -- class 105 = endpoint
INNER JOIN sys.server_principals AS grantee
    ON sp.grantee_principal_id = grantee.principal_id
WHERE e.type_desc = 'DATABASE_MIRRORING'
ORDER BY e.name, grantee.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: TCP Listener State for the Endpoint Port
  Confirms the instance is actually listening on the DATABASE_MIRRORING port.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    tls.ip_address,
    tls.port,
    tls.type_desc                               AS listener_type,    -- e.g. 'TSQL', 'Database Mirroring'
    tls.state_desc                              AS listener_state,   -- ONLINE / etc.
    tls.start_time
FROM sys.dm_tcp_listener_states AS tls
ORDER BY tls.type_desc, tls.port;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Certificate-Based Endpoint Authentication
  Lists certificates and their owning principals — relevant when endpoints use
  AUTHENTICATION = CERTIFICATE (cross-domain / workgroup / Linux replicas).
  Watch expiry_date: an expired endpoint cert silently breaks the session.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    c.name                                      AS certificate_name,
    c.certificate_id,
    USER_NAME(c.principal_id)                   AS owning_principal,
    c.subject,
    c.start_date,
    c.expiry_date,
    CASE WHEN c.expiry_date < SYSUTCDATETIME() THEN 'EXPIRED — endpoint auth will FAIL'
         WHEN c.expiry_date < DATEADD(DAY, 30, SYSUTCDATETIME()) THEN 'Expiring within 30 days'
         ELSE 'OK'
    END                                         AS expiry_status,
    c.pvt_key_encryption_type_desc              AS private_key_protection
FROM sys.certificates AS c
ORDER BY c.expiry_date;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: SETUP TEMPLATES — COMMENTED OUT. For reference only.
  Full walkthrough (incl. certificate cross-import) in
  references/mirroring-endpoints.md.
──────────────────────────────────────────────────────────────────────────────*/
/*
   -- Windows-auth endpoint (same domain), used by mirroring AND AGs:
   --   CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED
   --       AS TCP (LISTENER_PORT = 5022)
   --       FOR DATABASE_MIRRORING (ROLE = ALL,
   --           AUTHENTICATION = WINDOWS NEGOTIATE,
   --           ENCRYPTION = REQUIRED ALGORITHM AES);
   --   GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [DOMAIN\PartnerSqlSvc];

   -- Certificate-auth endpoint (cross-domain / Linux) — local cert is Node1_Cert:
   --   CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED
   --       AS TCP (LISTENER_PORT = 5022)
   --       FOR DATABASE_MIRRORING (ROLE = ALL,
   --           AUTHENTICATION = CERTIFICATE [Node1_Cert],
   --           ENCRYPTION = REQUIRED ALGORITHM AES);
   -- Then import each partner's PUBLIC cert under a mapped login and grant CONNECT.
*/
