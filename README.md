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

Both scripts support `--version` and print the revision embedded when installed from a Git archive.

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
  --logs-dir=/u01/app/oracle/backups/logs \
  --job-script=rman-backup.sh \
  --job-args="--sid=orcl --task=archivelog --base-backup-dir=/u01/app/oracle/backups --logs-dir=/u01/app/oracle/backups/logs"

./job-runner.sh \
  --silent \
  --job-name=orcl-database-i0 \
  --logs-dir=/u01/app/oracle/backups/logs \
  --job-script=rman-backup.sh \
  --job-args="--sid=orcl --task=database-i0 --base-backup-dir=/u01/app/oracle/backups --logs-dir=/u01/app/oracle/backups/logs"
```

`--silent` keeps routine output off the console. Successful start/end records and errors are still written to the wrapper logs.

Cron Example:
```sh
10 */1 * *  * $HOME/oracle-backup/job-runner.sh --silent --job-name=icsad-archivelog --logs-dir=/ORABACKUP/ICSAD/logs --job-script=rman-backup.sh --job-args="--sid=ICSAD --task=archivelog --base-backup-dir=/ORABACKUP/ICSAD --logs-dir=/ORABACKUP/ICSAD/logs"
30 21 * *  5 $HOME/oracle-backup/job-runner.sh --silent --job-name=icsad-database-i0 --logs-dir=/ORABACKUP/ICSAD/logs --job-script=rman-backup.sh --job-args="--sid=ICSAD --task=database-i0 --base-backup-dir=/ORABACKUP/ICSAD --logs-dir=/ORABACKUP/ICSAD/logs"
```

## Dry Run

`--dry-run` prints the command and generated RMAN script without running RMAN or deleting files.

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
