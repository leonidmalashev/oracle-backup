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

- `job-runner.sh` - wrapper for scheduled jobs, locking, signal handling, and cron-friendly logging.
- `rman-backup.sh` - RMAN launcher that generates the RMAN script and runs RMAN.
- `rman-backup.conf` - common RMAN templates and defaults.
- `rman-backup.<sid>.conf` - per-database overrides, for example `rman-backup.orcl.conf`.
- `job-runner.conf` - runner environment settings.
- `tests/` - Linux integration tests with fake RMAN/Oracle tools.

## Command Line Rules

Only long options are supported. Options with values must use `=`:

```bash
--sid=orcl
--task=archivelog
--base-backup-dir=/u01/app/oracle/backups
--logs-dir=/u01/app/oracle/backups/logs
```

The space form is intentionally rejected:

```bash
--sid orcl
```

Short options such as `-s`, `-t`, `-n`, `-j`, `-p`, and `-h` are not supported.

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

Legacy PID files are not used.

## Logs

Wrapper logs:

```text
/u01/app/oracle/backups/logs/job-runner.sh.log
/u01/app/oracle/backups/logs/rman-backup.sh.log
```

The format is syslog-like with `key=value` payloads:

```text
Sep 28 19:40:28 orcl1 rman-backup.sh[39696]: start sid=orcl task=archivelog base_backup_dir=/u01/app/oracle/backups logs_dir=/u01/app/oracle/backups/logs config=./rman-backup.conf sid_config=./rman-backup.orcl.conf
Sep 28 19:40:39 orcl1 rman-backup.sh[39696]: finish sid=orcl task=archivelog status=0 signal=none phase=log-retention
```

Per-RMAN logs are still written as `*.log`, for example:

```text
/u01/app/oracle/backups/logs/al_2026-09-28T195149.log
```

## Diagnostics

Successful real backups do not leave `rman-*` diagnostic directories.

Diagnostics directories are kept only for failures, signals, or cleanup errors. They contain:

- `rman.scr`
- `rman.log`
- `rman.out`
- `status.txt`

`--dry-run` keeps its temporary directory by design.

## Configuration

Common RMAN templates live in `rman-backup.conf`.

Per-database files, such as `rman-backup.orcl.conf`, should contain only overrides: files-per-set, section size, extra RMAN output, or safety switches.

The current production ORCL config keeps initial-deployment safeguards: crosscheck/delete commands are disabled and `DELETE INPUT` is not used.

## Tests

Run on Linux:

```bash
cd /home/oracle/oracle-backup/tests
bash job-runner-locks.sh ../job-runner.sh
bash bash-errors.sh ..
```

The tests use fake RMAN/Oracle tools and do not connect to a database.
