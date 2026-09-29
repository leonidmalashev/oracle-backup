# Deployment Notes

Production host: `oracle@192.168.56.11`.

Production script directory:

```text
/home/oracle/oracle-backup
```

Backup and log directories remain outside the script directory:

```text
/u01/app/oracle/backups/orcl
/u01/app/oracle/backups/logs
```

The previous script directory `/home/oracle/dba-scripts/oracle-backup` was moved to `/home/oracle/oracle-backup`.

Use only long options. Options with values must use `--option=value` syntax.

Cron-style archivelog example:

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

See `README.md` for usage, logging, locking, dry-run behavior, diagnostics, and tests.

## Last Verified

After moving to `/home/oracle/oracle-backup`, both checks succeeded:

- `--dry-run`: `0`
- real `archivelog` run: `0`

Latest verified RMAN log at the time of the move:

```text
/u01/app/oracle/backups/logs/al_2026-09-28T195149.log
```
