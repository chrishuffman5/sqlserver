-- =====================================================================
-- 00-load.sql  —  sqlserver-advisor : load the captured CSVs into DuckDB
-- ---------------------------------------------------------------------
-- PREREQUISITE: a completed capture run has written the 12 contract CSVs
--               into ./capture/ (relative to the DuckDB working dir).
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
-- =====================================================================

-- header=true: the contract CSVs always carry a header row.
-- sample_size=-1: scan the WHOLE file for type inference. The captures mix
--   big integers (row counts, bytes), decimals (pct, cost), timestamps
--   (captured_at, last_user_*), and free text (sample_query_text,
--   *_column_list). A bounded sample can mis-type a column that only turns
--   non-NULL deep in the file (e.g. last_user_seek), so we force a full scan.

-- Formatting helpers used by the a01..a99 metric strings. They cast to
-- DOUBLE first so a value inferred as INTEGER, BIGINT, or DECIMAL all format
-- identically (DuckDB's '{:.Nf}' float spec rejects integer arguments).
--   fmt_n(x)    -> thousands-separated, no decimals  (e.g. 12,000,000)
--   fmt_d(x, d) -> thousands-separated, d decimals    (e.g. 62.5)
CREATE OR REPLACE MACRO fmt_n(x)    AS format('{:,.0f}', x::DOUBLE);
CREATE OR REPLACE MACRO fmt_d(x, d) AS format('{:,.' || d::VARCHAR || 'f}', x::DOUBLE);

CREATE OR REPLACE TABLE server_info      AS SELECT * FROM read_csv_auto('capture/server_info.csv',      header=true, sample_size=-1);
CREATE OR REPLACE TABLE config           AS SELECT * FROM read_csv_auto('capture/config.csv',           header=true, sample_size=-1);
CREATE OR REPLACE TABLE db_inventory     AS SELECT * FROM read_csv_auto('capture/db_inventory.csv',     header=true, sample_size=-1);
CREATE OR REPLACE TABLE tables           AS SELECT * FROM read_csv_auto('capture/tables.csv',           header=true, sample_size=-1);
CREATE OR REPLACE TABLE columns          AS SELECT * FROM read_csv_auto('capture/columns.csv',          header=true, sample_size=-1);
CREATE OR REPLACE TABLE indexes          AS SELECT * FROM read_csv_auto('capture/indexes.csv',          header=true, sample_size=-1);
CREATE OR REPLACE TABLE index_usage      AS SELECT * FROM read_csv_auto('capture/index_usage.csv',      header=true, sample_size=-1);
CREATE OR REPLACE TABLE missing_indexes  AS SELECT * FROM read_csv_auto('capture/missing_indexes.csv',  header=true, sample_size=-1);
CREATE OR REPLACE TABLE index_physical   AS SELECT * FROM read_csv_auto('capture/index_physical.csv',   header=true, sample_size=-1);
CREATE OR REPLACE TABLE foreign_keys     AS SELECT * FROM read_csv_auto('capture/foreign_keys.csv',     header=true, sample_size=-1);
CREATE OR REPLACE TABLE query_stats      AS SELECT * FROM read_csv_auto('capture/query_stats.csv',      header=true, sample_size=-1);
CREATE OR REPLACE TABLE wait_stats       AS SELECT * FROM read_csv_auto('capture/wait_stats.csv',       header=true, sample_size=-1);

-- ---------------------------------------------------------------------
-- PARQUET VARIANT (optional) — if the collector exported Parquet instead
-- of (or in addition to) CSV, swap read_csv_auto for read_parquet. Parquet
-- preserves types exactly (no inference) and is far cheaper to re-scan, so
-- it is the better format for keeping captures around. Example:
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
