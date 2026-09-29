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

- `rman-backup.sh` - RMAN launcher that generates the RMAN script and runs RMAN.
- `rman-backup.conf` - common RMAN templates and defaults.
- `rman-backup.<sid>.conf` - per-database overrides, for example `rman-backup.orcl.conf`.
- `job-runner.sh` - wrapper for scheduled jobs, locking, signal handling, and cron-friendly logging.
- `job-runner.conf` - runner environment settings.

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
- `restore_validate`

## Direct RMAN Wrapper Usage

```bash
cd /home/oracle/oracle-backup
./rman-backup.sh \
  --sid=orcl \
  --task=archivelog \
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

`--silent` suppresses routine success messages in wrapper logs. Errors are still logged.

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

After a successful database or archivelog backup, RMAN removes obsolete backup sets and archived logs using the target database's current retention policy.

To use an explicit recovery window for this cleanup, set it in the per-database config, for example:

```bash
RMAN_OBSOLETE_RECOVERY_WINDOW_DAYS=30
```

The value must be a positive whole number. When set, it overrides the database's configured policy for that `DELETE OBSOLETE` command, so choose a window that matches the required recovery period. The script does not use `DELETE INPUT`: archived logs are kept until RMAN determines they are no longer needed by the active policy. Crosscheck and expired-record cleanup run before backup; `DELETE OBSOLETE` runs after backup. Common RMAN templates live in `rman-backup.conf`, and per-database files such as `rman-backup.orcl.conf` contain overrides.

## Tests

Run on Linux:

```bash
cd /home/oracle/oracle-backup/tests
bash job-runner-locks.sh ../job-runner.sh
bash bash-errors.sh ..
```

The tests use fake RMAN/Oracle tools and do not connect to a database.
