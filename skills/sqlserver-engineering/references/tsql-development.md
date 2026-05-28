# T-SQL Development Reference

Idiomatic, correct, set-based T-SQL for SQL Server 2016–2025 and Azure SQL DB/MI. The recurring theme: **let the engine do work in sets, give the optimizer good cardinality, and keep predicates SARGable.**

---

## 1. Set-Based Thinking vs. RBAR (Row-By-Agonizing-Row)

The single biggest T-SQL performance mistake is processing rows one at a time when a set operation would do. Cursors, `WHILE` loops over `@@ROWCOUNT`, and scalar UDFs in SELECT lists all force the engine into row-at-a-time execution.

```sql
-- RBAR: cursor updating each row (slow, log-heavy, lock-churning)
DECLARE c CURSOR FOR SELECT OrderID FROM dbo.Orders WHERE Status = 'New';
-- ... fetch loop, one UPDATE per row ...

-- Set-based: one statement, one plan, one pass
UPDATE dbo.Orders
SET    Status = 'Processing', ModifiedUtc = SYSUTCDATETIME()
WHERE  Status = 'New';
```

### When a cursor is genuinely unavoidable
Some tasks are inherently iterative (calling a per-row stored proc, sequential administrative loops). Make the cursor as cheap as possible:

```sql
DECLARE c CURSOR LOCAL FAST_FORWARD FOR   -- LOCAL + FAST_FORWARD = read-only, forward-only, fastest
    SELECT DatabaseName FROM dbo.MaintenanceList ORDER BY DatabaseName;
```

`FAST_FORWARD` is shorthand for `FORWARD_ONLY READ_ONLY`. Avoid `STATIC` (copies to tempdb), `KEYSET`, and `DYNAMIC` unless you specifically need their semantics. Always `LOCAL` (global cursors leak across the connection).

**Batching as a middle ground:** for huge DML, loop in *set-based batches* (e.g. `UPDATE TOP (5000) ... WHERE ...` until `@@ROWCOUNT = 0`) to bound transaction-log growth, lock duration, and blocking — still set-based within each batch.

---

## 2. EXISTS vs. IN vs. JOIN

- **`EXISTS`** — best for existence checks. Short-circuits on the first match, is NULL-safe, and the optimizer treats it as a semi-join.
- **`IN`** — fine for a small literal list. With a subquery it's usually planned like `EXISTS`, **but** `NOT IN` against a column that can be `NULL` is a trap: a single NULL in the list makes the whole predicate return no rows. Use `NOT EXISTS` instead.
- **`JOIN`** — use when you actually need columns from the other table. A join can *multiply* rows if the join key isn't unique; `EXISTS` never does.

```sql
-- Existence: EXISTS short-circuits, no row multiplication
SELECT c.CustomerID, c.Name
FROM   dbo.Customer AS c
WHERE  EXISTS (SELECT 1 FROM dbo.[Order] AS o WHERE o.CustomerID = c.CustomerID);

-- Anti-join: NOT EXISTS is NULL-safe; NOT IN is NOT
SELECT c.CustomerID
FROM   dbo.Customer AS c
WHERE  NOT EXISTS (SELECT 1 FROM dbo.[Order] AS o WHERE o.CustomerID = c.CustomerID);
-- AVOID: WHERE c.CustomerID NOT IN (SELECT o.CustomerID FROM dbo.[Order] o)  -- wrong if any o.CustomerID IS NULL
```

The convention `SELECT 1` (or `SELECT *`) inside `EXISTS` is identical in cost — the optimizer never materializes the projection.

---

## 3. Error Handling: THROW, TRY/CATCH, Transactions

### THROW vs. RAISERROR
Use **`THROW`** for new code:
- Re-raises the original error number/severity/state when called with no arguments inside `CATCH`.
- Always severity 16, terminates the batch, and is simpler/safer.
- `RAISERROR` is legacy: it can't re-raise the original error verbatim, requires pre-defined messages for `%`-formatting via `sys.messages`, and the `WITH NOWAIT`/`WITH LOG` options are its only remaining niche reasons to use it.

```sql
BEGIN CATCH
    -- Log, then re-raise the exact original error
    THROW;   -- no arguments = re-throw inside CATCH
END CATCH;
```

### The canonical transaction pattern
`SET XACT_ABORT ON` makes most runtime errors abort the *whole* transaction (avoids the half-committed-but-error-swallowed trap). Inside `CATCH`, check `XACT_STATE()` before deciding to roll back:

```sql
SET XACT_ABORT, NOCOUNT ON;
BEGIN TRY
    BEGIN TRANSACTION;
        UPDATE dbo.Account SET Balance = Balance - @amt WHERE AccountID = @from;
        UPDATE dbo.Account SET Balance = Balance + @amt WHERE AccountID = @to;
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    --  1 = active & committable;  -1 = doomed (must roll back); 0 = none
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;   -- re-raise to the caller after cleanup
END CATCH;
```

- `XACT_STATE() = -1` means the transaction is **doomed** (uncommittable) — you can only roll back.
- Without `XACT_ABORT ON`, some errors leave the transaction open and `CATCH` still runs — a leak source. Turn it on.
- `TRY/CATCH` does **not** catch: compile errors in the same batch, severity ≥ 20 (connection dies), or warnings. It also doesn't catch errors raised at severity < 11.

---

## 4. CTEs vs. Temp Tables vs. Table Variables

| Construct | Materialized? | Statistics? | Cardinality estimate | Use for |
|---|---|---|---|---|
| **CTE** (`WITH`) | **No** — inlined into the plan; re-executed per reference | n/a | derived from underlying tables | Readability, recursion, single-reference subqueries |
| **`#temp` table** | Yes (tempdb) | **Yes** (auto + you can index) | accurate | Expensive intermediates read multiple times; large/variable row counts |
| **`@table` variable** | Yes (tempdb) | **No** | **1 row** (legacy) | Tiny, known-small sets; required in functions / for table-valued params |

**CTEs are not a temp table.** A CTE referenced three times is *evaluated three times* — it's pure syntactic sugar (a named inline subquery), not a materialization. If an intermediate result is expensive and read repeatedly, push it into a `#temp` table so it computes once *and* gets statistics:

```sql
-- BAD: the expensive aggregate runs 2x (once per JOIN reference)
WITH Agg AS (SELECT CustomerID, SUM(Amount) AS Total FROM dbo.[Order] GROUP BY CustomerID)
SELECT a1.CustomerID FROM Agg a1 JOIN Agg a2 ON ... ;   -- Agg computed twice

-- GOOD: compute once, then reuse with real statistics
SELECT CustomerID, SUM(Amount) AS Total
INTO   #Agg
FROM   dbo.[Order]
GROUP BY CustomerID;
-- (optionally) CREATE INDEX ix ON #Agg(CustomerID);
SELECT ... FROM #Agg a1 JOIN #Agg a2 ON ... ;
```

**Table-variable cardinality:** the optimizer historically estimates **1 row** for `@table` variables (no statistics), producing nested-loop plans that blow up when the variable actually holds thousands of rows. **2019+ (compat 150) adds table-variable deferred compilation**, which defers the plan until first execution so the *actual* row count is used — a big improvement, but the table variable still has no column statistics. For variable/large sets where the estimate drives the plan, prefer `#temp`. Force a recount on demand with `OPTION (RECOMPILE)` on older compat levels.

---

## 5. Window Functions

Window functions (`OVER(...)`) compute across a set of rows related to the current row *without collapsing them* (unlike `GROUP BY`). They typically beat self-joins and correlated subqueries.

```sql
SELECT
    OrderID, CustomerID, OrderDate, Amount,
    ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY OrderDate)              AS seq,
    RANK()       OVER (PARTITION BY CustomerID ORDER BY Amount DESC)            AS amt_rank,
    LAG(Amount)  OVER (PARTITION BY CustomerID ORDER BY OrderDate)             AS prev_amt,
    LEAD(Amount) OVER (PARTITION BY CustomerID ORDER BY OrderDate)             AS next_amt
FROM dbo.[Order];
```

### Running totals — `ROWS` vs `RANGE` (an important, subtle default)
When you add `ORDER BY` to an aggregate window without specifying a frame, the **default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`**. `RANGE` groups *peer rows* (rows with equal `ORDER BY` values) into the same frame **and uses an on-disk spool**, while `ROWS` is positional and uses a faster in-memory window spool. They also give *different answers* when the order key has ties.

```sql
-- Prefer ROWS for running totals: faster AND avoids the peer-grouping surprise
SELECT OrderDate, Amount,
       SUM(Amount) OVER (ORDER BY OrderDate
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
FROM dbo.[Order];
```

A supporting index on `(PARTITION columns, ORDER BY columns)` lets the engine skip the Sort feeding the window operator. **`STRING_AGG` (2017+)** also supports `WITHIN GROUP (ORDER BY ...)` for ordered concatenation. **The `WINDOW` clause (2022+)** lets you name and reuse a frame definition across multiple functions.

---

## 6. The APPLY Operator

`CROSS APPLY` / `OUTER APPLY` invoke a table expression *per row* of the left input — a correlated join. Essential for:
- **Top-N-per-group** (latest order per customer):
  ```sql
  SELECT c.CustomerID, o.OrderID, o.OrderDate
  FROM   dbo.Customer AS c
  CROSS APPLY (SELECT TOP (1) * FROM dbo.[Order] o
               WHERE o.CustomerID = c.CustomerID
               ORDER BY o.OrderDate DESC) AS o;
  ```
- Calling a **table-valued function** with arguments from each left row.
- Splitting/expanding (`STRING_SPLIT`, `OPENJSON`) per row.

`CROSS APPLY` ≈ inner join (drops left rows with no match); `OUTER APPLY` ≈ left join (keeps them with NULLs). With a supporting index on the inner table, APPLY top-N-per-group is usually far more efficient than `ROW_NUMBER()` filtering the whole set.

---

## 7. MERGE — Use With Caution

`MERGE` does insert/update/delete in one statement, but it has a long history of **bugs and footguns**:
- Documented correctness bugs with concurrent execution, indexed views, foreign keys, and some triggers (several Connect/feedback items over the years).
- Under concurrency it can raise unique-key violations / deadlocks unless you take an explicit `HOLDLOCK`/`SERIALIZABLE` hint on the target — and even then it's easy to get wrong.
- Triggers fire once for the whole statement with mixed actions in `inserted`/`deleted`, surprising people expecting per-action firing.

For high-concurrency **upserts**, an explicit pattern is usually safer and easier to reason about:

```sql
BEGIN TRANSACTION;
    UPDATE t WITH (UPDLOCK, SERIALIZABLE)
    SET    t.Col = s.Col
    FROM   dbo.Target t
    WHERE  t.[Key] = @key;

    IF @@ROWCOUNT = 0
        INSERT dbo.Target ([Key], Col) VALUES (@key, @col);
COMMIT TRANSACTION;
```

Use `MERGE` for batch/ETL set operations where concurrency is controlled; avoid it for hot OLTP upserts.

---

## 8. Scalar UDF Inlining (2019+)

Pre-2019, a scalar UDF in a SELECT/WHERE forces **row-by-row** execution, serializes the plan (no parallelism), and hides its cost from the estimator — a notorious silent killer.

**SQL Server 2019 (compat 150) introduced scalar UDF inlining (FROID):** qualifying scalar UDFs are rewritten into the calling query as a relational expression, so they cost properly and run set-based.

```sql
-- Check whether a function is inlineable
SELECT name, is_inlineable
FROM   sys.sql_modules m
JOIN   sys.objects o ON o.object_id = m.object_id
WHERE  o.type = 'FN';
```

**Inlining is disabled** when the UDF does things like: reference `GETDATE()`/`SYSDATETIME()` in some contexts, use `@@ROWCOUNT`, contain time-dependent or non-deterministic intrinsics, perform aggregation, reference table variables / TVPs, use `EXEC`/dynamic SQL, recursion, or `WITH RECOMPILE`. You can also force-disable per function (`WITH INLINE = OFF`) or per query (`OPTION (USE HINT('DISABLE_TSQL_SCALAR_UDF_INLINING'))`). Even on 2019+, **verify** `is_inlineable = 1` and that the actual plan shows the inlined form — don't assume.

---

## 9. Dynamic SQL — Parameterized and Injection-Safe

Concatenating values into a SQL string is both a **SQL-injection** hole and a **plan-cache-bloat** machine (every literal value gets its own plan). Use `sp_executesql` with **parameters**:

```sql
-- SAFE: parameterized; one cached plan, no injection surface
DECLARE @sql nvarchar(max) = N'
    SELECT OrderID, Amount
    FROM   dbo.[Order]
    WHERE  CustomerID = @CustomerID
      AND  OrderDate >= @Since;';
EXEC sys.sp_executesql @sql,
     N'@CustomerID int, @Since datetime2(0)',
     @CustomerID = @cust, @Since = @since;
```

- Only **values** can be parameters. For dynamic **identifiers** (table/column names), you cannot parameterize — the **primary defense is whitelisting**: validate the requested name against the catalog (`sys.objects` / `sys.schemas` / `sys.columns`) so only a real, permitted object can be used; then wrap with `QUOTENAME()` as defense-in-depth:
  ```sql
  -- Whitelist FIRST: reject anything that isn't a real object the caller is allowed to touch
  IF NOT EXISTS (SELECT 1 FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
                 WHERE s.name = @schema AND o.name = @table AND o.type = 'U')
      THROW 50000, N'Unknown or disallowed table.', 1;

  SET @sql = N'SELECT * FROM ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table) + N' WHERE ...';
  ```
- **`QUOTENAME()` gotcha:** its input is `sysname` (`nvarchar(128)`), so an identifier **longer than 128 characters returns `NULL`** — silently collapsing your whole dynamic string to `NULL` (and, if an attacker supplies a 129+ char string, bypassing the bracket-escaping you relied on). Whitelisting against the catalog closes that hole, because real object names are ≤ 128 chars.
- Never build predicates by string-concatenating user input. **Whitelisting** is the real defense for identifiers; `QUOTENAME` is a wrapper, not a guarantee; `sp_executesql` parameters defend values.

---

## 10. Version-Gated T-SQL Functions

Confirm the **engine version** *and* often the **compatibility level** before using these. (Many ship with the engine but are good to gate when targeting mixed estates.)

| Function / Feature | First version | Notes |
|---|---|---|
| `STRING_SPLIT` (no ordinal) | 2016 | `enable_ordinal` argument added in **2022** |
| `STRING_AGG` | 2017 | Ordered concat via `WITHIN GROUP (ORDER BY ...)` |
| `TRIM` | 2017 | Leading+trailing; `LEADING/TRAILING/BOTH ... FROM` syntax extended in 2022 |
| `CONCAT_WS` | 2017 | Concatenate with separator, skips NULLs |
| `TRANSLATE` | 2017 | Multi-character replace |
| `APPROX_COUNT_DISTINCT` | 2019 | HyperLogLog approximate distinct (IQP) |
| `GREATEST` / `LEAST` | 2022 | Row-wise max/min across columns |
| `GENERATE_SERIES` | 2022 | Set-returning integer/numeric series (great for numbers tables) |
| `DATE_BUCKET` / `DATETRUNC` | 2022 | Bucketing / truncation to a date part |
| `IS [NOT] DISTINCT FROM` | 2022 | NULL-safe equality predicate (SARGable) |
| `STRING_SPLIT(..., sep, 1)` ordinal | 2022 | Returns an `ordinal` column to preserve order |
| `WINDOW` clause | 2022 | Named, reusable window frame definitions |
| `REGEXP_LIKE` / `REGEXP_REPLACE` / `REGEXP_SUBSTR` / `REGEXP_COUNT` / `REGEXP_INSTR` | 2025 | Native regular expressions |
| Native `json` type + `JSON_OBJECT`/`JSON_ARRAY`/`JSON_OBJECTAGG`/`JSON_ARRAYAGG` & JSON index | 2025 | First-class JSON storage/indexing (the constructors `JSON_OBJECT`/`JSON_ARRAY` themselves are 2022) |
| `vector` type + `VECTOR_DISTANCE` / DiskANN | 2025 | Native vector storage & similarity search |

**Azure SQL DB/MI** generally receive these functions *before or alongside* the box product — when in doubt on Azure, test, since the PaaS surface tracks the latest engine.

---

## Cross-References
- Plan-level consequences of these patterns (estimates, recompiles, sniffing): `query-optimization.md`.
- Indexes that make these patterns seek instead of scan: `indexing.md`.
- Type choices that keep predicates SARGable: `schema-design.md`.
- Live blocking/deadlocks caused by long transactions or cursors: **`sqlserver-monitoring`**.
