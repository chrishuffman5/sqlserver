# Schema Design Reference

Designing tables, types, constraints, and physical structures that are correct, performant, and maintainable on SQL Server 2016–2025 and Azure SQL DB/MI. Good schema design front-loads correctness (constraints the optimizer can trust) and minimizes the cost paid on every read and write (type width, conversions, partition/compression strategy).

---

## 1. Normalization vs. Denormalization

Normalize first; denormalize deliberately, with evidence.

- **1NF** — atomic columns, no repeating groups / comma-lists in a column.
- **2NF** — no partial dependency on part of a composite key.
- **3NF** — no transitive dependency (non-key attributes depend only on the key).
- **BCNF** — every determinant is a candidate key (a stricter 3NF).

Normalization removes update anomalies and keeps writes cheap and consistent. **Denormalize only when** a measured read pattern demands it: a hot reporting query joining many tables, an aggregate computed repeatedly, or a high-fan-out lookup. When you do, choose a *maintained* mechanism over a hand-synced copy:
- **Indexed (materialized) view** for pre-joined/pre-aggregated results the engine keeps current.
- **Persisted computed column** for a derived value (§5).
- **Columnstore** for analytic aggregates over a normalized fact table (often removes the *need* to denormalize).

Avoid the EAV (entity-attribute-value) anti-pattern and storing delimited lists — both defeat typing, constraints, and SARGability.

---

## 2. Data Types — Choose the Narrowest Correct Type

Type choice affects storage, memory grants, index width, and SARGability on *every* row.

- **Dates/times:** prefer **`datetime2(n)`** over `datetime`. `datetime2` has a larger range, true precision control (`datetime2(0)` is 6 bytes vs. `datetime`'s 8 and rounds to 3.33 ms), and ANSI behavior. Use `date` when there's no time component, `datetimeoffset` when you need the zone. Store UTC (`SYSUTCDATETIME()`); convert at the edge.
- **Strings:** `varchar`/`char` (1 byte/char, code-page) vs. `nvarchar`/`nchar` (UTF-16, 2 bytes/char — or UTF-8 via a `_UTF8` collation in 2019+). Choose **deliberately**: using `nvarchar` everywhere doubles storage and, worse, **mixing `varchar` columns with `nvarchar` parameters injects implicit conversions that kill index seeks** (see `query-optimization.md` §7). Avoid `(max)` types unless values genuinely exceed 8,000/4,000 — they have row-overflow/LOB overhead. Avoid deprecated `text`/`ntext`/`image`.
- **Numbers:** integer family (`tinyint`/`smallint`/`int`/`bigint`) sized to the range; **`decimal(p,s)`** for exact money/quantities (never `float`/`real` for money — binary FP can't represent 0.10 exactly). `money` exists but `decimal` is clearer about precision.
- **Booleans:** `bit` (NULLable tri-state; 8 bits pack into 1 byte).
- **GUIDs:** `uniqueidentifier` is 16 bytes — fine as a column, problematic as a *clustered* key when random (see `indexing.md`).
- **Avoid implicit conversions by design:** match parameter/variable types to column types; keep join keys identical in type and collation.

### IDENTITY vs. SEQUENCE
- **`IDENTITY`** — per-column auto-increment; simple, but you can't get the next value without inserting, and it's table-bound.
- **`SEQUENCE`** (2012+) — a standalone object: share one sequence across tables, fetch values *before* insert (`NEXT VALUE FOR`), cache for throughput, define `MINVALUE/MAXVALUE/CYCLE`. Prefer `SEQUENCE` when you need the key before insertion, a cross-table key, or ranges.

Both can leave gaps (rollbacks, cache loss on restart, the 2012 `IDENTITY` reseed-by-1000 jump under TF272/`IDENTITY_CACHE`). Gaps are normal — don't assume contiguity.

---

## 3. Constraints — Correctness *and* Optimizer Hints

Constraints aren't just integrity rules; the optimizer **reasons** with trusted ones to eliminate work.

- **PRIMARY KEY** — entity identity; implemented as a unique index (clustered by default — but you can choose, see `indexing.md`).
- **FOREIGN KEY** — referential integrity; **and** lets the optimizer perform **join elimination** (skip joining a parent table if no columns from it are needed and the FK guarantees the match) — *only if the FK is trusted*.
- **UNIQUE** — alternate keys; gives the optimizer a cardinality guarantee.
- **CHECK** — domain rules; a **trusted** CHECK enables **predicate elimination** / **partition elimination** (e.g. the optimizer can skip a partition/table whose CHECK contradicts the query predicate).
- **DEFAULT** — supplies values; pairs with `NOT NULL` for clean schemas.

### Trusted vs. untrusted constraints (the optimizer cares)
A constraint added `WITH NOCHECK`, or after data was loaded around it, becomes **not trusted** (`is_not_trusted = 1`) — the optimizer **ignores it** for elimination even though it's still enforced for new rows. Re-validate so the optimizer trusts it:

```sql
-- Re-establish trust: WITH CHECK validates existing data and flips is_not_trusted to 0
ALTER TABLE dbo.Child WITH CHECK CHECK CONSTRAINT FK_Child_Parent;
ALTER TABLE dbo.T     WITH CHECK CHECK CONSTRAINT CK_T_Status;

-- Audit untrusted FK/CHECK constraints
SELECT OBJECT_NAME(parent_object_id) AS [table], name, is_not_trusted
FROM   sys.foreign_keys WHERE is_not_trusted = 1
UNION ALL
SELECT OBJECT_NAME(parent_object_id), name, is_not_trusted
FROM   sys.check_constraints WHERE is_not_trusted = 1;
```

---

## 4. Computed Columns

A computed column is defined by an expression over other columns:
- **Non-persisted** — evaluated at read time; stored only in metadata.
- **`PERSISTED`** — materialized on disk and maintained on write; required for indexing if the expression is imprecise (e.g. `float`), and lets the value be read without recomputation.

```sql
ALTER TABLE dbo.[Order]
    ADD LineTotal AS (Quantity * UnitPrice) PERSISTED;   -- maintained, indexable
```

A key use: **make a non-SARGable predicate seekable.** Wrap the expression the queries actually use in a persisted computed column and index it:

```sql
ALTER TABLE dbo.Person ADD UpperLastName AS UPPER(LastName) PERSISTED;
CREATE INDEX IX_Person_UpperLastName ON dbo.Person(UpperLastName);
-- Now WHERE UpperLastName = @n  seeks, where WHERE UPPER(LastName)=@n would scan.
```

The expression must be deterministic (and precise, or persisted) to be indexed.

---

## 5. Sparse Columns

Sparse columns optimize storage for columns that are **mostly NULL**: a NULL costs 0 bytes (vs. the usual fixed-width cost), at the price of higher per-row overhead (~4 extra bytes) for non-NULL values. Worth it only when a large majority of values are NULL (rule of thumb: >~ 40–60% NULL depending on type). Pairs with a **column set** (`xml` aggregate of all sparse columns) and with **filtered indexes** (`WHERE col IS NOT NULL`). Typical use: wide product-catalog tables with many attribute columns relevant to only a few rows.

---

## 6. Partitioning

Partitioning splits one table/index into multiple physical units by a **partition function** on a single column, mapped to filegroups by a **partition scheme**. It is primarily a **manageability / data-lifecycle** feature — *not* a general query accelerator.

```sql
-- 1) Function: defines boundary values. RANGE RIGHT => boundary belongs to the partition on its RIGHT.
CREATE PARTITION FUNCTION pf_OrderDate (date)
    AS RANGE RIGHT FOR VALUES ('2024-01-01', '2025-01-01', '2026-01-01');

-- 2) Scheme: maps each partition to a filegroup
CREATE PARTITION SCHEME ps_OrderDate
    AS PARTITION pf_OrderDate ALL TO ([PRIMARY]);

-- 3) Create/align the table & its indexes ON the scheme(partition column)
CREATE TABLE dbo.[Order] (OrderID bigint, OrderDate date NOT NULL, ...)
    ON ps_OrderDate (OrderDate);
```

- **`RANGE RIGHT` vs `RANGE LEFT`:** with `RANGE RIGHT`, a boundary value goes into the partition *to its right* (lower bound inclusive) — the natural choice for date sliding-windows (`>= '2025-01-01'`). `RANGE LEFT` puts the boundary in the partition to its left.
- **Aligned indexes:** index the table on the same partition column/scheme so indexes are **partition-aligned** — a prerequisite for fast `SWITCH`.
- **Partition elimination:** if the query predicate is on the partition column *and the column isn't wrapped in a non-SARGable expression*, the optimizer scans only the relevant partitions. This is the main read benefit — and it's easy to lose to implicit conversion on the partition column.
- **Sliding window** lifecycle uses metadata-only operations:
  - **`SWITCH`** — move a whole partition in/out as a metadata operation (near-instant) — e.g. switch the oldest partition out to a staging table to archive/drop it; switch a fully-loaded staging table in. Requires matching schema, aligned indexes, and the target/source CHECK constraints.
  - **`SPLIT`** — add a new boundary (create next period's empty partition); keep the affected boundary **empty** to avoid a costly data move.
  - **`MERGE`** — remove a boundary (collapse two partitions).

Don't partition small tables for "speed" — a well-indexed unpartitioned table usually wins. Partition for archival, fast bulk in/out, and piecemeal maintenance.

---

## 7. Temporal (System-Versioned) Tables (2016+)

A system-versioned temporal table automatically keeps full row history in a linked **history table**, with two `datetime2` period columns the engine maintains:

```sql
CREATE TABLE dbo.Employee (
    EmployeeID int PRIMARY KEY,
    Salary     decimal(10,2) NOT NULL,
    ValidFrom  datetime2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    ValidTo    datetime2 GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.EmployeeHistory));
```

Query any past state with `FOR SYSTEM_TIME` (`AS OF`, `FROM..TO`, `BETWEEN`, `CONTAINED IN`, `ALL`):

```sql
SELECT * FROM dbo.Employee FOR SYSTEM_TIME AS OF '2025-01-01T00:00:00';
```

Use for audit, point-in-time analysis, and slowly-changing-dimension history. Notes: the engine writes history on every UPDATE/DELETE (write amplification on hot tables — consider compressing/partitioning the history table); you can't directly modify history while versioning is on; combine with **ledger** (2022) when you need cryptographic tamper-evidence (that's a security concern → `sqlserver-security`).

---

## 8. Data Compression

Trade CPU for reduced I/O and a larger effective buffer pool. Estimate savings first with `sp_estimate_data_compression_savings`.

- **`ROW` compression** — stores fixed-length types using only the bytes needed (variable-length numerics, no padding). Low CPU cost; almost always a net win on I/O-bound tables.
- **`PAGE` compression** — ROW + prefix + dictionary compression within a page. Higher CPU, larger savings; best for read-heavy / scan-heavy data with repetition.
- **Columnstore** is already heavily compressed; **`COLUMNSTORE_ARCHIVE`** squeezes cold rowgroups further (more CPU to decompress) for rarely-read historical data.
- **XML compression** (2022) for `xml`-typed columns.

Compression applies per table/index/partition — a common pattern is `PAGE`/`COLUMNSTORE_ARCHIVE` on old partitions and lighter or no compression on the hot partition. (Applying/rebuilding compression is a maintenance op → `sqlserver-operations`.)

---

## 9. In-Memory OLTP (Memory-Optimized Tables)

In-Memory OLTP keeps table rows in memory with lock-free, latch-free **MVCC (optimistic multi-versioning)** access — eliminating latch/lock hot spots and enabling extreme insert/lookup throughput. Tables require a **memory-optimized filegroup** and at least one index (see `indexing.md` §11 for hash vs. range).

```sql
CREATE TABLE dbo.Session (
    Token   uniqueidentifier NOT NULL,
    UserID  int NOT NULL,
    Expires datetime2 NOT NULL,
    CONSTRAINT PK_Session PRIMARY KEY NONCLUSTERED HASH (Token) WITH (BUCKET_COUNT = 1000000)
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);
```

### Durability
- **`SCHEMA_AND_DATA`** (default) — data is persisted (logged + checkpoint files); survives restart. Use for real OLTP tables.
- **`SCHEMA_ONLY`** — only the schema persists; **data is lost on restart** and writes aren't logged (very fast). Use for transient data: session/cache state, staging/ETL landing zones, ASP.NET-style session tables.

### Natively compiled stored procedures
Compile a proc to native machine code (`WITH NATIVE_COMPILATION, SCHEMABINDING` + an `ATOMIC` block) for the lowest-latency access to memory-optimized tables. They run far faster but have a **restricted T-SQL surface** (limited syntax, no access to disk tables in older versions, must be schema-bound). Use for short, hot, well-defined transactions.

### Use cases & limits
- **Good for:** high-contention OLTP (latch/`PAGELATCH` hot spots), high-velocity ingest, transient session/staging data, replacing tempdb-table contention.
- **Limits/costs:** all data must fit in memory (size carefully + leave headroom; out-of-memory aborts transactions); feature restrictions versus disk tables have narrowed each release but still exist; cross-feature interactions (e.g. with some replication/CDC) vary by version — verify against the target build.

---

## Cross-References
- Clustered-key choice, filtered/covering/columnstore index mechanics, In-Memory index types: `indexing.md`.
- How trusted constraints, type matching, and partition predicates change the *plan*: `query-optimization.md`.
- Type matching to keep predicates SARGable; computed-column indexing patterns: `tsql-development.md` + `query-optimization.md`.
- Compression/rebuild execution, partition-maintenance jobs, history-table maintenance: **`sqlserver-operations`**.
- Ledger / tamper-evidence, encryption of sensitive columns: **`sqlserver-security`**.
