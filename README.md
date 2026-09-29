# Oracle RMAN Backup Scripts

Bash scripts for Oracle RMAN backups on the Oracle host.

Production script directory:

```text
/home/oracle/oracle-backup
```

Backup files and logs stay outside the script directory:

```text
/u01/app/oracle/backups/orcl
/u01/app/oracle/backups/logs
```

## Files

- `rman-backup.sh`         - RMAN launcher that generates the RMAN script and runs RMAN.
- `rman-backup.conf`       - common RMAN templates and defaults.
- `rman-backup.<sid>.conf` - per-database overrides, for example `rman-backup.orcl.conf`.
- `job-runner.sh`          - wrapper for scheduled jobs, locking, signal handling, and cron-friendly logging.
- `job-runner.conf`        - runner environment settings.

## Command Line Rules

```bash
--sid=orcl
--task=archivelog
--base-backup-dir=/u01/app/oracle/backups
--logs-dir=/u01/app/oracle/backups/logs
```

## Tasks

Supported RMAN tasks:

- `database-i0`
- `database-i1`
- `archivelog`
- `maintenance` (optional repository crosscheck and expired-record cleanup)
- `restore_validate`

## Direct RMAN Wrapper Usage

```bash
cd /home/oracle/oracle-backup

./rman-backup.sh \
  --sid=orcl \
  --task=archivelog \
  --base-backup-dir=/u01/app/oracle/backups \
  --logs-dir=/u01/app/oracle/backups/logs

./rman-backup.sh \
  --sid=orcl \
  --task=database-i0 \
  --base-backup-dir=/u01/app/oracle/backups \
  --logs-dir=/u01/app/oracle/backups/logs

./rman-backup.sh \
  --sid=orcl \
  --task=maintenance \
  --base-backup-dir=/u01/app/oracle/backups \
  --logs-dir=/u01/app/oracle/backups/logs

./rman-backup.sh \
  --sid=orcl \
  --task=restore_validate \
  --base-backup-dir=/u01/app/oracle/backups \
  --logs-dir=/u01/app/oracle/backups/logs
```

## Scheduled/Cron Usage

Use `job-runner.sh` for cron. It applies locking and forwards signals to the child process.

```bash
cd /home/oracle/oracle-backup

./job-runner.sh \
  --silent \
  --job-name=orcl-archivelog \
  --job-script=rman-backup.sh \
  --job-args="--sid=orcl --task=archivelog --base-backup-dir=/u01/app/oracle/backups --logs-dir=/u01/app/oracle/backups/logs" \
  --logs-dir=/u01/app/oracle/backups/logs

./job-runner.sh \
  --silent \
  --job-name=orcl-database-i0 \
  --job-script=rman-backup.sh \
  --job-args="--sid=orcl --task=database-i0 --base-backup-dir=/u01/app/oracle/backups --logs-dir=/u01/app/oracle/backups/logs" \
  --logs-dir=/u01/app/oracle/backups/logs
```

`--silent` keeps routine output off the console. Successful start/end records and errors are still written to the wrapper logs.

## Dry Run

`--dry-run` prints the command and generated RMAN script without running RMAN or deleting files.

```bash
cd /home/oracle/oracle-backup
./job-runner.sh \
  --dry-run \
  --job-name=orcl-archivelog \
  --job-script=rman-backup.sh \
  --job-args="--sid=orcl --task=archivelog --base-backup-dir=/u01/app/oracle/backups --logs-dir=/u01/app/oracle/backups/logs" \
  --logs-dir=/u01/app/oracle/backups/logs
```

Dry-run temporary files are intentionally retained so the generated RMAN script can be inspected.

## Locking

`job-runner.sh` uses `flock` and stores lock files in:

```text
$HOME/.job-runner-locks
```

For `rman-backup.sh`, the lock key is derived from SID and task:

```text
rman-backup.<SID>.<task>
```

This means:

- the same `SID + task` does not run twice at the same time;
- different SIDs can run in parallel;
- different tasks for the same SID can run in parallel.
- the optional `maintenance` task takes an exclusive lock for that SID and waits until its RMAN jobs are finished.

## Logs

Wrapper logs:

```text
job-runner.sh.log
rman-backup.sh.log
```

Per-RMAN logs are still written as `*.log`, for example:

```text
al_2026-09-28T195149.log
```

## Diagnostics

Diagnostics directories are kept only for failures, signals, or cleanup errors. They contain:

- `rman.scr`
- `rman.log`
- `rman.out`
- `status.txt`

`--dry-run` keeps its temporary directory by design.

## Retention and Cleanup

After a successful database backup, `DELETE OBSOLETE` removes backup sets that are no longer needed under the target database's configured RMAN retention policy. The script does not change that policy. Configure it once per database in RMAN, for example `CONFIGURE RETENTION POLICY TO REDUNDANCY 1;` or `CONFIGURE RETENTION POLICY TO REDUNDANCY 2;`.

Archivelog jobs only back up logs not already backed up and then run `DELETE INPUT`. They do not crosscheck files or delete expired records or obsolete backups. RMAN removes each source archive log only after its backup succeeds and the configured archived-log deletion policy allows deletion. This lets frequent archivelog jobs free space without deleting a log before it is backed up. With multiple archive destinations, `DELETE INPUT` removes the copy used for the backup; use `DELETE ALL INPUT` only if every destination copy should be removed.

Database `i0/i1` jobs do not crosscheck files or remove expired records; they run `DELETE OBSOLETE` after the backup according to the configured redundancy policy. Run the optional maintenance task separately when you want to crosscheck backup and archive-log files and remove expired repository records:

```bash
./job-runner.sh \
  --job-name=orcl-rman-maintenance \
  --job-script=rman-backup.sh \
  --job-args="--sid=orcl --task=maintenance --base-backup-dir=/u01/app/oracle/backups --logs-dir=/u01/app/oracle/backups/logs" \
  --logs-dir=/u01/app/oracle/backups/logs
```

The maintenance task takes an exclusive lock for the SID, so it will not overlap a backup or archivelog job for that database. Common RMAN templates live in `rman-backup.conf`, and per-database files such as `rman-backup.orcl.conf` contain overrides.

## Tests

Run on Linux:

```bash
cd /home/oracle/oracle-backup/tests
bash job-runner-locks.sh ../job-runner.sh
bash bash-errors.sh ..
```

The tests use fake RMAN/Oracle tools and do not connect to a database.
