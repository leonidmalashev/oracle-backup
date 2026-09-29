#!/bin/bash
# rman-backup.sh - Oracle RMAN backup launcher.
set -Eeuo pipefail
_started_at=$SECONDS

_verbose=false
_silent=false
_dry_run=false
_oracle_sid=""
_task=""
_base_backup_dir=""
_logs_dir=""
_temp_dir=""
_rman_scr=""
_rman_log=""
_rman_out=""
_child_pid=""
backup_tag=""
_signal=""
_error_line=""
_phase=startup
POSITIONAL_ARGS=()

log_info() {
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

print_help() {
    cat << EOF
$USAGE

Options:
      --sid=SID             Oracle SID to back up.
      --task=TASK           One of: database-i0, database-i1, archivelog, maintenance, restore_validate.
      --base-backup-dir=DIR Base directory for backup pieces.
      --logs-dir=DIR        Directory for wrapper logs and diagnostics.
      --dry-run             Generate and show the RMAN script and command, then exit.
                            Does not run RMAN, delete logs, or remove temp files.
      --silent              Suppress console output; keep routine log entries and errors.
      --help                Show this help.
EOF
}

sanitize() {
    local sanitized
    sanitized=$(printf '%s' "$1" | sed 's#[\\/:\*\?"<>|]##g' | tr ' ' '_' | sed 's/^[[:space:]\.]*//; s/[[:space:]\.]*$//')
    printf '%s\n' "${sanitized:0:255}"
}

record_error() {
    local status=$1
    _error_line=$2
    printf 'ERROR: phase=%s line=%s status=%s\n' "$_phase" "$_error_line" "$status" >&2 || true
    return "$status"
}

cleanup() {
    local status=$? cleanup_status=0 diagnostics_dir="" file
    trap - EXIT ERR
    trap '' INT TERM HUP
    set +e
    # Reap the child before copying/deleting files it may still be writing.
    # Also covers an unexpected shell error after the child has been launched.
    if [[ -n $_child_pid ]]; then
        kill -TERM -- "$_child_pid" 2>/dev/null || true
        wait "$_child_pid" 2>/dev/null || true
        _child_pid=""
    fi
    if [[ -n $_task && ( $status -ne 0 || $_dry_run == false ) ]]; then
        local duration=$(( SECONDS - _started_at ))
        printf '%s finish sid=%s task=%s status=%s signal=%s phase=%s duration=%ss\n' \
            "$(log_prefix)" "$(log_escape "$_oracle_sid")" "$(log_escape "$_task")" \
            "$status" "$(log_escape "${_signal:-none}")" "$(log_escape "$_phase")" "$duration" >&2 || true
    fi
    if [[ -n $_temp_dir && -d $_temp_dir ]]; then
        if $_dry_run; then
            printf 'DRY RUN: temporary files retained: %s\n' "$_temp_dir" >&2 || true
            exit "$status"
        fi
        # Keep the established per-job log path for existing consumers.
        if [[ -f $_rman_log ]]; then
            cp -- "$_rman_log" "$_logs_dir/$(sanitize "$backup_tag").log" || cleanup_status=$?
        fi
        if [[ $status -ne 0 && $cleanup_status -eq 0 ]]; then
            # Unique directories prevent concurrent runs from overwriting diagnostics.
            diagnostics_dir=$(mktemp -d "$_logs_dir/rman-$(sanitize "$backup_tag").XXXXXXXX") || cleanup_status=$?
            if [[ $cleanup_status -eq 0 ]]; then
                for file in "$_rman_scr" "$_rman_log" "$_rman_out"; do
                    if [[ -f $file ]]; then
                        cp -- "$file" "$diagnostics_dir/" || cleanup_status=$?
                    fi
                done
                printf 'task=%s\nsid=%s\nexit_status=%s\nsignal=%s\nphase=%s\nerror_line=%s\n' \
                    "$_task" "$_oracle_sid" "$status" "${_signal:-none}" "$_phase" "$_error_line" \
                    > "$diagnostics_dir/status.txt" || cleanup_status=$?
            fi
        fi
        if [[ $cleanup_status -eq 0 ]]; then
            if [[ -n $diagnostics_dir ]]; then
                $_silent || printf '%s diagnostics_saved sid=%s task=%s path=%s\n' \
                    "$(log_prefix)" "$(log_escape "$_oracle_sid")" "$(log_escape "$_task")" \
                    "$(log_escape "$diagnostics_dir")" >&2 || true
            fi
            rm -f -- "$_rman_scr" "$_rman_log" "$_rman_out" || cleanup_status=$?
            rmdir -- "$_temp_dir" || cleanup_status=$?
        fi
    fi
    if [[ $cleanup_status -ne 0 ]]; then
        printf 'ERROR: Diagnostics/cleanup failed (code %s); retained temporary files: %s; archive: %s\n' \
            "$cleanup_status" "$_temp_dir" "$diagnostics_dir" >&2 || true
        if [[ $status -eq 0 ]]; then status=$cleanup_status; fi
    fi
    exit "$status"
}

handle_signal() {
    _signal=$2
    exit "$1"
}
trap cleanup EXIT
trap 'record_error $? $LINENO' ERR
trap 'handle_signal 130 INT' INT
trap 'handle_signal 143 TERM' TERM
trap 'handle_signal 129 HUP' HUP

USAGE="Usage: $(basename "$0") --sid=SID --task=[ database-i0 | database-i1 | archivelog | maintenance | restore_validate ] --base-backup-dir=DIR --logs-dir=DIR [--silent] [--dry-run]"
while [[ $# -gt 0 ]]; do
    case $1 in
        --sid|--task|--base-backup-dir|--logs-dir)
            printf 'ERROR: Use %s=value syntax\n%s\n' "$1" "$USAGE" >&2
            exit 2
            ;;
    esac
    case $1 in
        --help)            print_help; exit 0 ;;
        --silent)          _silent=true; shift ;;
        --dry-run)         _dry_run=true; shift ;;
        --sid=*)           _oracle_sid=${1#*=}; shift ;;
        --task=*)          _task=${1#*=}; shift ;;
        --base-backup-dir=*) _base_backup_dir=${1#*=}; shift ;;
        --logs-dir=*)      _logs_dir=${1#*=}; shift ;;
        -*) printf 'ERROR: Unknown option: %s\n%s\n' "$1" "$USAGE" >&2; exit 2 ;;
        *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

if [[ ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
    printf 'ERROR: Unexpected positional argument: %s\n%s\n' "${POSITIONAL_ARGS[0]}" "$USAGE" >&2
    exit 2
fi
if $_dry_run; then
    _silent=false
fi

if [[ -z $_oracle_sid || -z $_task || -z $_base_backup_dir || -z $_logs_dir ]]; then
    printf 'ERROR: --sid=SID, --task=TASK, --base-backup-dir=DIR and --logs-dir=DIR are required\n%s\n' "$USAGE" >&2
    exit 2
fi
case $_task in
    database-i0) job_name=i0 ;;
    database-i1) job_name=i1 ;;
    archivelog) job_name=al ;;
    maintenance) job_name=maint ;;
    restore_validate) job_name=rv ;;
    *) printf 'ERROR: Unknown task: %s\n%s\n' "$_task" "$USAGE" >&2; exit 2 ;;
esac
if [[ ! $_oracle_sid =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    printf 'ERROR: Invalid --sid: %s\n' "$_oracle_sid" >&2
    exit 2
fi
if [[ -e $_base_backup_dir && ! -d $_base_backup_dir ]]; then
    printf 'ERROR: --base-backup-dir is not a directory: %s\n' "$_base_backup_dir" >&2
    exit 2
fi
if [[ -e $_logs_dir && ! -d $_logs_dir ]]; then
    printf 'ERROR: --logs-dir is not a directory: %s\n' "$_logs_dir" >&2
    exit 2
fi

mkdir -p -- "$_logs_dir"
if ! $_dry_run; then
    exec >> "${_logs_dir}/$(basename "$0").log" 2>&1
fi
_work_dir=$(dirname "$0")
_backup_config=""
_sid_config=""
if [[ -f $_work_dir/rman-backup.conf ]]; then
    _backup_config="$_work_dir/rman-backup.conf"
    source "$_work_dir/rman-backup.conf"
fi
if [[ -f $_work_dir/rman-backup.${_oracle_sid}.conf ]]; then
    _sid_config="$_work_dir/rman-backup.${_oracle_sid}.conf"
    source "$_work_dir/rman-backup.${_oracle_sid}.conf"
fi

export ORACLE_SID="$_oracle_sid" ORAENV_ASK=NO
# Oracle's environment script may inspect unset variables.
set +u
source oraenv -s
set -u
if [[ -z ${ORACLE_HOME:-} ]]; then
    echo 'ERROR: oraenv did not set ORACLE_HOME' >&2
    exit 1
fi
mkdir -p -- "${_base_backup_dir}/${_oracle_sid}"
LOGS_DIR=$_logs_dir
if ! $_silent || [[ $_dry_run == false ]]; then
    printf '%s start sid=%s task=%s base_backup_dir=%s logs_dir=%s config=%s sid_config=%s\n' \
        "$(log_prefix)" "$(log_escape "$_oracle_sid")" "$(log_escape "$_task")" \
        "$(log_escape "$_base_backup_dir")" "$(log_escape "$LOGS_DIR")" \
        "$(log_escape "$_backup_config")" "$(log_escape "$_sid_config")"
fi

job_time=$(date +'%FT%T')
backup_tag="${job_name}_${job_time}"
_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/rman.XXXXXXXX")
_rman_scr="$_temp_dir/rman.scr"
_rman_log="$_temp_dir/rman.log"
_rman_out="$_temp_dir/rman.out"
_phase=generate
case $_task in
    database-i0) create_rman_backup_database_i0_script "$_rman_scr" "$backup_tag" "$job_name" ;;
    database-i1) create_rman_backup_database_i1_script "$_rman_scr" "$backup_tag" "$job_name" ;;
    archivelog) create_rman_backup_archivelog_script "$_rman_scr" "$backup_tag" "$job_name" ;;
    maintenance) create_rman_maintenance_script "$_rman_scr" "$backup_tag" ;;
    restore_validate) create_rman_restore_database_validate_script "$_rman_scr" "$backup_tag" "$job_name" ;;
esac
if [[ ! -f $_rman_scr ]]; then
    printf 'ERROR: Cannot open RMAN script file: %s\n' "$_rman_scr" >&2
    exit 1
fi

if $_dry_run; then
    log_info "DRY RUN: RMAN script: $_rman_scr"
    log_info "DRY RUN: RMAN log: $_rman_log"
    log_info "DRY RUN: RMAN output: $_rman_out"
    log_info "DRY RUN: would execute:"
    log_info "  $ORACLE_HOME/bin/rman nocatalog log $_rman_log @$_rman_scr"
    log_info "DRY RUN: generated RMAN script follows:"
    cat -- "$_rman_scr"
    exit 0
fi

_phase=rman
"$ORACLE_HOME/bin/rman" nocatalog log "$_rman_log" "@$_rman_scr" > "$_rman_out" 2>&1 &
_child_pid=$!
if wait "$_child_pid"; then _result_code=0; else _result_code=$?; fi
_child_pid=""
if [[ $_result_code -ne 0 ]]; then
    printf '%s rman_error sid=%s task=%s status=%s\n' \
        "$(log_prefix)" "$(log_escape "$_oracle_sid")" "$(log_escape "$_task")" "$_result_code"
    for diagnostic in "$_rman_scr" "$_rman_log" "$_rman_out"; do
        if [[ -f $diagnostic ]]; then
            printf 'ERROR: Contents of %s\n' "$diagnostic"
            cat -- "$diagnostic" || true
        fi
    done
else
    _phase=log-retention
    find "$LOGS_DIR" -name '*.log' -mtime +32 -print -delete
fi
exit "$_result_code"
