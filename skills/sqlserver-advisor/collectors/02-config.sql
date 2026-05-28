/*******************************************************************************
 * SQL Server Advisor - Collector 02: Configuration
 *
 * Purpose : Capture the instance-level run-value configuration surface
 *           (sp_configure equivalent) as one row per setting so DuckDB can flag
 *           well-known misconfigurations (MAXDOP, cost threshold, max/min server
 *           memory, optimize for ad hoc workloads, etc.).
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box / Azure VM). On Azure SQL Database the
 *           instance-scoped sys.configurations surface is NOT meaningful (most
 *           config is database-scoped or platform-managed) - see note below.
 * Safety  : READ-ONLY. Reads sys.configurations only. This script NEVER calls
 *           sp_configure to write, and NEVER runs RECONFIGURE. It does not even
 *           toggle 'show advanced options' - sys.configurations already exposes
 *           every advanced setting regardless of that flag.
 *
 * Output columns (EXACT capture contract -> capture/config.csv):
 *   server_name, captured_at, config_name, value_in_use, minimum, maximum
 *
 * Platform / DMV caveats:
 *   - sys.configurations is empty/irrelevant on Azure SQL Database (EngineEdition
 *     5); instance config there is managed by the platform. On Azure SQL MI (8),
 *     AWS RDS, and Cloud SQL a subset is settable; the catalog still reads fine.
 *   - value_in_use is the running value (post-RECONFIGURE); 'value' (the
 *     configured-but-not-yet-active value) is intentionally not in the contract.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))  AS server_name,
    SYSUTCDATETIME()                                     AS captured_at,
    c.name                                               AS config_name,
    CONVERT(bigint, c.value_in_use)                      AS value_in_use,
    CONVERT(bigint, c.minimum)                           AS minimum,
    CONVERT(bigint, c.maximum)                           AS maximum
FROM sys.configurations AS c
ORDER BY c.name;
