# Disaster Recovery Planning Reference

How to turn business requirements into an HA/DR architecture, and how to execute failover when the time comes. For the individual technologies see `availability-groups.md`, `failover-clustering.md`, `mirroring-endpoints.md`, and `log-shipping-and-replication.md`. **Cloud-managed DR** (Azure SQL auto-failover groups, zone redundancy, RDS Multi-AZ) lives in **`sqlserver-cloud`** — see §7.

## 1. RPO and RTO — The Two Numbers That Drive Everything

| Term | Definition | Question it answers |
|---|---|---|
| **RPO — Recovery Point Objective** | Maximum tolerable **data loss**, expressed as a time window | "How much recent data can we afford to lose?" |
| **RTO — Recovery Time Objective** | Maximum tolerable **downtime** to restore service | "How fast must we be back up?" |

- **RPO = 0** demands **synchronous** replication (sync-commit AG, High-Safety mirroring, FCI's single copy). Any asynchronous technology has RPO > 0 equal to its current lag.
- **Low RTO** demands **automatic failover** (sync AG with automatic mode, FCI on WSFC, mirroring with witness) and pre-warmed standbys; manual/forced failover and restore-from-backup have higher RTO.
- Always capture them **per database/tier** — not every database needs the same numbers. Tier-1 OLTP may need RPO 0 / RTO minutes; an archive DB may accept RPO 24h / RTO a day.

## 2. HA vs DR — Different Problems

| | High Availability (HA) | Disaster Recovery (DR) |
|---|---|---|
| Protects against | Node/instance/OS/disk failure within a site | Loss of a whole site/region |
| Distance | Local (LAN) | Remote (WAN, another region) |
| Failover | Usually **automatic**, seconds–minutes | Usually **deliberate decision**, minutes–hours |
| Typical tech | FCI, sync AG (automatic), mirroring+witness | Async AG, distributed AG, log shipping, cloud failover group |
| Data loss | Zero (synchronous) | Often non-zero (asynchronous) |

You almost always want **both**, layered. A typical enterprise design: **sync AG (or FCI) for local HA** + **async AG replica (or distributed AG / log shipping) in another region for DR**.

## 3. Requirements → Technology Decision Matrix

| Requirement | Recommended technology |
|---|---|
| RPO 0, RTO seconds, local, automatic | **FCI** (instance) or **sync-commit AG with automatic failover** (databases) |
| RPO 0 but need data redundancy + readable copy | **Sync-commit AG** (Enterprise) |
| Cross-region DR, RPO seconds–minutes, RTO minutes | **Async-commit AG replica** in the DR region (manual/forced failover) |
| Cross-region DR across separate clusters / OSes / migrations | **Distributed AG** |
| Cheap DR, version-tolerant, RPO = minutes, manual failover | **Log shipping** |
| Protection against logical corruption / accidental deletes | **Log shipping with delayed restore** (or PITR backups) — sync HA propagates the mistake instantly |
| Single DB HA on Standard Edition | **Basic AG** (2016+) |
| Partial data / writable or differently-shaped reporting target | **Transactional replication** (not HA) |
| Read scale-out, no automatic failover needed | **Read-scale AG** (`CLUSTER_TYPE = NONE`, 2017+) or transactional replication |

### Layering examples
- **Tier-1 OLTP**: sync AG (2 replicas) for HA in primary region + async AG replica in DR region + nightly full/log backups to immutable storage. RPO 0 local, seconds in DR, full PITR archive.
- **FCI + AG**: FCI per site (instance HA, shared storage) + AG across sites (DR, independent copies). See `failover-clustering.md` §6.
- **AG + log shipping**: AG for HA + a delayed-restore log-shipping secondary as a logical-corruption safety net.

## 4. Failover Runbook Template

Keep a per-AG / per-system runbook. The universal shape:

```
1. DETECT
   - Alert fires (sync health, replica down, listener unreachable, site outage).
   - Confirm scope: single replica? whole instance? whole site?
   - Check scripts/01,02 (AG), 03 (mirroring), 05 (cluster), 06 (log shipping).

2. DECIDE  (consult RPO/RTO + current sync state)
   - Is the target replica SYNCHRONIZED?  -> planned/automatic failover, NO data loss.
   - Is it behind / async / primary unreachable?  -> forced failover, ACCEPT data loss.
   - Is this a transient blip that will self-heal?  -> do NOT fail over; let it recover.
   - Get authorization for any data-loss decision.

3. FAIL OVER  (run the correct command for the situation — see §5)

4. VALIDATE
   - New primary is PRIMARY and online; databases ONLINE.
   - Listener / VNN resolves to the new primary; app connects.
   - Sync state of remaining replicas; resume/reseed any that need it.
   - Functional smoke test from the application.

5. FAIL BACK  (when the original site/replica is healthy and caught up)
   - Resync the old primary as a secondary.
   - Plan a *planned* failover back during a maintenance window (no data loss).
```

## 5. Failover Commands by Situation

### Planned / automatic AG failover (no data loss — replica SYNCHRONIZED)
```sql
-- Run on the TARGET secondary (which becomes primary). Sync + SYNCHRONIZED required.
ALTER AVAILABILITY GROUP [AG1] FAILOVER;
```

### Forced AG failover (POSSIBLE DATA LOSS — async or not synchronized)
```sql
-- WARNING: may lose committed transactions. Last resort, used when the primary is gone
-- or the target is not synchronized. Run on the surviving secondary.
ALTER AVAILABILITY GROUP [AG1] FORCE_FAILOVER_ALLOW_DATA_LOSS;
```
After a forced failover:
- The new primary may be **missing transactions** that were committed but not hardened on it → reconcile/replay lost data from logs/backups if possible.
- Other replicas (incl. the old primary, once back) will be in a **SUSPENDED / divergent** state and must be **resumed** (`ALTER DATABASE [db] SET HADR RESUME;`) or, if they diverged past the new primary's LSN, **removed and reseeded**.
- Re-evaluate `required_synchronized_secondaries_to_commit` so commits aren't blocked by the now-degraded topology.

### Mirroring
```sql
-- Planned (sync, no loss), on the principal:
ALTER DATABASE [AppDB] SET PARTNER FAILOVER;
-- Forced (possible data loss), on the mirror:
ALTER DATABASE [AppDB] SET PARTNER FORCE_SERVICE_ALLOW_DATA_LOSS;
```

### FCI
WSFC drives FCI failover (automatic on node/health failure). Manual move: use Failover Cluster Manager or `Move-ClusterGroup`. No data-loss decision — there is a single shared copy.

### Log shipping
Manual: apply outstanding (and, if possible, tail-log) backups, then `RESTORE DATABASE [db] WITH RECOVERY;` and repoint apps (see `log-shipping-and-replication.md` §A6).

## 6. DR Testing Cadence

An untested DR plan is a hope, not a plan.

- **Quarterly (at least)**: execute a *planned* failover of each Tier-1 AG/system during a maintenance window; validate app connectivity, sync resume, and fail back. Time it against RTO.
- **Annually**: full DR drill — fail over to the **DR region**, run the application there, measure actual RPO/RTO, then fail back. Include the people/process (who decides, who executes, comms).
- **On change**: re-test after topology, version, or network changes.
- **Validate backups continuously**: restore-test backups (an AG/cluster does not remove the need for tested backups — see `sqlserver-operations`). Verify `RESTORE VERIFYONLY` and periodic real restores.
- Record actual measured RPO/RTO vs objectives; close gaps.

## 7. Multi-Site, Cross-Region & Cloud DR

- **Multi-subnet / stretched clusters**: configure `RegisterAllProvidersIP`, low `HostRecordTTL`, and `MultiSubnetFailover=True` (see `failover-clustering.md` §5). Manage cross-site quorum votes (zero out DR-site votes so a WAN partition doesn't hand quorum to the wrong side); use a **Cloud Witness** when there's no reliable third site.
- **Cross-region (box product)**: async-commit AG replica or distributed AG in the DR region; expect non-zero RPO equal to lag. Monitor `log_send_queue_size` to keep RPO bounded.
- **Cloud-managed DR — defer to `sqlserver-cloud`**:
  - **Azure SQL Database / Managed Instance**: **auto-failover groups** (geo-replication + automatic listener redirection), **zone-redundant** configurations for in-region HA. The cloud platform manages quorum, witness, and failover — you do **not** build WSFC.
  - **SQL on Azure VM (IaaS)**: this skill's box-product techniques apply (AG/FCI on WSFC); the SQL IaaS extension and Azure Cloud Witness help.
  - **AWS RDS for SQL Server**: **Multi-AZ** uses mirroring/AG under the hood, managed by AWS — you don't run failover commands; AWS does.
  - Do **not** duplicate cloud failover-group setup here — point the user to `sqlserver-cloud`.
