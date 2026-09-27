#!/bin/bash
# ==============================================================================
# ocserv Firewall Daemon — Systemd-Native Self-Healing Service
#
# Usage:
#   /usr/local/bin/ocserv-firewall.sh {start|stop|status}
# ==============================================================================
set -uo pipefail

export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ==============================================================================
# Configuration Area
# ==============================================================================
VPN_IF="op+"
VPN4="10.255.255.0/24"
VPN6="fd00:aaaa:bbbb::/64"
TS_IF="tailscale0"
OCSERV_PORT=8443
CHECK_INTERVAL=10
ENABLE_UDP="no"

ACTION="${1:-}"

# ==============================================================================
# Helpers & Checks
# ==============================================================================
log() {
    echo "[ocserv-firewall] $*"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "[ERROR] This script must be run as root." >&2
        exit 1
    fi
}

check_dependencies() {
    local required_cmds=(iptables ip6tables sysctl ip awk wc)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            echo "[ERROR] Missing required CLI binary: ${cmd}" >&2
            exit 1
        fi
    done
}

ensure_sysctl() {
    local key="$1" want="$2" have
    have=$(sysctl -n "${key}" 2>/dev/null || echo "")
    if [[ "${have}" != "${want}" ]]; then
        log "sysctl ${key}: ${have:-<unset>} -> ${want}"
        if ! sysctl -w "${key}=${want}" >/dev/null; then
            log "WARNING: failed to set sysctl ${key}=${want}"
            return 1
        fi
    fi
    return 0
}

tailscale_present() {
    ip link show "${TS_IF}" >/dev/null 2>&1
}

notify_systemd() {
    local status_msg="$1"
    if command -v systemd-notify >/dev/null 2>&1; then
        systemd-notify --ready --status="${status_msg}" 2>/dev/null || true
    fi
}

notify_watchdog() {
    if command -v systemd-notify >/dev/null 2>&1; then
        systemd-notify WATCHDOG=1 2>/dev/null || true
    fi
}

# ==============================================================================
# Core Chain Management
# ==============================================================================
build_chains() {
    local have_ts=0
    tailscale_present && have_ts=1

    # ---- IPv4 FORWARD ----
    iptables -w -N OCSERV-FORWARD 2>/dev/null || iptables -w -F OCSERV-FORWARD
    iptables -w -A OCSERV-FORWARD -s "${VPN4}" -j ACCEPT
    iptables -w -A OCSERV-FORWARD -d "${VPN4}" -j ACCEPT
    if [[ "${have_ts}" -eq 1 ]]; then
        iptables -w -A OCSERV-FORWARD -i "${VPN_IF}" -o "${TS_IF}" -j ACCEPT
        iptables -w -A OCSERV-FORWARD -i "${TS_IF}" -o "${VPN_IF}" -j ACCEPT
    fi
    iptables -w -A OCSERV-FORWARD -j RETURN

    # ---- IPv6 FORWARD ----
    ip6tables -w -N OCSERV-FORWARD 2>/dev/null || ip6tables -w -F OCSERV-FORWARD
    ip6tables -w -A OCSERV-FORWARD -s "${VPN6}" -j ACCEPT
    ip6tables -w -A OCSERV-FORWARD -d "${VPN6}" -j ACCEPT
    if [[ "${have_ts}" -eq 1 ]]; then
        ip6tables -w -A OCSERV-FORWARD -i "${VPN_IF}" -o "${TS_IF}" -j ACCEPT
        ip6tables -w -A OCSERV-FORWARD -i "${TS_IF}" -o "${VPN_IF}" -j ACCEPT
    fi
    ip6tables -w -A OCSERV-FORWARD -j RETURN

    # ---- NAT POSTROUTING (IPv4 / IPv6) ----
    iptables -w -t nat -N OCSERV-POSTROUTING 2>/dev/null || iptables -w -t nat -F OCSERV-POSTROUTING
    iptables -w -t nat -A OCSERV-POSTROUTING -s "${VPN4}" ! -o "${VPN_IF}" -j MASQUERADE
    iptables -w -t nat -A OCSERV-POSTROUTING -j RETURN

    ip6tables -w -t nat -N OCSERV-POSTROUTING 2>/dev/null || ip6tables -w -t nat -F OCSERV-POSTROUTING
    ip6tables -w -t nat -A OCSERV-POSTROUTING -s "${VPN6}" ! -o "${VPN_IF}" -j MASQUERADE
    ip6tables -w -t nat -A OCSERV-POSTROUTING -j RETURN

    # ---- INPUT (IPv4 / IPv6) ----
    iptables -w -N OCSERV-INPUT 2>/dev/null || iptables -w -F OCSERV-INPUT
    iptables -w -A OCSERV-INPUT -p tcp --dport "${OCSERV_PORT}" -j ACCEPT
    if [[ "${ENABLE_UDP}" == "yes" ]]; then
        iptables -w -A OCSERV-INPUT -p udp --dport "${OCSERV_PORT}" -j ACCEPT
    fi
    iptables -w -A OCSERV-INPUT -j RETURN

    ip6tables -w -N OCSERV-INPUT 2>/dev/null || ip6tables -w -F OCSERV-INPUT
    ip6tables -w -A OCSERV-INPUT -p tcp --dport "${OCSERV_PORT}" -j ACCEPT
    if [[ "${ENABLE_UDP}" == "yes" ]]; then
        ip6tables -w -A OCSERV-INPUT -p udp --dport "${OCSERV_PORT}" -j ACCEPT
    fi
    ip6tables -w -A OCSERV-INPUT -j RETURN
}

# Verifies that each custom chain contains its expected rule signatures.
# Counting rules alone is too coarse: a chain reduced to just its RETURN
# line would still yield >= 3 lines and be wrongly treated as intact.
chains_intact() {
    # IPv4 FORWARD
    iptables -w -C OCSERV-FORWARD -s "${VPN4}" -j ACCEPT 2>/dev/null || return 1
    iptables -w -C OCSERV-FORWARD -d "${VPN4}" -j ACCEPT 2>/dev/null || return 1
    iptables -w -C OCSERV-FORWARD -j RETURN 2>/dev/null || return 1

    # IPv6 FORWARD
    ip6tables -w -C OCSERV-FORWARD -s "${VPN6}" -j ACCEPT 2>/dev/null || return 1
    ip6tables -w -C OCSERV-FORWARD -d "${VPN6}" -j ACCEPT 2>/dev/null || return 1
    ip6tables -w -C OCSERV-FORWARD -j RETURN 2>/dev/null || return 1

    # IPv4 NAT POSTROUTING
    iptables -w -t nat -C OCSERV-POSTROUTING -s "${VPN4}" ! -o "${VPN_IF}" -j MASQUERADE 2>/dev/null || return 1
    iptables -w -t nat -C OCSERV-POSTROUTING -j RETURN 2>/dev/null || return 1

    # IPv6 NAT POSTROUTING
    ip6tables -w -t nat -C OCSERV-POSTROUTING -s "${VPN6}" ! -o "${VPN_IF}" -j MASQUERADE 2>/dev/null || return 1
    ip6tables -w -t nat -C OCSERV-POSTROUTING -j RETURN 2>/dev/null || return 1

    # IPv4 INPUT
    iptables -w -C OCSERV-INPUT -p tcp --dport "${OCSERV_PORT}" -j ACCEPT 2>/dev/null || return 1
    if [[ "${ENABLE_UDP}" == "yes" ]]; then
        iptables -w -C OCSERV-INPUT -p udp --dport "${OCSERV_PORT}" -j ACCEPT 2>/dev/null || return 1
    fi
    iptables -w -C OCSERV-INPUT -j RETURN 2>/dev/null || return 1

    # IPv6 INPUT
    ip6tables -w -C OCSERV-INPUT -p tcp --dport "${OCSERV_PORT}" -j ACCEPT 2>/dev/null || return 1
    if [[ "${ENABLE_UDP}" == "yes" ]]; then
        ip6tables -w -C OCSERV-INPUT -p udp --dport "${OCSERV_PORT}" -j ACCEPT 2>/dev/null || return 1
    fi
    ip6tables -w -C OCSERV-INPUT -j RETURN 2>/dev/null || return 1

    return 0
}

jump_is_first() {
    local tool="$1" table_flag="$2" parent="$3" target="$4"
    local first_target
    # shellcheck disable=SC2086
    first_target=$(${tool} -w ${table_flag} -L "${parent}" -n --line-numbers 2>/dev/null | awk 'NR==3 {print $2}')
    [[ "${first_target}" == "${target}" ]]
}

enforce_jump_first() {
    local tool="$1" table_flag="$2" parent="$3" target="$4"
    if jump_is_first "${tool}" "${table_flag}" "${parent}" "${target}"; then
        return 0
    fi

    log "Jump ${target} in ${parent} (${tool} ${table_flag:-filter}) moved from position 1 — reasserting"
    # shellcheck disable=SC2086
    while ${tool} -w ${table_flag} -C "${parent}" -j "${target}" 2>/dev/null; do
        # shellcheck disable=SC2086
        ${tool} -w ${table_flag} -D "${parent}" -j "${target}"
    done
    # shellcheck disable=SC2086
    if ! ${tool} -w ${table_flag} -I "${parent}" 1 -j "${target}"; then
        log "WARNING: failed to re-anchor ${target} in ${parent} (${tool} ${table_flag:-filter})"
        return 1
    fi
    return 0
}

enforce_all_jumps_first() {
    enforce_jump_first iptables ""       FORWARD    OCSERV-FORWARD
    enforce_jump_first iptables ""       INPUT      OCSERV-INPUT
    enforce_jump_first iptables "-t nat" POSTROUTING OCSERV-POSTROUTING
    enforce_jump_first ip6tables ""       FORWARD    OCSERV-FORWARD
    enforce_jump_first ip6tables ""       INPUT      OCSERV-INPUT
    enforce_jump_first ip6tables "-t nat" POSTROUTING OCSERV-POSTROUTING
}

# ==============================================================================
# Actions
# ==============================================================================
do_start() {
    require_root
    check_dependencies

    # Handle systemd shutdown (SIGTERM) or ctrl+c (SIGINT) cleanly
    trap 'log "Received SIGTERM/SIGINT from systemd, performing clean shutdown..."; do_stop; exit 0' TERM INT

    ensure_sysctl net.ipv4.ip_forward 1
    ensure_sysctl net.ipv6.conf.all.forwarding 1

    build_chains
    enforce_all_jumps_first

    local last_ts_state=0
    tailscale_present && last_ts_state=1
    log "Initial setup complete (tailscale0 active: ${last_ts_state}). Service ready."

    notify_systemd "Monitoring rules (Interval: ${CHECK_INTERVAL}s)"

    while true; do
        sleep "${CHECK_INTERVAL}" &
        wait $! || true
        notify_watchdog

        local ts_now=0
        tailscale_present && ts_now=1

        local reason=""
        if [[ "${ts_now}" -ne "${last_ts_state}" ]]; then
            reason="Tailscale state transition (${last_ts_state} -> ${ts_now})"
        elif ! chains_intact; then
            reason="chains missing or flushed"
        fi

        if [[ -n "${reason}" ]]; then
            log "Rebuilding rules (${reason})."
            build_chains
            last_ts_state="${ts_now}"
        fi

        enforce_all_jumps_first
    done
}

do_stop() {
    require_root
    check_dependencies

    log "Cleaning up all OCSERV iptables chains and jumps..."

    while iptables  -w -C FORWARD -j OCSERV-FORWARD 2>/dev/null; do iptables  -w -D FORWARD -j OCSERV-FORWARD; done
    while iptables  -w -C INPUT   -j OCSERV-INPUT   2>/dev/null; do iptables  -w -D INPUT   -j OCSERV-INPUT;   done
    while iptables  -w -t nat -C POSTROUTING -j OCSERV-POSTROUTING 2>/dev/null; do iptables -w -t nat -D POSTROUTING -j OCSERV-POSTROUTING; done
    while ip6tables -w -C FORWARD -j OCSERV-FORWARD 2>/dev/null; do ip6tables -w -D FORWARD -j OCSERV-FORWARD; done
    while ip6tables -w -C INPUT   -j OCSERV-INPUT   2>/dev/null; do ip6tables -w -D INPUT   -j OCSERV-INPUT;   done
    while ip6tables -w -t nat -C POSTROUTING -j OCSERV-POSTROUTING 2>/dev/null; do ip6tables -w -t nat -D POSTROUTING -j OCSERV-POSTROUTING; done

    iptables  -w -F OCSERV-FORWARD 2>/dev/null && iptables  -w -X OCSERV-FORWARD 2>/dev/null || true
    iptables  -w -F OCSERV-INPUT   2>/dev/null && iptables  -w -X OCSERV-INPUT   2>/dev/null || true
    iptables  -w -t nat -F OCSERV-POSTROUTING 2>/dev/null && iptables  -w -t nat -X OCSERV-POSTROUTING 2>/dev/null || true
    ip6tables -w -F OCSERV-FORWARD 2>/dev/null && ip6tables -w -X OCSERV-FORWARD 2>/dev/null || true
    ip6tables -w -F OCSERV-INPUT   2>/dev/null && ip6tables -w -X OCSERV-INPUT   2>/dev/null || true
    ip6tables -w -t nat -F OCSERV-POSTROUTING 2>/dev/null && ip6tables -w -t nat -X OCSERV-POSTROUTING 2>/dev/null || true

    log "Firewall cleanup complete."
}

do_status() {
    require_root
    check_dependencies
    echo "=== OCSERV Jump Status ==="
    iptables -w -L FORWARD -n --line-numbers 2>/dev/null | grep -E "OCSERV|^Chain|^num" || true
    iptables -w -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -E "OCSERV|^Chain|^num" || true

    echo ""
    echo "=== Environment Info ==="
    echo "tailscale0 present : $(tailscale_present && echo yes || echo no)"
    echo "UDP port enabled   : ${ENABLE_UDP}"
    echo "Chains intact      : $(chains_intact && echo yes || echo no)"
}

case "${ACTION}" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    *)
        echo "Usage: $0 {start|stop|status}" >&2
        exit 1
        ;;
esac
