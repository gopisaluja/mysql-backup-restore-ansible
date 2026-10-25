# Monthly restore drill

A backup that has never been restored is an assumption, not a backup. The drill
proves, once a month, that a recent backup can be found, downloaded, verified,
imported, masked and used, and it measures how long that takes (RTO) and how
much data would have been lost (RPO).

The drill uses the same Jenkins job and Ansible roles as a normal developer
restore, so it also exercises the self-service path end to end.

## Targets

Agree on these with the service owners and write them down before the first
drill; the drill tells you whether you meet them.

| Objective | Example target | Measured by |
|-----------|----------------|-------------|
| RPO (max data loss) | 24 h + backup duration | Largest gap between consecutive successful backups in the month, and data age at restore time |
| RTO (time to a usable copy) | 2 h for `app_db` | Approval granted to smoke checks passed |
| Integrity | 100% | SHA-256 verified, table count matches metadata, smoke queries pass |

Daily logical dumps cannot deliver an RPO below roughly 24 hours. If a service
needs better than that, add binary-log shipping or point-in-time recovery; that
is outside the scope of this repository.

## Roles

- **Drill owner** (rotates monthly): runs the drill and writes the record.
- **Approver**: a member of `db-restore-approvers` who is not the drill owner.
- **Service owner**: confirms the restored copy is usable (optional query or app check).

## Procedure

1. **Pick the backup.** Use the newest backup for one database, and at least once
   a quarter pick an *older* one (for example 25-35 days old) so the
   lifecycle-tiered storage class is exercised too.

   ```bash
   aws s3 ls "s3://<bucket>/mysql/prod/app_db/" --recursive | grep '\.meta\.json$' | tail -n 5
   ```

2. **Check the RPO for the month** from the metadata keys: the timestamps are in
   the key names, so the largest gap between consecutive backups is visible
   without downloading anything.

   ```bash
   aws s3 ls "s3://<bucket>/mysql/prod/app_db/$(date -u +%Y/%m)/" --recursive \
     | grep -o '[0-9]\{8\}T[0-9]\{6\}Z' | sort \
     | python3 -c '
   import sys, datetime as dt
   ts = [dt.datetime.strptime(l.strip(), "%Y%m%dT%H%M%SZ") for l in sys.stdin if l.strip()]
   gaps = [(b - a).total_seconds() / 3600 for a, b in zip(ts, ts[1:])]
   print(f"backups={len(ts)} max_gap_h={max(gaps, default=0):.1f}")'
   ```

3. **Restore into the drill environment.** Run `mysql-restore` in Jenkins with:
   - `SOURCE_DB`: the database under test
   - `BACKUP`: `latest` or the chosen date
   - `TARGET_ENV`: `qa` (or a dedicated `drill` environment)
   - `TARGET_DB`: for example `app_db_drill`, so nobody's working copy is replaced
   - `REASON`: `restore drill YYYY-MM`

   Note the time the approval is granted; this is the RTO start.

4. **Let the role verify.** The job fails unless:
   - the artifact's SHA-256 matches the metadata written at backup time;
   - the restored base-table count equals the count recorded at backup time;
   - every `min_rows` and custom smoke query in the database profile passes
     (including the "no unmasked e-mail addresses" check).

5. **Application check (optional, recommended quarterly).** Point a test
   instance of the application at the restored copy and run a read-only
   journey, or have the service owner run a known query.

6. **Collect the numbers.** The archived `artifacts/restore-<host>-<db>.json`
   contains `backup_key`, `backup_created_at`, `duration_seconds`,
   `import_seconds` and `data_age_hours`. RTO = approval time to the job's
   finish time (Jenkins timestamps).

7. **Clean up.** Drop `app_db_drill` (or leave it for the service owner and
   drop it after sign-off).

8. **Record the drill** (below) and open tickets for every deviation.

## Drill record

Keep one row per drill, for example in the team wiki or a `drills/` folder in
the infrastructure repository.

| Date | DB | Backup key | Size | Download (s) | Import + masking (s) | RTO (min) | Max backup gap (h) | Data age at restore (h) | Checks | Issues / follow-ups | Owner |
|------|----|-----------|------|--------------|----------------------|-----------|--------------------|-------------------------|--------|---------------------|-------|
| YYYY-MM-DD | app_db | `mysql/prod/app_db/...meta.json` | 0.0 GiB | | | | | | pass / fail | | |

## What to watch for over time

- **Import time growing faster than data size**: often new secondary indexes or
  large tables without primary keys. Past a certain size a physical
  (XtraBackup) restore becomes the faster option; revisit the trade-off in the
  README.
- **Backup gaps**: a missing day means the backup job failed silently or its
  alert did not reach anyone. Fix alert routing, not just the job.
- **Masking drift**: new PII columns appear with schema changes. The custom
  smoke queries are the place to assert that they are masked.
- **Retrieval surprises**: if the lifecycle policy is changed to GLACIER or
  DEEP_ARCHIVE, older backups need a RestoreObject request first; the drill
  with an old backup will show this immediately.
