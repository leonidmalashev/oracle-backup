#!/bin/bash
# --
# job-runner.sh - ?????? ??????? ???????
# --
# $Id: job-runner.sh leonid.malashev@gmail.com $
#-------------------------------------------------------------------------------
#set -x
set -Eeuo pipefail

USAGE="Usage: $(basename "$0") --logs-dir=DIR --job-name=NAME --job-script=SCRIPT [--job-args='ARGUMENTS'] [--silent] [--dry-run]"
_verbose=false
_silent=false
_dry_run=false
_job_name=""
_job_script=""
_job_args=""
_logs_dir=""
_child_pid=""
_signal=""
_job_started=false
_lock_name=""
_rman_sid=""
_rman_task=""
_rman_group_lock_name=""
_rman_group_lock_mode=""
POSITIONAL_ARGS=()
job_args=()

require_value() {
    if [[ $# -lt 2 ]]; then
        printf 'ERROR: Option %s requires a value\n%s\n' "$1" "$USAGE" >&2
        exit 2
    fi
}

print_help() {
    cat << EOF
$USAGE

Options:
      --job-name=NAME       Logical job name for logs and generic locking.
      --job-script=SCRIPT   Script from this directory to run.
      --job-args=ARGS       Argument string passed to the job script.
      --logs-dir=DIR        Directory for job-runner logs.
      --silent              Suppress console output; keep routine log entries and errors.
      --dry-run             Show what would run. For rman-backup.sh, passed through.
      --help                Show this help.

RMAN jobs:
  rman-backup.sh jobs require --sid=SID and --task=TASK inside --job-args.
  Their lock key is rman-backup.<SID>.<task>.
  The maintenance task also takes an exclusive per-SID lock against all RMAN tasks.
EOF
}

log_info() {
    $_silent || printf '%s\n' "$*"
}

log_warn() {
    $_silent || printf '%s\n' "$*"
}

log_escape() {
    local value=${1//\\/\\\\}
    value=${value//$'\n'/\\n}
    value=${value//$'\t'/\\t}
    value=${value// /\\ }
    printf '%s' "$value"
}

log_stamp() {
    date '+%b %e %T'
}

log_prefix() {
    printf '%s %s %s[%s]:' "$(log_stamp)" "$(hostname -s 2>/dev/null || hostname)" "$(basename "$0")" "$$"
}

# Parse the existing --job-args string without evaluating shell code.
# Support whitespace, single/double quotes, escapes, and empty quoted arguments.
# Expansion ($(), variables, globs) is deliberately not performed.
parse_job_args() {
    local input=$1 state=plain word="" char next started=false i
    for ((i=0; i<${#input}; i++)); do
        char=${input:i:1}
        case $state in
            single)
                if [[ $char == "'" ]]; then state=plain; else word+=$char; fi
                ;;
            double)
                case $char in
                    '"') state=plain ;;
                    '\')
                        if (( i + 1 >= ${#input} )); then return 2; fi
                        next=${input:i+1:1}
                        case $next in
                            '"'|'\'|'$'|'`') word+=$next; i=$((i + 1)) ;;
                            $'\n') i=$((i + 1)) ;;
                            *) word+=$char ;;
                        esac
                        ;;
                    *) word+=$char ;;
                esac
                ;;
            plain)
                case $char in
                    ' '|$'\t'|$'\n')
                        if $started; then job_args+=("$word"); word=""; started=false; fi
                        ;;
                    "'") state=single; started=true ;;
                    '"') state=double; started=true ;;
                    '\')
                        if (( i + 1 >= ${#input} )); then return 2; fi
                        i=$((i + 1))
                        if [[ ${input:i:1} != $'\n' ]]; then word+=${input:i:1}; started=true; fi
                        ;;
                    *) word+=$char; started=true ;;
                esac
                ;;
        esac
    done
    [[ $state == plain ]] || return 2
    if $started; then job_args+=("$word"); fi
    return 0
}

get_job_arg_value() {
    local long_option=$1 arg
    local -i i

    for ((i=0; i<${#job_args[@]}; i++)); do
        arg=${job_args[i]}
        case $arg in
            "$long_option")
                if (( i + 1 < ${#job_args[@]} )); then
                    printf '%s\n' "${job_args[i + 1]}"
                    return 0
                fi
                ;;
            "$long_option"=*)
                printf '%s\n' "${arg#*=}"
                return 0
                ;;
        esac
    done
    return 1
}

has_job_arg() {
    local option=$1 arg

    for arg in "${job_args[@]}"; do
        [[ $arg == "$option" ]] && return 0
    done
    return 1
}

derive_lock_name() {
    local script_name sid task

    script_name=$(basename -- "$_job_script")
    if [[ $script_name == rman-backup.sh ]]; then
        sid=$(get_job_arg_value --sid || true)
        task=$(get_job_arg_value --task || true)
        if [[ -z $sid || -z $task ]]; then
            echo "ERROR: rman-backup.sh jobs require --sid=SID and --task=TASK for locking" >&2
            exit 2
        fi
        _rman_sid=$sid
        _rman_task=$task
        _rman_group_lock_name="rman-maintenance.${sid}"
        if [[ $task == maintenance ]]; then
            _rman_group_lock_mode=exclusive
        else
            _rman_group_lock_mode=shared
        fi
        _lock_name="rman-backup.${sid}.${task}"
        return 0
    fi
    _lock_name=$_job_name
}

cleanup() {
    local status=$?
    trap - EXIT ERR
    trap '' INT TERM HUP
    set +e
    if [[ -n $_child_pid ]]; then
        # Async children can inherit ignored SIGINT; TERM also works for them.
        kill -TERM -- "$_child_pid" 2>/dev/null || true
        wait "$_child_pid" 2>/dev/null || true
    fi
    if $_job_started; then
        if ! $_silent || [[ $status -ne 0 || $_dry_run == false ]]; then
            printf '%s finish --job-name=%s --status=%s --signal=%s\n' \
                "$(log_prefix)" "$(log_escape "$_job_name")" "$status" "$(log_escape "${_signal:-none}")" >&2 || true
        fi
    fi
    exit "$status"
}

handle_signal() {
    _signal=$2
    exit "$1"
}
trap cleanup EXIT
trap 'printf "ERROR: job-runner line=%s status=%s\n" "$LINENO" "$?" >&2 || true' ERR
trap 'handle_signal 130 INT' INT
trap 'handle_signal 143 TERM' TERM
trap 'handle_signal 129 HUP' HUP

# Parse command line options.
while [[ $# -gt 0 ]]; do
  case $1 in
    --job-name|--job-script|--job-args|--logs-dir)
      printf 'ERROR: Use %s=value syntax\n%s\n' "$1" "$USAGE" >&2
      exit 2
      ;;
  esac
  case $1 in
    --help)          print_help; exit 0 ;;
    --silent)        _silent=true;     shift ;;
    --dry-run)       _dry_run=true;    shift ;;
    --job-name=*)    _job_name="${1#*=}";   shift ;;
    --job-script=*)  _job_script="${1#*=}"; shift ;;
    --job-args=*)    _job_args="${1#*=}";   shift ;;
    --logs-dir=*)    _logs_dir="${1#*=}";   shift ;;
    -*)              printf 'ERROR: Unknown option: %s\n%s\n' "$1" "$USAGE" >&2; exit 2 ;;
    *)               POSITIONAL_ARGS+=("$1"); shift ;;
  esac
done

if [[ -z $_job_name || -z $_job_script || -z $_logs_dir ]]; then
    printf 'ERROR: --job-name=NAME, --job-script=SCRIPT and --logs-dir=DIR are required\n%s\n' "$USAGE" >&2
    exit 2
fi
if [[ ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
    printf 'ERROR: Unexpected positional argument: %s\n%s\n' "${POSITIONAL_ARGS[0]}" "$USAGE" >&2
    exit 2
fi
if $_dry_run; then
    _silent=false
fi
if ! parse_job_args "$_job_args"; then
    echo 'ERROR: Unclosed quote or trailing escape in --job-args' >&2
    exit 2
fi
mkdir -p -- "$_logs_dir"
if ! $_dry_run; then
    exec >> "${_logs_dir}/$(basename "$0").log" 2>&1
fi

_work_dir=$(dirname "$0")
source "${_work_dir}/job-runner.conf"

# Job names become file names inside a private directory.
if [[ ! ${_job_name:-} =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    echo "ERROR: Invalid or missing job name" >&2
    exit 1
fi
if [[ ! $_job_script =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ || $_job_script == .* ]]; then
    echo "ERROR: Invalid job script name" >&2
    exit 1
fi
if [[ ! -f "${_work_dir}/${_job_script}" || ! -x "${_work_dir}/${_job_script}" ]]; then
    echo "ERROR: Job script is not executable: ${_work_dir}/${_job_script}" >&2
    exit 1
fi
derive_lock_name
if [[ ! ${_lock_name:-} =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    echo "ERROR: Invalid lock name derived from job arguments" >&2
    exit 1
fi
if ! command -v flock >/dev/null 2>&1; then
    echo "ERROR: flock is required for job locking" >&2
    exit 1
fi

_lock_dir="${HOME:?HOME is required}/.job-runner-locks"
(umask 077; mkdir -p -- "$_lock_dir")
if [[ -L "$_lock_dir" || ! -d "$_lock_dir" || ! -O "$_lock_dir" ]]; then
    echo "ERROR: Lock directory must be a real directory owned by the current user" >&2
    exit 1
fi
if [[ $(stat -c '%a' -- "$_lock_dir") != 700 ]]; then
    echo "ERROR: Lock directory must have permissions 700: $_lock_dir" >&2
    exit 1
fi

if [[ -n $_rman_group_lock_name ]]; then
    _rman_group_lock_file="$_lock_dir/${_rman_group_lock_name}.lock"
    if [[ -L $_rman_group_lock_file || ( -e $_rman_group_lock_file &&
          ( ! -f $_rman_group_lock_file || ! -O $_rman_group_lock_file ) ) ]]; then
        echo "ERROR: Unsafe RMAN group lock file: $_rman_group_lock_file" >&2
        exit 1
    fi
    # Backup jobs share this SID lock; maintenance holds it exclusively.
    # The child inherits descriptor 8, so maintenance cannot overlap a live RMAN process.
    exec 8>> "$_rman_group_lock_file"
    if [[ $_rman_group_lock_mode == exclusive ]]; then
        if flock -n -E 75 -x 8; then lock_status=0; else lock_status=$?; fi
    else
        if flock -n -E 75 -s 8; then lock_status=0; else lock_status=$?; fi
    fi
    if [[ $lock_status -eq 75 ]]; then
        log_warn "$(date +'%FT%T') WARNING: RMAN work is already running for SID ${_rman_sid}"
        exit 0
    elif [[ $lock_status -ne 0 ]]; then
        echo "ERROR: Cannot acquire RMAN group lock (code $lock_status): $_rman_group_lock_file" >&2
        exit "$lock_status"
    fi
fi

_lock_file="$_lock_dir/${_lock_name}.lock"
if [[ -L "$_lock_file" || ( -e "$_lock_file" && ( ! -f "$_lock_file" || ! -O "$_lock_file" ) ) ]]; then
    echo "ERROR: Unsafe lock file: $_lock_file" >&2
    exit 1
fi
# Keep the file in place: unlinking it would allow a second lock on a new inode.
# The child inherits descriptor 9, keeping the lock if the runner is terminated.
exec 9>> "$_lock_file"
if flock -n -E 75 9; then
    :
else
    lock_status=$?
    if [[ $lock_status -eq 75 ]]; then
        log_warn "$(date +'%FT%T') WARNING: Job is already running: ${_lock_name}"
        exit 0
    fi
    echo "ERROR: Cannot acquire job lock (code $lock_status): $_lock_file" >&2
    exit "$lock_status"
fi

_job_started=true
if ! $_silent || [[ $_dry_run == false ]]; then
    printf '%s start --job-name=%s --lock=%s --job-script=%s --job-args=%s --logs-dir=%s\n' \
        "$(log_prefix)" "$(log_escape "$_job_name")" "$(log_escape "$_lock_name")" \
        "$(log_escape "$_job_script")" "$(log_escape "$_job_args")" "$(log_escape "$_logs_dir")"
fi
if $_silent && [[ $(basename -- "$_job_script") == rman-backup.sh ]] && ! has_job_arg --silent; then
    job_args+=(--silent)
fi
if $_dry_run && [[ $(basename -- "$_job_script") == rman-backup.sh ]] && ! has_job_arg --dry-run; then
    job_args+=(--dry-run)
fi
if $_dry_run; then
    log_info "DRY RUN: would execute: ${_work_dir}/${_job_script}"
    for arg_index in "${!job_args[@]}"; do
        printf 'DRY RUN: argument[%s]=%q\n' "$arg_index" "${job_args[arg_index]}"
    done
    if [[ $(basename -- "$_job_script") != rman-backup.sh ]]; then
        exit 0
    fi
fi
"${_work_dir}/${_job_script}" "${job_args[@]}" &
_child_pid=$!
if wait "$_child_pid"; then return_code=0; else return_code=$?; fi
_child_pid=""
[[ $return_code -ne 0 ]] && printf '%s child_exit --job-name=%s --status=%s\n' \
    "$(log_prefix)" "$(log_escape "$_job_name")" "$return_code"
exit "$return_code"
