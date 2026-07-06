-- =====================================================================
-- 00-load.sql  —  sqlserver-advisor : load the captured CSVs into DuckDB
-- ---------------------------------------------------------------------
-- PREREQUISITE: a completed capture run has written the 16 contract CSVs
--               into ./capture/ (relative to the DuckDB working dir).
--               If a collector was skipped (platform) or returned zero rows,
--               create the CSV as a header-only stub (the capture-guide
--               harness does this) so every table still loads — empty.
-- WHAT THIS DOES: creates one DuckDB table per capture file. The table
--               name == the CSV base name (the pinned-contract name), so
--               the a01..a99 analysis queries can reference them directly.
-- HOW TO RUN:    duckdb advisor.duckdb            (a persistent db, recommended)
--                  .read analysis/00-load.sql
--                  .read analysis/a99-recommendations.sql
--               or for a one-shot in-memory session:
--                  duckdb -c ".read analysis/00-load.sql" -c ".read analysis/a99-recommendations.sql"
--
-- All reads are READ-ONLY against local files. Nothing here touches the
-- source SQL Server — the capture already happened, once.
--
-- TYPES ARE PINNED. Each load passes types={...} for every non-text
-- contract column, because the contract is pinned anyway and inference
-- alone has two failure modes: (a) a header-only stub CSV would infer
-- every column as VARCHAR, breaking the analysis queries' numeric/date
-- comparisons; (b) a column that is all-NULL in this capture (e.g.
-- last_user_seek) would land VARCHAR and break date_diff. BOOLEAN columns
-- accept both True/False (PowerShell) and 1/0 (sqlcmd) spellings.
-- Timestamps must be ISO-ish (yyyy-MM-dd HH:mm:ss[.fff]) — the capture
-- guide's export path guarantees this; avoid locale-formatted dates.
-- =====================================================================

-- Formatting helpers used by the a01..a99 metric strings. They cast to
-- DOUBLE first so a value typed INTEGER, BIGINT, or DECIMAL all format
-- identically (DuckDB's '{:.Nf}' float spec rejects integer arguments).
--   fmt_n(x)    -> thousands-separated, no decimals  (e.g. 12,000,000)
--   fmt_d(x, d) -> thousands-separated, d decimals    (e.g. 62.5)
CREATE OR REPLACE MACRO fmt_n(x)    AS format('{:,.0f}', x::DOUBLE);
CREATE OR REPLACE MACRO fmt_d(x, d) AS format('{:,.' || d::VARCHAR || 'f}', x::DOUBLE);

CREATE OR REPLACE TABLE server_info AS SELECT * FROM read_csv_auto('capture/server_info.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','product_major_version':'INTEGER','engine_edition':'INTEGER',
           'host_cpu_count':'INTEGER','host_physical_memory_mb':'BIGINT','sql_memory_limit_mb':'BIGINT',
           'sqlserver_start_time':'TIMESTAMP','is_hadr_enabled':'INTEGER'});

CREATE OR REPLACE TABLE config AS SELECT * FROM read_csv_auto('capture/config.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','value_in_use':'BIGINT','minimum':'BIGINT','maximum':'BIGINT'});

CREATE OR REPLACE TABLE db_inventory AS SELECT * FROM read_csv_auto('capture/db_inventory.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','database_id':'INTEGER','compatibility_level':'INTEGER',
           'is_read_committed_snapshot_on':'BOOLEAN','is_snapshot_isolation_state_on':'INTEGER',
           'is_auto_create_stats_on':'BOOLEAN','is_auto_update_stats_on':'BOOLEAN',
           'is_auto_update_stats_async_on':'BOOLEAN','total_size_mb':'DOUBLE'});

CREATE OR REPLACE TABLE tables AS SELECT * FROM read_csv_auto('capture/tables.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','object_id':'BIGINT','is_heap':'BOOLEAN','has_primary_key':'BOOLEAN',
           'has_clustered_columnstore':'BOOLEAN','row_count':'BIGINT','total_space_mb':'DOUBLE',
           'used_space_mb':'DOUBLE','data_space_mb':'DOUBLE','index_space_mb':'DOUBLE',
           'unused_space_mb':'DOUBLE','partition_count':'INTEGER'});

CREATE OR REPLACE TABLE columns AS SELECT * FROM read_csv_auto('capture/columns.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','column_id':'INTEGER','max_length_bytes':'INTEGER','precision':'INTEGER',
           'scale':'INTEGER','is_nullable':'BOOLEAN','is_computed':'BOOLEAN','is_identity':'BOOLEAN'});

CREATE OR REPLACE TABLE indexes AS SELECT * FROM read_csv_auto('capture/indexes.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','object_id':'BIGINT','index_id':'INTEGER','is_unique':'BOOLEAN',
           'is_primary_key':'BOOLEAN','is_unique_constraint':'BOOLEAN','is_disabled':'BOOLEAN',
           'is_filtered':'BOOLEAN','fill_factor':'INTEGER'});

CREATE OR REPLACE TABLE index_usage AS SELECT * FROM read_csv_auto('capture/index_usage.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','index_id':'INTEGER','user_seeks':'BIGINT','user_scans':'BIGINT',
           'user_lookups':'BIGINT','user_updates':'BIGINT','last_user_seek':'TIMESTAMP',
           'last_user_scan':'TIMESTAMP','last_user_lookup':'TIMESTAMP','last_user_update':'TIMESTAMP'});

CREATE OR REPLACE TABLE missing_indexes AS SELECT * FROM read_csv_auto('capture/missing_indexes.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','unique_compiles':'BIGINT','user_seeks':'BIGINT','user_scans':'BIGINT',
           'avg_total_user_cost':'DOUBLE','avg_user_impact':'DOUBLE','improvement_measure':'DOUBLE'});

CREATE OR REPLACE TABLE index_physical AS SELECT * FROM read_csv_auto('capture/index_physical.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','index_id':'INTEGER','partition_number':'INTEGER',
           'avg_fragmentation_in_percent':'DOUBLE','page_count':'BIGINT',
           'avg_page_space_used_in_percent':'DOUBLE','fragment_count':'BIGINT','forwarded_record_count':'BIGINT'});

CREATE OR REPLACE TABLE foreign_keys AS SELECT * FROM read_csv_auto('capture/foreign_keys.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','is_disabled':'BOOLEAN','is_not_trusted':'BOOLEAN'});

CREATE OR REPLACE TABLE query_stats AS SELECT * FROM read_csv_auto('capture/query_stats.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','execution_count':'BIGINT','total_worker_time_ms':'DOUBLE',
           'avg_worker_time_ms':'DOUBLE','total_logical_reads':'BIGINT','avg_logical_reads':'DOUBLE',
           'total_elapsed_time_ms':'DOUBLE','avg_elapsed_time_ms':'DOUBLE','total_grant_kb':'BIGINT'});

CREATE OR REPLACE TABLE wait_stats AS SELECT * FROM read_csv_auto('capture/wait_stats.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','waiting_tasks_count':'BIGINT','wait_time_ms':'BIGINT',
           'signal_wait_time_ms':'BIGINT','pct_of_total':'DOUBLE'});

CREATE OR REPLACE TABLE db_files AS SELECT * FROM read_csv_auto('capture/db_files.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','database_id':'INTEGER','file_id':'INTEGER','size_mb':'DOUBLE',
           'max_size_mb':'DOUBLE','is_percent_growth':'BOOLEAN','growth_value':'DOUBLE','vlf_count':'BIGINT'});

CREATE OR REPLACE TABLE backup_history AS SELECT * FROM read_csv_auto('capture/backup_history.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','last_full_backup':'TIMESTAMP','last_diff_backup':'TIMESTAMP',
           'last_log_backup':'TIMESTAMP','full_backup_count_30d':'INTEGER','log_backup_count_7d':'INTEGER',
           'last_full_backup_size_mb':'DOUBLE','last_full_has_checksum':'INTEGER'});

CREATE OR REPLACE TABLE stats_health AS SELECT * FROM read_csv_auto('capture/stats_health.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','stats_id':'INTEGER','is_auto_created':'BOOLEAN','is_user_created':'BOOLEAN',
           'no_recompute':'BOOLEAN','has_filter':'BOOLEAN','last_updated':'TIMESTAMP','rows':'BIGINT',
           'rows_sampled':'BIGINT','sample_pct':'DOUBLE','modification_counter':'BIGINT'});

CREATE OR REPLACE TABLE identity_columns AS SELECT * FROM read_csv_auto('capture/identity_columns.csv', header=true, sample_size=-1,
    types={'captured_at':'TIMESTAMP','seed_value':'DECIMAL(38,0)','increment_value':'DECIMAL(38,0)',
           'last_value':'DECIMAL(38,0)','max_value':'DECIMAL(38,0)','is_cycling':'BOOLEAN','pct_used':'DOUBLE'});

-- ---------------------------------------------------------------------
-- PARQUET VARIANT (optional) — if the collector exported Parquet instead
-- of (or in addition to) CSV, swap read_csv_auto for read_parquet. Parquet
-- preserves types exactly (no inference or types= needed) and is far
-- cheaper to re-scan, so it is the better format for keeping captures
-- around. Example:
--
--   CREATE OR REPLACE TABLE tables AS SELECT * FROM read_parquet('capture/tables.parquet');
--
-- ---------------------------------------------------------------------
-- TRENDING ACROSS RUNS — keep each capture run in its own dated subfolder
-- (e.g. capture/2026-05-28T0900Z/tables.csv, capture/2026-05-29T0900Z/...)
-- and glob across them; every contract row already carries captured_at, so
-- you can GROUP BY captured_at to trend table growth / fragmentation / waits
-- over time. read_csv_auto / read_parquet accept a glob and a union flag:
--
--   CREATE OR REPLACE TABLE tables_history AS
--     SELECT * FROM read_csv_auto('capture/*/tables.csv', header=true,
--                                 sample_size=-1, union_by_name=true);
--   -- then: SELECT captured_at, database_name, schema_name, table_name,
--   --              total_space_mb FROM tables_history ORDER BY 2,3,4,1;
-- =====================================================================
