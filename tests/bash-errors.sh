#!/bin/bash
# Integration tests with a fake oraenv/RMAN. No Oracle database is accessed.
set -euo pipefail
project_dir=$(cd -- "${1:-$(dirname "$0")/..}" && pwd)
test_dir=$(mktemp -d /tmp/oracle-bash-test.XXXXXXXX)
real_home=$HOME
export HOME="$test_dir/home"
mkdir -p "$HOME"
active_pid=""
job="bash-errors-$(id -u)-$$"
cleanup() {
    if [[ -n $active_pid ]]; then
        kill -TERM "$active_pid" 2>/dev/null || true
        wait "$active_pid" 2>/dev/null || true
    fi
    export HOME=$real_home
    if [[ -d $test_dir && ! -L $test_dir && $test_dir == /tmp/oracle-bash-test.* ]]; then
        rm -rf -- "$test_dir"
    fi
}
trap cleanup EXIT
scripts="$test_dir/scripts with spaces"
mkdir -p "$scripts" "$test_dir/bin" "$test_dir/oracle home/bin" "$test_dir/temp files"
cp -- "$project_dir/job-runner.sh" "$project_dir/rman-backup.sh" \
    "$project_dir/rman-backup.conf" "$project_dir/rman-backup.orcl.conf" "$scripts/"
printf '# Test configuration\n' > "$scripts/job-runner.conf"
cat > "$test_dir/bin/oraenv" <<'ORAENV'
# Deliberately inspect an unset variable, like third-party environment scripts.
unused=$ORACLE_ENV_UNSET_TEST
export ORACLE_HOME="$MOCK_ORACLE_HOME"
ORAENV
cat > "$test_dir/oracle home/bin/rman" <<'RMAN'
#!/bin/bash
set -euo pipefail
[[ $# -eq 4 && $1 == nocatalog && $2 == log && $4 == @* ]]
cp -- "${4#@}" "$TEST_ROOT/generated.rman"
if [[ $TEST_MODE != no-log ]]; then printf 'RMAN test log\n' > "$3"; fi
printf 'mock stdout\n'
printf 'mock stderr\n' >&2
case $TEST_MODE in
    success) exit 0 ;;
    fail) exit 17 ;;
    no-log) exit 23 ;;
    hold)
        trap 'sleep 0.2; touch "$TEST_ROOT/stopped"; exit 143' TERM
        echo "$$" > "$TEST_ROOT/rman.pid"
        while :; do sleep 0.05; done
        ;;
esac
RMAN
cat > "$scripts/args.sh" <<'ARGS_SCRIPT'
#!/bin/bash
printf '%s\0' "$@" > "$TEST_ROOT/args.bin"
ARGS_SCRIPT
chmod 700 "$scripts/rman-backup.sh" "$scripts/args.sh" "$test_dir/oracle home/bin/rman"
export TEST_ROOT="$test_dir" MOCK_ORACLE_HOME="$test_dir/oracle home" TEST_MODE=success
export PATH="$test_dir/bin:$PATH" TMPDIR="$test_dir/temp files"
unset ORACLE_ENV_UNSET_TEST

expect_status() {
    local expected=$1 status=0
    shift
    "$@" > "$test_dir/console" 2>&1 || status=$?
    if [[ $status -ne $expected ]]; then
        cat "$test_dir/console" >&2
        printf 'FAIL: expected %s, got %s\n' "$expected" "$status" >&2
        exit 1
    fi
}
expect_ok() {
    "$@" > "$test_dir/console" 2>&1
}
assert_temp_empty() {
    [[ -z $(find "$TMPDIR" -mindepth 1 -print -quit) ]]
}
wait_for_rman() {
    for ((attempt=0; attempt<200; attempt++)); do
        [[ ! -f $test_dir/rman.pid ]] || return 0
        sleep 0.05
    done
    echo 'FAIL: RMAN mock did not start' >&2
    exit 1
}
assert_diagnostics() {
    local logs=$1 status=$2 signal=${3:-none} directory
    saved_diagnostics=""
    for directory in "$logs"/rman-*; do
        [[ -f $directory/status.txt ]] || continue
        if grep -qx "exit_status=$status" "$directory/status.txt" && \
           grep -qx "signal=$signal" "$directory/status.txt"; then
            saved_diagnostics=$directory
        fi
    done
    [[ -n $saved_diagnostics ]]
}
assert_no_diagnostics() {
    local logs=$1
    [[ -z $(find "$logs" -mindepth 1 -maxdepth 1 -type d -name 'rman-*' -print -quit 2>/dev/null) ]]
}
run_rman() {
    bash "$scripts/rman-backup.sh" --sid=orcl --task="$1" \
        --logs-dir="$test_dir/logs $1" --base-backup-dir="$test_dir/backup files"
}

for option in --sid --task --base-backup-dir --logs-dir; do
    expect_status 2 bash "$scripts/rman-backup.sh" "$option"
    ! grep -q 'unbound variable' "$test_dir/console"
done
for option in --job-name --job-script --job-args --logs-dir; do
    expect_status 2 bash "$scripts/job-runner.sh" "$option"
    ! grep -q 'unbound variable' "$test_dir/console"
done
expect_status 2 bash "$scripts/rman-backup.sh"
expect_status 2 bash "$scripts/job-runner.sh"
expect_status 2 bash "$scripts/rman-backup.sh" unexpected
expect_status 2 bash "$scripts/job-runner.sh" unexpected
expect_ok bash "$scripts/rman-backup.sh" --help
grep -q -- '--dry-run' "$test_dir/console"
! grep -q 'RMAN job finished' "$test_dir/console"
expect_ok bash "$scripts/job-runner.sh" --help
grep -q -- '--dry-run' "$test_dir/console"
for option in -s -t -v -h; do
    expect_status 2 bash "$scripts/rman-backup.sh" "$option"
done
for option in -n -j -p -v -h; do
    expect_status 2 bash "$scripts/job-runner.sh" "$option"
done
echo 'PASS: short options are rejected'
echo 'PASS: missing options and values report errors without unbound variables'

for task in database-i0 database-i1 archivelog maintenance restore_validate; do
    run_rman "$task"
    grep -q 'CONNECT TARGET /' "$test_dir/generated.rman"
    case $task in
        database-i0) grep -q 'INCREMENTAL LEVEL = 0' "$test_dir/generated.rman" ;;
        database-i1) grep -q 'INCREMENTAL LEVEL = 1' "$test_dir/generated.rman" ;;
        archivelog)
            grep -q 'NOT BACKED UP 1 TIMES' "$test_dir/generated.rman"
            grep -Eq 'DELETE ALL INPUT;$' "$test_dir/generated.rman"
            ! grep -Eq 'CROSSCHECK|DELETE NOPROMPT EXPIRED|DELETE NOPROMPT OBSOLETE' "$test_dir/generated.rman"
            ;;
        maintenance)
            grep -q 'CROSSCHECK BACKUP;' "$test_dir/generated.rman"
            grep -q 'CROSSCHECK ARCHIVELOG ALL;' "$test_dir/generated.rman"
            grep -q 'DELETE NOPROMPT EXPIRED BACKUP;' "$test_dir/generated.rman"
            grep -q 'DELETE NOPROMPT EXPIRED ARCHIVELOG ALL;' "$test_dir/generated.rman"
            ;;
        restore_validate) grep -q 'RESTORE DATABASE VALIDATE;' "$test_dir/generated.rman" ;;
    esac
    if [[ $task == database-i0 || $task == database-i1 ]]; then
        grep -q 'DELETE NOPROMPT OBSOLETE;' "$test_dir/generated.rman"
        ! grep -Eq 'CROSSCHECK|DELETE NOPROMPT EXPIRED' "$test_dir/generated.rman"
    fi
    assert_temp_empty
    assert_no_diagnostics "$test_dir/logs $task"
    find "$test_dir/logs $task" -mindepth 1 -maxdepth 1 -type f -name '*.log' -print -quit | grep -q .
    grep -Eq 'rman-backup\.sh\[[0-9]+\]: start sid=' "$test_dir/logs $task/rman-backup.sh.log"
    grep -Eq 'rman-backup\.sh\[[0-9]+\]: finish sid=' "$test_dir/logs $task/rman-backup.sh.log"
    ! grep -Eq '^(Backup Config|SID Backup Config|ORACLE_SID|Base Backups Directory|Logs Directory|Task:|[0-9].*Begin RMAN Job|[0-9].*End RMAN Job)' \
        "$test_dir/logs $task/rman-backup.sh.log"
done
echo 'PASS: all five tasks support spaces and new log directories; temp files are cleaned'

silent_logs="$test_dir/silent logs"
bash "$scripts/rman-backup.sh" --silent --sid=orcl --task=archivelog \
    --logs-dir="$silent_logs" --base-backup-dir="$test_dir/silent backups" \
    > "$test_dir/silent.console" 2>&1
grep -Eq 'rman-backup\.sh\[[0-9]+\]: start sid=orcl task=archivelog' \
    "$silent_logs/rman-backup.sh.log"
grep -Eq 'rman-backup\.sh\[[0-9]+\]: finish sid=orcl task=archivelog status=0 .*duration=[0-9]+s' \
    "$silent_logs/rman-backup.sh.log"
[[ ! -s $test_dir/silent.console ]]
if grep -Eq 'Backup Config|SID Backup Config|ORACLE_SID|Begin RMAN Job|End RMAN Job|RMAN job finished|Diagnostics saved' \
    "$silent_logs/rman-backup.sh.log"; then
    echo 'FAIL: --silent wrote console-only RMAN messages' >&2
    exit 1
fi
assert_temp_empty
assert_no_diagnostics "$silent_logs"
echo 'PASS: --silent keeps console quiet and writes start/finish to the RMAN wrapper log'

rm -f -- "$test_dir/generated.rman"
dry_logs="$test_dir/dry logs"
dry_backups="$test_dir/dry backups"
bash "$scripts/rman-backup.sh" --dry-run --sid=orcl --task=archivelog \
    --logs-dir="$dry_logs" --base-backup-dir="$dry_backups" > "$test_dir/dry-run.out" 2>&1
grep -q 'DRY RUN: would execute:' "$test_dir/dry-run.out"
grep -q 'BACKUP AS COMPRESSED BACKUPSET ARCHIVELOG ALL' "$test_dir/dry-run.out"
[[ ! -e $test_dir/generated.rman ]]
[[ ! -e $dry_logs/rman-backup.sh.log ]]
dry_temp=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -name 'rman.*' -print -quit)
[[ -n $dry_temp && -f $dry_temp/rman.scr ]]
rm -rf -- "$dry_temp"
assert_temp_empty
echo 'PASS: --dry-run shows RMAN command/script without running RMAN or cleanup deletes'

arg_string=$(cat <<'ARG_STRING'
alpha "two words" '' escaped\ space '*' '$(touch injected)' "$HOME" "quote: \"yes\""
ARG_STRING
)
bash "$scripts/job-runner.sh" --job-name="$job" --job-script=args.sh --job-args="$arg_string" --logs-dir="$test_dir/new runner logs"
mapfile -d '' -t actual < "$test_dir/args.bin"
expected=(alpha 'two words' '' 'escaped space' '*' '$(touch injected)' '$HOME' 'quote: "yes"')
[[ ${#actual[@]} -eq ${#expected[@]} ]]
for i in "${!expected[@]}"; do [[ ${actual[i]} == "${expected[i]}" ]]; done
for invalid in '"unclosed' "'unclosed" 'trailing\'; do
    expect_status 2 bash "$scripts/job-runner.sh" --job-name="$job" --job-script=args.sh --job-args="$invalid" --logs-dir="$test_dir/new runner logs"
done
echo 'PASS: --job-args handles quotes/escapes/empty args without expansions'

TEST_MODE=fail
expect_status 17 run_rman archivelog
grep -q 'mock stdout' "$test_dir/logs archivelog/rman-backup.sh.log"
grep -q 'mock stderr' "$test_dir/logs archivelog/rman-backup.sh.log"
assert_temp_empty
assert_diagnostics "$test_dir/logs archivelog" 17
grep -q 'mock stderr' "$saved_diagnostics/rman.out"
TEST_MODE=no-log
expect_status 23 run_rman archivelog
assert_temp_empty
assert_diagnostics "$test_dir/logs archivelog" 23
[[ -f $saved_diagnostics/rman.scr && ! -f $saved_diagnostics/rman.log ]]
grep -q 'mock stdout' "$saved_diagnostics/rman.out"
echo 'PASS: failure codes and both output streams survive, even without an RMAN log'

TEST_MODE=success
printf '\ncreate_rman_backup_archivelog_script() { echo partial-script > "$1"; return 19; }\n' >> "$scripts/rman-backup.orcl.conf"
expect_status 19 run_rman archivelog
assert_temp_empty
assert_diagnostics "$test_dir/logs archivelog" 19
grep -q 'partial-script' "$saved_diagnostics/rman.scr"
grep -q '^error_line=[0-9]' "$saved_diagnostics/status.txt"
cp -- "$project_dir/rman-backup.orcl.conf" "$scripts/rman-backup.orcl.conf"
echo 'PASS: generation errors retain their status and trigger cleanup'

TEST_MODE=hold
for signal in TERM HUP; do
    bash "$scripts/rman-backup.sh" --sid=orcl --task=archivelog \
        --logs-dir="$test_dir/signal logs" --base-backup-dir="$test_dir/backup files" &
    active_pid=$!
    wait_for_rman
    kill -"$signal" "$active_pid"
    result=0
    wait "$active_pid" || result=$?
    active_pid=""
    if [[ $signal == TERM ]]; then [[ $result -eq 143 ]]; else [[ $result -eq 129 ]]; fi
    [[ -f $test_dir/stopped ]]
    ! kill -0 "$(cat "$test_dir/rman.pid")" 2>/dev/null
    assert_temp_empty
    assert_diagnostics "$test_dir/signal logs" "$result" "$signal"
    grep -q 'mock stderr' "$saved_diagnostics/rman.out"
    rm -- "$test_dir/rman.pid" "$test_dir/stopped"
done
echo 'PASS: TERM/HUP stop RMAN, preserve signal exit codes and clean temporary files'

# Run in the foreground: asynchronous Bash commands can inherit ignored SIGINT.
expect_status 130 timeout --foreground --preserve-status --signal=INT 1 \
    bash "$scripts/rman-backup.sh" --sid=orcl --task=archivelog \
    --logs-dir="$test_dir/int logs" --base-backup-dir="$test_dir/backup files"
[[ -f $test_dir/stopped ]]
assert_temp_empty
assert_diagnostics "$test_dir/int logs" 130 INT
grep -q 'mock stderr' "$saved_diagnostics/rman.out"
rm -- "$test_dir/rman.pid" "$test_dir/stopped"
echo 'PASS: SIGINT preserves diagnostics and exits 130 after child termination'

job_string="--sid=orcl --task=archivelog --logs-dir='$test_dir/chain logs' --base-backup-dir='$test_dir/backup files'"
bash "$scripts/job-runner.sh" --job-name="$job" --job-script=rman-backup.sh --job-args="$job_string" --logs-dir="$test_dir/chain logs" &
active_pid=$!
wait_for_rman
kill -TERM "$active_pid"
result=0
wait "$active_pid" || result=$?
active_pid=""
[[ $result -eq 143 && -f $test_dir/stopped ]]
! kill -0 "$(cat "$test_dir/rman.pid")" 2>/dev/null
assert_temp_empty
flock -n "$HOME/.job-runner-locks/rman-backup.orcl.archivelog.lock" true
echo 'PASS: runner forwards termination through to RMAN and releases the lock only after exit'

# Simulate an archive write error, including after a successful RMAN operation.
cat > "$test_dir/bin/cp" <<'COPY'
#!/bin/bash
if [[ ${TEST_COPY_FAILURE:-0} == 1 ]]; then
    for argument in "$@"; do
        if [[ $argument == *'/rman-'* || $argument == *'logs archivelog/'*.log ]]; then exit 74; fi
    done
fi
exec /bin/cp "$@"
COPY
chmod 700 "$test_dir/bin/cp"
export TEST_COPY_FAILURE=1
for mode in fail success; do
    TEST_MODE=$mode
    if [[ $mode == fail ]]; then expected_status=17; else expected_status=74; fi
    expect_status "$expected_status" run_rman archivelog
    retained=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d)
    [[ -n $retained && -f $retained/rman.scr && -f $retained/rman.log && -f $retained/rman.out ]]
    grep -q 'mock stderr' "$retained/rman.out"
    grep -Fq "retained temporary files: $retained" "$test_dir/logs archivelog/rman-backup.sh.log"
    rm -- "$retained/rman.scr" "$retained/rman.log" "$retained/rman.out"
    rmdir -- "$retained"
done
TEST_MODE=hold
rm -f -- "$test_dir/rman.pid" "$test_dir/stopped"
bash "$scripts/rman-backup.sh" --sid=orcl --task=archivelog \
    --logs-dir="$test_dir/signal archive failure" --base-backup-dir="$test_dir/backup files" &
active_pid=$!
wait_for_rman
kill -TERM "$active_pid"
result=0
wait "$active_pid" || result=$?
active_pid=""
[[ $result -eq 143 && -f $test_dir/stopped ]]
retained=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d)
[[ -n $retained && -f $retained/rman.scr && -f $retained/rman.log && -f $retained/rman.out ]]
rm -- "$retained/rman.scr" "$retained/rman.log" "$retained/rman.out"
rmdir -- "$retained"
unset TEST_COPY_FAILURE
echo 'PASS: archive failures retain all original files and preserve failure/signal precedence'

TEST_MODE=success
mapfile -t archives_before < <(find "$test_dir/logs archivelog" -mindepth 1 -maxdepth 1 -type d -name 'rman-*')
run_rman archivelog
run_rman archivelog
mapfile -t archives < <(find "$test_dir/logs archivelog" -mindepth 1 -maxdepth 1 -type d -name 'rman-*')
[[ ${#archives[@]} -eq ${#archives_before[@]} ]]
assert_temp_empty
echo 'PASS: successful repeated jobs do not leave diagnostics directories'
