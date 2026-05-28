# Indexing Reference

How SQL Server indexes are structured, how the optimizer uses them, and how to design, cover, consolidate, and clean them. Covers rowstore (clustered/nonclustered), columnstore, filtered, and In-Memory OLTP indexes for SQL Server 2016–2025 and Azure SQL DB/MI.

---

## 1. The Clustered Index — Choose the Key Carefully

A clustered index **physically orders the table by its key; the leaf level *is* the data**. One per table. A table with no clustered index is a **heap** (rows located by a physical `RID` = file:page:slot, no order).

The clustered key is propagated into **every nonclustered index as the row locator** (see §2), so the key's choice has table-wide cost. Pick a key that is:

- **Narrow** — every byte is duplicated in every NCI and in every NCI's intermediate levels. A wide clustered key (e.g. a composite of several `nvarchar` columns) bloats the entire index subsystem.
- **Unique** — if the clustered key isn't declared unique, SQL Server silently adds a 4-byte **uniquifier** to duplicate keys (and an overflow structure once you exceed ~2.1B dupes of a value). Unique keys also give the optimizer a cardinality guarantee.
- **Static** — updating the clustered key physically moves the row and updates every NCI's locator. Choose a column that doesn't change.
- **Ever-increasing** — `IDENTITY`/`SEQUENCE` or other monotonic keys append to the end, avoiding mid-index page splits and fragmentation. **Random GUIDs (`NEWID()`) are the anti-pattern**: random insert points cause constant page splits — use `NEWSEQUENTIALID()` or, better, a sequential surrogate if you cluster on it.

The PK defaults to the clustered index, but **PK ≠ clustered**: you can make the PK nonclustered and cluster on a better column (e.g. a monotonic event timestamp on an append-only table).

---

## 2. Nonclustered Index Structure & the Row Locator

A nonclustered index (NCI) is a separate B-tree whose leaf level holds the **key columns + INCLUDE columns + a row locator** back to the base table:
- If the table has a **clustered index**, the locator is the **clustered key**.
- If the table is a **heap**, the locator is the physical **RID**.

This is why the clustered key's width matters everywhere, and why a narrow clustered key keeps NCIs lean. When a query needs columns *not* in the NCI, the engine performs a **Key Lookup** (clustered) or **RID Lookup** (heap) — one random read per qualifying row (§4).

Limits (verify on Microsoft Learn for your build): up to **999 nonclustered indexes** per table; an index key can have up to **32 key columns**. **Key byte size:** a **clustered** key ≤ **900 bytes**; a **nonclustered** key ≤ **1,700 bytes on 2016+** (it was 900 for all index types on 2014 and earlier). `INCLUDE` columns count against neither the column-count nor the byte limit — use them to escape the key-size ceiling and to cover wide SELECT lists.

---

## 3. Covering Indexes & INCLUDE

A **covering index** contains every column a query touches, so the query is satisfied entirely from the index — no lookup to the base table.

`INCLUDE` adds columns to the **leaf level only**. They are *not* part of the key, so they:
- don't participate in sort order or uniqueness,
- don't bloat the intermediate B-tree levels,
- can be types disallowed in keys (e.g. `nvarchar(max)`, up to the LOB rules).

```sql
-- [SCHEMA CHANGE] Query: SELECT C, D FROM T WHERE A = @a AND B > @b
-- Creating an index is size-of-data; OFFLINE create takes a Sch-M lock (ONLINE = ON is
-- Enterprise/Azure-only). Confirm target DB and use a maintenance window for large tables.
CREATE NONCLUSTERED INDEX IX_T_A_B_inc_C_D
    ON dbo.[MyDB_Table] (A, B)   -- key: equality (A) before range (B)
    INCLUDE (C, D);              -- payload: covers the SELECT list
```

**Key-column ordering rule:** put **equality** predicate columns first (in selectivity order), then **range** predicate columns, then columns needed only for `ORDER BY`. A range predicate "stops" the usefulness of subsequent key columns for seeking, so a range column should be last among seekable keys.

Don't over-cover: each extra column widens the leaf and adds write cost. Cover the *hot* query, not every column.

---

## 4. Key Lookups — Detect and Eliminate

A **Key Lookup** appears when a nonclustered index is selective enough to be chosen but doesn't contain all the SELECT/predicate columns. The optimizer joins the NCI seek back to the clustered index, one lookup per row. A few are fine; thousands dominate cost and can flip the optimizer into a full scan instead.

**Eliminate by covering** the missing columns:
- If the missing column is in the SELECT list → add it via `INCLUDE`.
- If the missing column is in a residual predicate / `ORDER BY` that should seek → add it to the **key**.

```sql
-- [SCHEMA CHANGE] Plan shows: Index Seek (IX_T_A) -> Key Lookup (PK) for column D
-- Fix: include D so the index covers the query. Size-of-data + log-heavy; an OFFLINE rebuild
-- takes a Sch-M lock that BLOCKS the table. ONLINE = ON is Enterprise-only (also Developer/Eval;
-- the Azure SQL DB/MI engine supports it) — on Standard this runs OFFLINE. Confirm target DB
-- (SELECT DB_NAME()) and run in an approved maintenance window.
CREATE NONCLUSTERED INDEX IX_T_A ON dbo.[MyDB_Table] (A) INCLUDE (D)
    WITH (DROP_EXISTING = ON);   -- add ONLINE = ON only on Enterprise/Azure to avoid the Sch-M block
```

Use `scripts/05-plan-cache-analysis.sql` to surface plans with lookups and missing-index warnings.

---

## 5. Filtered Indexes & the Parameterization Gotcha

A **filtered index** indexes only the rows matching a `WHERE` predicate — smaller, cheaper to maintain, and statistics are more accurate for that subset. Ideal for sparse/soft-delete/status-subset patterns:

```sql
-- [SCHEMA CHANGE] size-of-data create; OFFLINE takes a Sch-M lock (ONLINE = ON Enterprise/Azure-only).
-- Confirm target DB (SELECT DB_NAME()) and run large builds in an approved maintenance window.
CREATE NONCLUSTERED INDEX IX_Order_Open
    ON dbo.[MyDB_Order] (CustomerID, OrderDate)
    INCLUDE (Amount)
    WHERE Status = 'Open';        -- only the hot, small subset is indexed
```

**The gotcha:** a *parameterized* query usually **cannot** use a filtered index, because the optimizer can't prove at compile time that the parameter matches the filter. `WHERE Status = @s` will typically ignore `WHERE Status = 'Open'`. Workarounds:
- Use a **literal** in the query (`WHERE Status = 'Open'`).
- Add `OPTION (RECOMPILE)` so the value is known at compile time.
- For parameterized access, use a regular (non-filtered) index.

Also: the filter predicate must be deterministic and reference only columns in the table; the query's predicate must be *implied by* (a superset condition of) the index filter for it to qualify. `IS NOT NULL` filters are a great fit for indexing sparse columns.

---

## 6. Columnstore Indexes

Columnstore stores data **column-by-column**, highly compressed, and is processed in **batch mode** (~900 rows per CPU iteration). It is the engine for analytics/DW: large scans, aggregations, and grouping. It is *not* for OLTP singleton lookups/updates.

### Clustered (CCI) vs. Nonclustered (NCCI)
- **Clustered columnstore (CCI)** — the table *is* columnar. Best for fact/DW tables, append-mostly, large. Becomes the primary storage.
- **Nonclustered columnstore (NCCI)** — a columnar index *on top of* a rowstore table, enabling **real-time operational analytics**: OLTP keeps its B-trees for point operations while analytic queries hit the NCCI in batch mode. Can be **filtered** (e.g. `WHERE Status='Closed'`) to exclude hot rows.

### Rowgroups, the delta store, and the tuple mover
- Rows compress into **rowgroups** of up to ~**1,048,576 (2^20) rows**. The ideal is rowgroups near that max.
- Small inserts land in a **delta store** (a rowstore B-tree, state `OPEN`). When a delta rowgroup fills (~1M rows) it becomes `CLOSED`; the background **tuple mover** then compresses it into a columnar rowgroup (`COMPRESSED`).
- **Quality problems** that hurt batch-mode efficiency: many under-full rowgroups (`trim_reason` shows why a rowgroup was trimmed — memory pressure, dictionary size, bulk load size), a high **deleted-rows** ratio (deletes are logical until rebuild), and lingering delta stores. `REORGANIZE` compresses closed delta rowgroups and merges fragmented ones; `REBUILD` fully recompresses. Assess with `scripts/08-columnstore-health.sql` (the *maintenance execution* belongs to `sqlserver-operations`).
- **Bulk-load** ≥ ~102,400 rows per batch goes straight to a compressed rowgroup, bypassing the delta store — size your loads accordingly.

### Combining columnstore with rowstore
You **can** add ordinary nonclustered rowstore indexes on top of a CCI (2016+) to support occasional selective seeks/constraints on an otherwise analytic table — a "hybrid" pattern for DW tables that also need a few point lookups or unique constraints.

---

## 7. Unique vs. Non-Unique Indexes

Declare an index **unique** whenever the data is unique. Beyond enforcing integrity, uniqueness gives the optimizer a **cardinality guarantee** (at most one row per key), enabling better join/seek choices and avoiding the clustered-index uniquifier. A `UNIQUE` constraint is implemented as a unique index. Don't fake uniqueness by leaving an index non-unique "just in case" — you lose the optimizer benefit and pay for the uniquifier on the clustered key.

---

## 8. Fill Factor & Page Splits

- A **page split** occurs when a row must be inserted/expanded into a full page: SQL Server allocates a new page and moves ~half the rows — expensive (extra logging, fragmentation, latch contention).
- **`FILLFACTOR`** leaves free space in leaf pages at build/rebuild time so in-place inserts/updates don't immediately split. `FILLFACTOR = 100` (default, =0) packs pages full — ideal for **ever-increasing** keys (appends never split mid-index) but bad for keys with random/mid-range inserts.
- For random-insert indexes (e.g. a GUID key you can't change), a lower fill factor (e.g. 80–90) reduces splits at the cost of more pages / lower buffer-pool density. **Tuning fill factor and scheduling rebuilds/reorgs is an operations concern → `sqlserver-operations`.** Design-time guidance: fix the *key* (make it monotonic) before reaching for a low fill factor.

> **Edition gate for rebuilds:** `REBUILD WITH (ONLINE = ON)` is **Enterprise-only** (also Developer/Evaluation; the Azure SQL DB/MI engine supports it) across **all** box versions 2016–2025 — Standard **never** gained it. On Standard, `REBUILD` is **OFFLINE** (takes a Sch-M lock that blocks the table), so default to `REORGANIZE` (always online, any edition) or a scheduled OFFLINE rebuild in an approved window. **RESUMABLE** rebuild requires `ONLINE = ON` (so it's Enterprise-gated on box); resumable *create* is 2019+.

---

## 9. Missing-Index DMVs — Use, Don't Obey

`sys.dm_db_missing_index_details` / `_groups` / `_group_stats` record indexes the optimizer *wished it had* during compilation. They're a useful signal but **not a plan**:
- They never **consolidate** overlapping suggestions — you'll see five near-duplicates differing only by an INCLUDE column.
- They ignore **existing** indexes, **write cost**, and the order of equality vs. inequality columns isn't always optimal.
- `improvement_measure` ≈ `avg_total_user_cost × avg_user_impact × (user_seeks + user_scans)` — useful for ranking, not absolute truth.

**Workflow:** rank by improvement measure, **merge overlapping suggestions into one index** (union the equality columns as the key in selectivity order, fold the rest into `INCLUDE`), check it doesn't duplicate an existing index, then test. See `scripts/02-missing-indexes.sql`.

---

## 10. Cleaning Up: Unused and Duplicate Indexes

Every index is **maintained on every INSERT/UPDATE/DELETE** and consumes buffer-pool and backup space. Over-indexing is as harmful as under-indexing.

- **Unused indexes** — `sys.dm_db_index_usage_stats` shows `user_seeks/scans/lookups` (reads) vs. `user_updates` (write maintenance). An index with **zero reads and nonzero writes** is pure overhead. Caveat: these counters **reset on instance restart** (and historically on index rebuild on some versions), so judge over a representative uptime window. See `scripts/01-index-usage.sql`.
- **Duplicate / overlapping indexes** — exact duplicates (same key columns in the same order) are always droppable; a **left-prefix** index (`(A)`) is redundant with `(A, B)` for most purposes. Compare key column lists to find them — `scripts/04-duplicate-overlapping-indexes.sql`. Keep the more general one (the wider key / better covering set).

Never drop the index backing a `PRIMARY KEY`/`UNIQUE` constraint or a `FOREIGN KEY`'s supporting index without checking it's not enforcing integrity or supporting cascades/joins.

---

## 11. In-Memory OLTP Indexes

Memory-optimized tables (see `schema-design.md`) use index structures that live **only in memory** and are **rebuilt on restart** (so they aren't logged, and there's no fragmentation concept). Every memory-optimized table needs at least one index; choose by access pattern:

- **Hash index** — O(1) **equality** lookups only (no range/order). Critically, you must size **`BUCKET_COUNT`** to ~1–2× the number of *distinct* key values:
  ```sql
  -- [SCHEMA CHANGE] Adding an index to a memory-optimized table is a size-of-data rebuild that
  -- takes a Sch-M lock blocking the table while it runs; confirm target DB (SELECT DB_NAME()) and
  -- run in an approved maintenance window. (In-Memory OLTP needs a memory-optimized filegroup +
  -- Enterprise on box / Business Critical|Premium on Azure.)
  ALTER TABLE dbo.[MyDB_Session] ADD INDEX IX_Session_Token
      HASH (Token) WITH (BUCKET_COUNT = 1000000);
  ```
  Too few buckets → long hash chains (collisions) → slow lookups; too many → wasted memory. Hash indexes are useless for range predicates and `ORDER BY`.
- **Range (Bw-tree / nonclustered) index** — supports range scans, inequality, and ordered retrieval; the right default unless the access is purely equality on a high-cardinality key. No `BUCKET_COUNT`, no `INCLUDE` (the memory-optimized row is referenced directly, so all columns are effectively available).

Pick **hash** for high-volume point lookups on a unique-ish key with a well-known cardinality; pick **range** for everything else or when in doubt.

---

## Cross-References
- Estimates/sniffing that decide whether an index gets *used*: `query-optimization.md`.
- Filtered-index parameterization interacts with the sniffing ladder: `query-optimization.md`.
- Clustered-key data-type choices, partition-aligned indexes, computed-column indexing: `schema-design.md`.
- Rebuild/reorganize automation, fill-factor jobs, fragmentation maintenance: **`sqlserver-operations`**.
- Live latch/lock contention on hot indexes: **`sqlserver-monitoring`**.
- **Community tooling (read-only):** Brent Ozar's **`sp_BlitzIndex`** consolidates missing/unused/duplicate/overly-wide index findings and flags heaps (`@Mode = 4` for detail) — a fast first pass before hand-running `scripts/01/02/04`. Install/usage and safety notes live in the community-tools section of **`sqlserver-monitoring`**.
