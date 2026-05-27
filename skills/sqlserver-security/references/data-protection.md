# SQL Server Data-Protection Reference (RLS, DDM, Classification, Ledger)

These features sit between authorization and encryption: they control **which rows** a principal sees (RLS), **how values are displayed** (DDM), **how data is labeled** (classification), and **whether the record is tamper-evident** (ledger). Critically, **one of them — Dynamic Data Masking — is NOT a security boundary**; know the difference before relying on any of them.

---

## 1. Row-Level Security (RLS) — 2016+

RLS restricts **which rows** a principal can read or write, enforced by the engine on every query touching the table — so it can't be bypassed by going around a view. It is implemented with:

1. An **inline table-valued function (iTVF)** — the **predicate function** — that returns a row when access is allowed.
2. A **security policy** that binds that function to a table as a **filter** and/or **block** predicate.

### Filter vs Block predicates
| | **FILTER** | **BLOCK** |
|---|---|---|
| Affects | Reads (`SELECT`/`UPDATE`/`DELETE` row visibility) | Writes (`AFTER INSERT/UPDATE`, `BEFORE UPDATE/DELETE`) |
| Effect on disallowed rows | **Silently removed** (no error) | Operation **fails** with an error |
| Use | Hide rows | Prevent inserting/updating rows out of one's allowed set |

### Pattern
```sql
-- 1. Predicate function: schema-bound inline TVF, returns 1 row when allowed
CREATE FUNCTION rls.fn_tenant_predicate(@TenantId int)
RETURNS TABLE WITH SCHEMABINDING AS
RETURN SELECT 1 AS ok
       WHERE @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS int)   -- session pattern
          OR IS_MEMBER('db_owner') = 1;                              -- admin bypass

-- 2. Policy binding it as filter + block on the table's tenant column
CREATE SECURITY POLICY rls.TenantPolicy
ADD FILTER PREDICATE rls.fn_tenant_predicate(TenantId) ON dbo.Orders,
ADD BLOCK  PREDICATE rls.fn_tenant_predicate(TenantId) ON dbo.Orders AFTER INSERT
WITH (STATE = ON);
```

### The SESSION_CONTEXT pattern
For multi-tenant apps where the DB connection is **pooled under one login**, you can't key off `USER_NAME()`. Instead the app sets a per-request value the predicate reads:

```sql
EXEC sp_set_session_context @key = N'TenantId', @value = 42, @read_only = 1;
-- @read_only = 1 prevents later code on the same connection from changing it
```

The predicate compares the row's tenant to `SESSION_CONTEXT('TenantId')`. **Set it `@read_only = 1`** so application code (or injected SQL) can't reassign it mid-session.

### Performance & bypass considerations
- The predicate function runs **for every row scan** — keep it trivial and **indexable**; a complex function or one preventing index seeks tanks performance. The optimizer can push a simple `SESSION_CONTEXT`/equality predicate down to a seek; a function with joins, `EXISTS` subqueries, or scalar UDF calls forces a scan and serializes the plan.
- Index the column the predicate filters on (e.g., `TenantId`), and avoid wrapping it in functions inside the predicate (keep it SARGable).
- RLS is a real boundary, but watch for **inference / side channels**: a unique-constraint violation, divide-by-zero, or error message can reveal that a hidden row exists or its value. Example: inserting a duplicate key fails even when RLS hides the conflicting row, revealing its existence. Design predicates and error handling to avoid leaking.
- `sysadmin` and `db_owner` (and anyone the predicate explicitly exempts via `IS_MEMBER`/`IS_ROLEMEMBER`) bypass RLS — keep those memberships tight.
- An `UPDATE` that moves a row out of the user's visible set needs a **`BLOCK` predicate** (`AFTER UPDATE`) or the row can silently "disappear" from that user; an `INSERT` of a row the user could not later see needs `AFTER INSERT`. Cover all four operations (`AFTER INSERT`, `AFTER UPDATE`, `BEFORE UPDATE`, `BEFORE DELETE`) for a complete write boundary.
- Disable/enable a policy with `ALTER SECURITY POLICY ... WITH (STATE = OFF|ON)`; inspect with `sys.security_policies` and `sys.security_predicates`.

---

## 2. Dynamic Data Masking (DDM) — 2016+

DDM **rewrites column values in query output** for unprivileged users — the stored data is unchanged. It is meant for **casual obfuscation** (e.g., hiding most of an email in a support UI), **not** for protecting regulated data.

### Mask functions
| Function | Example output | Use |
|---|---|---|
| `default()` | `xxxx` / `0` / `1900-01-01` (type-dependent) | Full mask |
| `email()` | `aXXX@XXXX.com` | Email addresses |
| `partial(prefix, padding, suffix)` | `partial(0,"XXX-XX-",4)` -> `XXX-XX-1234` | Show some characters |
| `random(low, high)` | a random number in range | Numeric noise |

```sql
ALTER TABLE dbo.Customers
ALTER COLUMN Email  ADD MASKED WITH (FUNCTION = 'email()');
ALTER TABLE dbo.Customers
ALTER COLUMN SSN    ADD MASKED WITH (FUNCTION = 'partial(0,"XXX-XX-",4)');
```

### DDM is NOT a security boundary
- Any principal with the **`UNMASK`** permission sees plaintext. (`sysadmin`/`db_owner` always do.)
- **Inference attacks** defeat it without `UNMASK`: an unprivileged user can `WHERE SSN = '123-45-6789'`, or `WHERE Salary > 100000`, or `JOIN`/`ORDER BY` the masked column to *deduce* values, because the predicate operates on the **real** data even though the *output* is masked. A `CAST`/computed column can also reveal it. Worked example — brute-force a masked salary with binary search, no `UNMASK` needed:

```sql
-- Output shows 0, but the filter still runs on the REAL value:
SELECT Name, Salary FROM dbo.Emp WHERE Name = 'Alice';            -- Salary displays masked
SELECT 1 WHERE EXISTS (SELECT 1 FROM dbo.Emp
                       WHERE Name = 'Alice' AND Salary > 150000);  -- returns row -> > 150k
-- Repeat narrowing the range to recover the exact value.
```

- Therefore: use DDM to reduce shoulder-surfing/accidental exposure in low-trust display paths. For real protection use **Always Encrypted** (hide from everyone incl. DBA), **column encryption**, or **RLS** (hide whole rows). Inventory masked columns with `sys.masked_columns` (`masking_function` shows the applied mask).

### Granular UNMASK (2022+)
Pre-2022, `UNMASK` was database-wide (all or nothing). **2022+** allows `GRANT UNMASK` at **schema, table, or column** scope, so you can let a role see real values for *some* columns only:
```sql
GRANT UNMASK ON dbo.Customers(Email) TO support_role;   -- 2022+ column-level
```

---

## 3. Data Classification & Sensitivity Labels

SQL Server can **label columns** with sensitivity (e.g., Confidential, GDPR) and information type — metadata that drives auditing, reporting, and (in Azure) policy. It does not restrict access by itself; it powers governance and surfaces what to protect.

```sql
ADD SENSITIVITY CLASSIFICATION TO dbo.Customers.SSN
WITH (LABEL = 'Highly Confidential', INFORMATION_TYPE = 'National ID', RANK = HIGH);

-- Inventory current classifications (read-only)
SELECT OBJECT_SCHEMA_NAME(c.object_id) AS sch, OBJECT_NAME(c.object_id) AS tbl,
       col.name AS column_name, c.label, c.information_type, c.rank_desc
FROM sys.sensitivity_classifications c
JOIN sys.columns col ON c.major_id = col.object_id AND c.minor_id = col.column_id;
```

Classifications integrate with **SQL Server Audit** (the data-sensitivity information appears in audit records) and with **Azure Purview / Defender for SQL** in the cloud. Use them to inventory regulated data and target encryption/masking/RLS where it matters.

---

## 4. Ledger — 2022+

**Ledger** makes tables **cryptographically tamper-evident**: any change (even by a `sysadmin` or someone with direct file access) leaves a verifiable trail, so you can *prove* data wasn't altered. It does not prevent change — it makes undetected change impossible. Two table types:

| Type | Updates/Deletes? | Structure |
|---|---|---|
| **Updatable ledger table** | Allowed, but versioned | The table + a hidden **history table** + a **ledger view** that unions current and historical rows with transaction/sequence metadata |
| **Append-only ledger table** | **Inserts only** (no update/delete) | The table itself is the immutable record (e.g., audit logs) |

```sql
-- Append-only ledger table (immutable insert log)
CREATE TABLE dbo.AccessLog (Id int IDENTITY, UserName sysname, AtUtc datetime2)
WITH (LEDGER = ON (APPEND_ONLY = ON));

-- Updatable ledger table (auto-creates history + ledger view)
CREATE TABLE dbo.Balances (AccountId int PRIMARY KEY, Amount money)
WITH (LEDGER = ON);
```

### Digests & verification
Each transaction is hashed into a **Merkle-tree**; the root is a **database digest**. You periodically generate and externally store digests, then verify the database against them — if anyone tampered with data *or* the history, verification fails.

```sql
-- Generate the current digest (store it in immutable external storage)
EXEC sys.sp_generate_database_ledger_digest;

-- Verify the database against previously saved digests
-- EXEC sys.sp_verify_database_ledger @digests;            -- pass saved digest JSON
-- EXEC sys.sp_verify_database_ledger_from_digest_storage_location @location;  -- from storage
```

- **Automatic digest storage:** configure the database to auto-publish digests to **Azure immutable Blob storage (with immutability policy)** or **Azure Confidential Ledger**, so even a compromised DBA cannot rewrite both the data and its proof.
- **Use cases:** financial/audit records, regulatory attestation, multi-party trust without a blockchain, "prove to an auditor nothing changed."
- **Overhead:** extra storage for history + hashing on writes; updatable ledger tables roughly double row storage over time. Use for data that needs trust, not everything.

Ledger-related metadata: `sys.tables` columns `ledger_type_desc`, `ledger_view_id`; `sys.database_ledger_transactions`; `sys.database_ledger_blocks`.

---

## 5. Which Protective Feature Solves Which Threat

| Threat / requirement | Best feature(s) |
|---|---|
| User should only see *their* rows (multi-tenant, region, dept) | **RLS** (filter + block) |
| Hide values from over-the-shoulder / casual display, low trust | **DDM** (not for regulated data) |
| Hide values even from the DBA / cloud operator | **Always Encrypted** (see `encryption.md`) |
| Protect a few columns with server-side keys | **Cell-level encryption** (see `encryption.md`) |
| Protect files/backups at rest | **TDE** (see `encryption.md`) |
| Prove data wasn't tampered with | **Ledger** (append-only or updatable) |
| Know *where* sensitive data is | **Data classification / sensitivity labels** |
| Record who did what | **SQL Server Audit** (see `hardening-and-auditing.md`) |

**Common mistakes:** using DDM where Always Encrypted/RLS is required; assuming RLS protects against `sysadmin` (it doesn't — they bypass); assuming ledger *prevents* changes (it makes them *detectable*); applying ledger to high-churn tables without budgeting for storage/write overhead.

`scripts/01`–`scripts/06` are diagnostic; RLS/DDM/ledger have no single "audit script" here, but classification and masked columns can be inventoried with the queries above.
