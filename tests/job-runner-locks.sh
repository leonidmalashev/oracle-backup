#!/bin/bash
# Integration tests: no Oracle connection or backup commands are used.
set -euo pipefail

source_runner=${1:-"$(dirname "$0")/../job-runner.sh"}
test_dir=$(mktemp -d)
real_home=$HOME
export HOME="$test_dir/home"
mkdir -p "$HOME"
job="runner-test-$(id -u)-$$"
lock_file="$HOME/.job-runner-locks/$job.lock"
pids=()
cleanup() {
    touch "$test_dir/release"
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    # Remove only this test's known files, after its children have finished.
    rm -f -- "$lock_file" \
        "$test_dir/job-runner.sh" "$test_dir/job-runner.conf" \
        "$test_dir/child.sh" "$test_dir/rman-backup.sh" "$test_dir/job-runner.sh.log" \
        "$test_dir/starts" "$test_dir/release" "$test_dir/finished" \
        "$test_dir/rman-starts" "$test_dir/rman-release" \
        "$test_dir/injected" "$test_dir/target" "$test_dir/child.pid"
    rm -f -- "$HOME/.job-runner-locks/rman-backup.orcl.archivelog.lock" \
        "$HOME/.job-runner-locks/rman-backup.test.archivelog.lock" \
        "$HOME/.job-runner-locks/rman-backup.orcl.database-i0.lock" \
        "$HOME/.job-runner-locks/rman-backup.orcl.maintenance.lock" \
        "$HOME/.job-runner-locks/rman-maintenance.orcl.lock" \
        "$HOME/.job-runner-locks/rman-maintenance.test.lock"
    export HOME=$real_home
    rmdir -- "$test_dir/home/.job-runner-locks" "$test_dir/home" 2>/dev/null || true
    rmdir -- "$test_dir"
}
trap cleanup EXIT
cp -- "$source_runner" "$test_dir/job-runner.sh"
printf '# Test configuration\n' > "$test_dir/job-runner.conf"
cat > "$test_dir/child.sh" <<'CHILD'
#!/bin/bash
set -euo pipefail
test_dir=$1
mode=$2
echo "$$" > "$test_dir/child.pid"
echo start >> "$test_dir/starts"
if [[ $mode == hold ]]; then
    while [[ ! -f "$test_dir/release" ]]; do sleep 0.05; done
fi
touch "$test_dir/finished"
[[ $mode != fail ]] || exit 7
CHILD
chmod 700 "$test_dir/child.sh"
cat > "$test_dir/rman-backup.sh" <<'RMAN_CHILD'
#!/bin/bash
set -euo pipefail
sid=""
task=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --sid=*) sid=${1#*=}; shift ;;
        --task=*) task=${1#*=}; shift ;;
        --base-backup-dir=*|--logs-dir=*) shift ;;
        *) shift ;;
    esac
done
printf '%s %s\n' "$sid" "$task" >> "$TEST_DIR/rman-starts"
while [[ ! -f "$TEST_DIR/rman-release" ]]; do sleep 0.05; done
RMAN_CHILD
chmod 700 "$test_dir/rman-backup.sh"
run_job() {
    bash "$test_dir/job-runner.sh" --logs-dir="$test_dir" \
        --job-name="$job" --job-script=child.sh --job-args="$test_dir $1"
}
run_rman_job() {
    TEST_DIR=$test_dir bash "$test_dir/job-runner.sh" --logs-dir="$test_dir" \
        --job-name=rman --job-script=rman-backup.sh \
        --job-args="--sid=$1 --task=$2 --base-backup-dir=$test_dir --logs-dir=$test_dir"
}
wait_for_file() {
    for ((attempt=0; attempt<200; attempt++)); do
        [[ ! -f $1 ]] || return 0
        sleep 0.05
    done
    echo "FAIL: timed out waiting for $1" >&2
    exit 1
}
bash -n "$test_dir/job-runner.sh"

for ((i=0; i<12; i++)); do
    run_job hold &
    pids+=("$!")
done
wait_for_file "$test_dir/starts"
sleep 1
[[ $(wc -l < "$test_dir/starts") -eq 1 ]]
touch "$test_dir/release"
for pid in "${pids[@]}"; do wait "$pid"; done
pids=()
[[ $(wc -l < "$test_dir/starts") -eq 1 ]]
echo 'PASS: 12 concurrent invocations execute exactly one child'
rm -- "$test_dir/starts" "$test_dir/release" "$test_dir/finished"

for spec in "orcl archivelog" "orcl archivelog" "test archivelog" "orcl database-i0"; do
    run_rman_job $spec &
    pids+=("$!")
done
wait_for_file "$test_dir/rman-starts"
sleep 1
[[ $(wc -l < "$test_dir/rman-starts") -eq 3 ]]
grep -qx 'orcl archivelog' "$test_dir/rman-starts"
grep -qx 'test archivelog' "$test_dir/rman-starts"
grep -qx 'orcl database-i0' "$test_dir/rman-starts"
run_rman_job orcl maintenance &
pids+=("$!")
sleep 1
[[ $(wc -l < "$test_dir/rman-starts") -eq 3 ]]
touch "$test_dir/rman-release"
for pid in "${pids[@]}"; do wait "$pid"; done
pids=()
[[ $(wc -l < "$test_dir/rman-starts") -eq 3 ]]
echo 'PASS: RMAN locks are scoped by SID/task and maintenance excludes concurrent tasks'
rm -- "$test_dir/rman-starts" "$test_dir/rman-release"

if TEST_DIR=$test_dir bash "$test_dir/job-runner.sh" --logs-dir="$test_dir" \
    --job-name=rman --job-script=rman-backup.sh \
    --job-args="--base-backup-dir=$test_dir --logs-dir=$test_dir"; then
    echo 'FAIL: rman-backup job without SID/task was accepted' >&2
    exit 1
fi
echo 'PASS: RMAN jobs require SID and task for locking'

if run_job fail; then
    echo 'FAIL: child error was lost' >&2
    exit 1
else
    [[ $? -eq 7 ]]
fi
run_job quick
[[ $(wc -l < "$test_dir/starts") -eq 2 ]]
grep -Eq 'job-runner\.sh\[[0-9]+\]: start --job-name=' "$test_dir/job-runner.sh.log"
grep -Eq 'job-runner\.sh\[[0-9]+\]: finish --job-name=' "$test_dir/job-runner.sh.log"
! grep -Eq '^[[:space:]]+(lock|script|arguments):' "$test_dir/job-runner.sh.log"
echo 'PASS: child error is preserved and lock is released for the next run'
rm -- "$test_dir/starts" "$test_dir/finished" "$test_dir/job-runner.sh.log"

bash "$test_dir/job-runner.sh" --silent --logs-dir="$test_dir" \
    --job-name="$job" --job-script=child.sh --job-args="$test_dir quick" \
    > "$test_dir/silent.console" 2>&1
grep -Eq 'job-runner\.sh\[[0-9]+\]: start --job-name=' "$test_dir/job-runner.sh.log"
grep -Eq 'job-runner\.sh\[[0-9]+\]: finish --job-name=.*--status=0' "$test_dir/job-runner.sh.log"
if [[ -s $test_dir/silent.console ]]; then
    echo 'FAIL: --silent wrote routine runner messages to the console' >&2
    exit 1
fi
echo 'PASS: --silent keeps console quiet and writes start/finish to the runner log'
rm -- "$test_dir/job-runner.sh.log" "$test_dir/starts" "$test_dir/finished" "$test_dir/silent.console"

bash "$test_dir/job-runner.sh" --dry-run --logs-dir="$test_dir" \
    --job-name="$job" --job-script=child.sh --job-args="$test_dir quick" > "$test_dir/dry-run.out" 2>&1
grep -q 'DRY RUN: would execute:' "$test_dir/dry-run.out"
[[ ! -e $test_dir/starts ]]
[[ ! -e $test_dir/job-runner.sh.log ]]
echo 'PASS: --dry-run shows runner command without starting generic jobs'
rm -- "$test_dir/dry-run.out"

# Start bash directly so the PID below identifies the runner, not a function shell.
bash "$test_dir/job-runner.sh" --logs-dir="$test_dir" \
    --job-name="$job" --job-script=child.sh --job-args="$test_dir hold" &
runner_pid=$!
pids+=("$runner_pid")
wait_for_file "$test_dir/starts"
kill -KILL "$runner_pid"
set +e
wait "$runner_pid" 2>/dev/null
set -e
pids=()
run_job quick
[[ $(wc -l < "$test_dir/starts") -eq 1 ]]
touch "$test_dir/release"
wait_for_file "$test_dir/finished"
# The child may still be closing descriptors after creating the marker.
for ((attempt=0; attempt<200; attempt++)); do
    if flock -n "$lock_file" true; then break; fi
    sleep 0.05
done
flock -n "$lock_file" true
run_job quick
[[ $(wc -l < "$test_dir/starts") -eq 2 ]]
echo 'PASS: child retains lock after runner SIGKILL; lock releases after child exit'

printf 'unchanged\n' > "$test_dir/target"
rm -- "$lock_file"
ln -s "$test_dir/target" "$lock_file"
if run_job quick; then
    echo 'FAIL: symlink lock was accepted' >&2
    exit 1
fi
[[ $(cat "$test_dir/target") == unchanged ]]
echo 'PASS: symlink lock is rejected without modifying its target'
rm -- "$lock_file"

job='../invalid-job-name'
if run_job quick; then
    echo 'FAIL: path traversal job name was accepted' >&2
    exit 1
fi
echo 'PASS: path traversal job name is rejected'
