/*******************************************************************************
 * SQL Server Advisor - Collector 03: Database Inventory
 *
 * Purpose : Capture per-database settings that drive correctness and
 *           performance recommendations: recovery model, compatibility level,
 *           RCSI / snapshot isolation, auto-stats flags, page-verify option,
 *           log-reuse-wait reason, and total size. One row per database.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box / Azure VM / MI / RDS / Cloud SQL).
 * Safety  : READ-ONLY. Reads sys.databases + sys.master_files only.
 *
 * Per-DB context note: although sys.databases is instance-wide, this collector
 * is listed under the per-DB group conceptually only for the database_name
 * column. It is SAFE to run once at the instance level and returns every
 * database in one result set. (The capture guide may run it a single time.)
 *
 * Output columns (EXACT capture contract -> capture/db_inventory.csv):
 *   server_name, captured_at, database_name, database_id, state_desc,
 *   recovery_model_desc, compatibility_level, is_read_committed_snapshot_on,
 *   is_snapshot_isolation_state_on, is_auto_create_stats_on,
 *   is_auto_update_stats_on, is_auto_update_stats_async_on,
 *   page_verify_option_desc, log_reuse_wait_desc, total_size_mb
 *
 * Platform / DMV caveats:
 *   - On Azure SQL Database you typically see master + the single user DB you are
 *     connected to. sys.master_files may be restricted; total_size_mb falls back
 *     to NULL there if master_files rows are not visible.
 *   - is_snapshot_isolation_state_on is an int (0/1/2/3 state); contract carries
 *     the column verbatim as captured.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))  AS server_name,
    SYSUTCDATETIME()                                     AS captured_at,
    d.name                                               AS database_name,
    d.database_id                                        AS database_id,
    d.state_desc                                         AS state_desc,
    d.recovery_model_desc                                AS recovery_model_desc,
    d.compatibility_level                                AS compatibility_level,
    d.is_read_committed_snapshot_on                      AS is_read_committed_snapshot_on,
    d.snapshot_isolation_state                           AS is_snapshot_isolation_state_on,
    d.is_auto_create_stats_on                            AS is_auto_create_stats_on,
    d.is_auto_update_stats_on                            AS is_auto_update_stats_on,
    d.is_auto_update_stats_async_on                      AS is_auto_update_stats_async_on,
    d.page_verify_option_desc                            AS page_verify_option_desc,
    d.log_reuse_wait_desc                                AS log_reuse_wait_desc,
    sz.total_size_mb                                     AS total_size_mb
FROM sys.databases AS d
OUTER APPLY
(
    SELECT CAST(SUM(mf.size) * 8.0 / 1024 AS DECIMAL(18,2)) AS total_size_mb
    FROM sys.master_files AS mf
    WHERE mf.database_id = d.database_id
) AS sz
ORDER BY d.name;
