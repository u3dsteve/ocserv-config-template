#!/bin/bash
# ==============================================================================
# ocuser.sh - OpenConnect (ocserv) User Management Engine
#
# Usage:
#   ./ocuser.sh add <username> [group]     Add a user (interactive password prompt)
#   ./ocuser.sh del <username>             Delete a user
#   ./ocuser.sh lock <username>            Lock a user (disable login)
#   ./ocuser.sh unlock <username>          Unlock a user
#   ./ocuser.sh list                       List all users
#   ./ocuser.sh passwd <username>          Change a user's password
#   ./ocuser.sh status                     Show ocserv server status and online users
#   ./ocuser.sh --help                     Show this help message
# ==============================================================================
set -euo pipefail

export LC_ALL=C

# ==============================================================================
# Global Configuration & State
# ==============================================================================
OCPASSWD_FILE="/etc/ocserv/ocpasswd"
OCPASSWD_BIN="/usr/bin/ocpasswd"
LOCK_FILE="/var/run/ocuser_management.lock"

LOCK_FD=9
CURRENT_STEP=""
COMMAND=""
TARGET_USER=""
TARGET_GROUP=""

# ==============================================================================
# Logging Helpers
# ==============================================================================
info()    { echo -e "\e[32m>>> $* \e[0m"; }
warning() { echo -e "\e[33m!!! $* \e[0m"; }
error()   { echo -e "\e[31m[ERROR] $* \e[0m" >&2; }
header()  { echo -e "\n\e[1m── $* ──\e[0m"; }

# ==============================================================================
# Signal & Error Handling
# ==============================================================================
cleanup_on_exit() {
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
}

graceful_exit() {
    local code="${1:-0}"
    CURRENT_STEP=""
    # Disable all traps before cleanup to prevent recursive error handling
    trap - INT EXIT ERR
    cleanup_on_exit
    exit "${code}"
}

handle_sigint() {
    echo ""
    warning "Operation interrupted by user (SIGINT)."
    trap - ERR
    exit 130
}

on_error() {
    local exit_code=$?
    local line=$1
    if [[ -n "${CURRENT_STEP}" ]]; then
        error "Unhandled error in step '${CURRENT_STEP}' at line ${line} (exit code: ${exit_code})."
    else
        error "Unhandled error at line ${line} (exit code: ${exit_code})."
    fi
    graceful_exit "${exit_code}"
}

trap cleanup_on_exit EXIT
trap handle_sigint INT
trap 'on_error $LINENO' ERR

usage() {
    grep '^#   \./ocuser\.sh' "$0" | sed 's/^#   //'
    [[ "${1:-}" == "err" ]] && graceful_exit 1 || graceful_exit 0
}

# ==============================================================================
# Verification & Helper Functions
# ==============================================================================
validate_username() {
    local user="$1"
    if [[ ! "${user}" =~ ^[a-zA-Z0-9_@.-]+$ ]]; then
        error "Invalid username '${user}'. Allowed characters: letters, numbers, _, @, ., -"
        graceful_exit 1
    fi
}

check_user_exists() {
    local user="$1"
    [[ ! -f "${OCPASSWD_FILE}" ]] && return 1
    awk -F: -v u="${user}" '$1 == u { found=1; exit } END { exit !found }' "${OCPASSWD_FILE}"
}

acquire_lock() {
    exec ${LOCK_FD}>"${LOCK_FILE}"
    if ! flock -n "${LOCK_FD}"; then
        error "Another user management process is running (${LOCK_FILE}). Exiting."
        graceful_exit 1
    fi
}

# Guard interactive ocpasswd invocations that rely on a TTY for password entry
require_tty() {
    if [[ ! -t 0 ]]; then
        error "Interactive terminal required for password prompt (stdin is not a TTY)."
        graceful_exit 1
    fi
}

# ==============================================================================
# Atomic Step Functions
# ==============================================================================
step_check_prereqs() {
    if [[ ! -x "${OCPASSWD_BIN}" ]]; then
        error "ocserv binary '${OCPASSWD_BIN}' is not installed or not executable."
        graceful_exit 1
    fi

    case "${COMMAND}" in
        add|del|lock|unlock|passwd|status)
            if [[ "${EUID}" -ne 0 ]]; then
                error "Command '${COMMAND}' requires root privileges. Run with sudo."
                graceful_exit 1
            fi
            ;;
    esac

    if ! systemctl is-active --quiet ocserv 2>/dev/null; then
        warning "ocserv system service is currently NOT active."
    fi
}

step_dispatch_command() {
    case "${COMMAND}" in
        add)    cmd_add ;;
        del)    cmd_del ;;
        lock)   cmd_lock ;;
        unlock) cmd_unlock ;;
        passwd) cmd_passwd ;;
        list)   cmd_list ;;
        status) cmd_status ;;
        *)      usage err ;;
    esac
}

# ==============================================================================
# Command Modules
# ==============================================================================
cmd_add() {
    acquire_lock
    validate_username "${TARGET_USER}"
    require_tty
    mkdir -p "$(dirname "${OCPASSWD_FILE}")"

    if check_user_exists "${TARGET_USER}"; then
        error "User '${TARGET_USER}' already exists."
        graceful_exit 1
    fi

    header "Adding User: ${TARGET_USER}"
    if [[ -n "${TARGET_GROUP}" ]]; then
        "${OCPASSWD_BIN}" -c "${OCPASSWD_FILE}" -g "${TARGET_GROUP}" "${TARGET_USER}"
    else
        "${OCPASSWD_BIN}" -c "${OCPASSWD_FILE}" "${TARGET_USER}"
    fi
    info "User successfully added: ${TARGET_USER}${TARGET_GROUP:+ (group: $TARGET_GROUP)}"
}

cmd_del() {
    acquire_lock
    validate_username "${TARGET_USER}"

    if ! check_user_exists "${TARGET_USER}"; then
        error "User '${TARGET_USER}' does not exist."
        graceful_exit 1
    fi

    header "Deleting User: ${TARGET_USER}"
    "${OCPASSWD_BIN}" -c "${OCPASSWD_FILE}" -d "${TARGET_USER}"
    info "User successfully deleted: ${TARGET_USER}"
}

cmd_lock() {
    acquire_lock
    validate_username "${TARGET_USER}"

    if ! check_user_exists "${TARGET_USER}"; then
        error "User '${TARGET_USER}' does not exist."
        graceful_exit 1
    fi

    header "Locking User: ${TARGET_USER}"
    "${OCPASSWD_BIN}" -c "${OCPASSWD_FILE}" -l "${TARGET_USER}"
    info "User account locked: ${TARGET_USER}"
}

cmd_unlock() {
    acquire_lock
    validate_username "${TARGET_USER}"

    if ! check_user_exists "${TARGET_USER}"; then
        error "User '${TARGET_USER}' does not exist."
        graceful_exit 1
    fi

    header "Unlocking User: ${TARGET_USER}"
    "${OCPASSWD_BIN}" -c "${OCPASSWD_FILE}" -u "${TARGET_USER}"
    info "User account unlocked: ${TARGET_USER}"
}

cmd_passwd() {
    acquire_lock
    validate_username "${TARGET_USER}"
    require_tty

    if ! check_user_exists "${TARGET_USER}"; then
        error "User '${TARGET_USER}' does not exist."
        graceful_exit 1
    fi

    header "Changing Password: ${TARGET_USER}"
    "${OCPASSWD_BIN}" -c "${OCPASSWD_FILE}" "${TARGET_USER}"
    info "Password updated for user: ${TARGET_USER}"
}

cmd_list() {
    header "ocserv User List"
    if [[ ! -f "${OCPASSWD_FILE}" ]]; then
        info "Password database file does not exist: ${OCPASSWD_FILE}"
        return 0
    fi

    printf "%-20s %-15s %s\n" "Username" "Group" "Status"
    printf "%-20s %-15s %s\n" "--------" "-----" "------"

    local user group hash status
    while IFS=: read -r user group hash || [[ -n "${user}" ]]; do
        [[ -z "${user}" || "${user}" =~ ^# ]] && continue
        status="Active"
        if [[ "${hash}" == \$0\$locked* || "${hash}" == "*"* ]]; then
            status="Locked"
        fi
        printf "%-20s %-15s %s\n" "${user}" "${group:-*}" "${status}"
    done < "${OCPASSWD_FILE}"
}

cmd_status() {
    header "ocserv Service Status Summary"
    if ! systemctl is-active --quiet ocserv 2>/dev/null; then
        warning "Status: ocserv service is NOT running."
        return 0
    fi

    info "Status: ocserv service is running."
    echo ""

    if ! command -v occtl >/dev/null 2>&1; then
        warning "occtl CLI utility not found in PATH."
        return 0
    fi

    local rc=0
    echo "=== Server Summary ==="
    if ! occtl show status 2>/dev/null; then
        warning "Unable to connect to occtl socket."
        rc=1
    fi

    echo ""
    echo "=== Online Users ==="
    if ! occtl show users 2>/dev/null; then
        warning "Unable to fetch online users."
        rc=1
    fi

    return "${rc}"
}

# ==============================================================================
# Pipeline Engine
# ==============================================================================
run_pipeline() {
    local pipeline=(
        step_check_prereqs
        step_dispatch_command
    )

    for step in "${pipeline[@]}"; do
        if declare -f "${step}" >/dev/null; then
            CURRENT_STEP="${step#step_}"
            "${step}"
        else
            error "Pipeline error: step function '${step}' is not defined."
            graceful_exit 1
        fi
    done
    CURRENT_STEP=""
}

# ==============================================================================
# Entry Point
# ==============================================================================
if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

COMMAND="$1"
shift || true

case "${COMMAND}" in
    add)
        TARGET_USER="${1:-}"
        TARGET_GROUP="${2:-}"
        [[ -z "${TARGET_USER}" ]] && { error "Missing username for 'add'."; usage err; }
        ;;
    del|lock|unlock|passwd)
        TARGET_USER="${1:-}"
        [[ -z "${TARGET_USER}" ]] && { error "Missing username for '${COMMAND}'."; usage err; }
        ;;
    list|status)
        ;;
    *)
        error "Unknown command: ${COMMAND}"
        usage err
        ;;
esac

run_pipeline
