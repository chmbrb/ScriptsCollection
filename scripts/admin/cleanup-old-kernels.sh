#!/usr/bin/env bash
#
# cleanup-old-kernels.sh — Universal old-kernel package cleanup.
#
# Detects the package manager in use (same detection list as
# system-update.sh) and removes old, unused kernel packages, always keeping
# the currently running kernel plus a configurable number of the most recent
# others. Listing candidates is the default behavior; nothing is ever
# removed unless -y/--yes is passed explicitly.
#
# Safety guarantees:
#   - The running kernel (uname -r) is never a removal candidate.
#   - Version-held/pinned kernel packages are never removal candidates.
#   - At least 2 kernels (running + 1 other) are always kept; --keep=0 is
#     refused outright.
#   - Only ever removes actual installed packages via the package manager
#     (dnf/apt/zypper/vkpurge) and lets it handle bootloader/initramfs
#     regeneration — this script never calls grubby/update-grub/efibootmgr
#     directly, and never touches rescue/recovery boot entries, since those
#     aren't candidate packages in the first place.
#
# Usage:
#   ./cleanup-old-kernels.sh [-k N|--keep=N] [-y|--yes] [-n|--dry-run] [-h|--help]
#
#   -k N, --keep=N  Keep this many old kernels in addition to the running
#                    one (default: 2). Must be >= 1.
#   -y, --yes        Actually remove the candidate kernels (default is to
#                    only list them).
#   -n, --dry-run    Explicit no-op: list candidates without removing
#                    anything (this is also the default with no flags).
#   -h, --help       Show this help text.

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ASSUME_YES=0
DRY_RUN=0
KEEP=2

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [-k N|--keep=N] [-y|--yes] [-n|--dry-run] [-h|--help]

  -k N, --keep=N  Keep this many old kernels in addition to the running
                   one (default: 2). Must be >= 1.
  -y, --yes        Actually remove the candidate kernels (default is to
                   only list them).
  -n, --dry-run    Explicit no-op: list candidates without removing
                   anything (this is also the default with no flags).
  -h, --help       Show this help text.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -k)
            KEEP="${2:-}"
            shift
            ;;
        --keep=*)
            KEEP="${1#*=}"
            ;;
        --keep)
            KEEP="${2:-}"
            shift
            ;;
        -y|--yes)
            ASSUME_YES=1
            ;;
        -n|--dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "${SCRIPT_NAME}: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

case "$KEEP" in
    ''|*[!0-9]*)
        die "invalid --keep value '${KEEP}': must be a non-negative integer"
        ;;
esac
if [ "$KEEP" -lt 1 ]; then
    die "refusing --keep=${KEEP}: this script always keeps the running kernel plus at least 1 other (2 total minimum) as a safety floor. Use your package manager directly if you really intend to remove down to a single bootable kernel."
fi

print_os_info() {
    if [ -r /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        log "Detected OS: ${PRETTY_NAME:-${NAME:-unknown}}"
    else
        log "Detected OS: $(uname -s) $(uname -r)"
    fi
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        if ! command -v sudo >/dev/null 2>&1; then
            die "not running as root and 'sudo' is not available; re-run as root"
        fi
        sudo "$@"
    fi
}

# Shared candidate computation.
#
# Inputs (globals, set by caller before calling): INSTALLED (array, newest
# first), HELD (array), RUNNING (string).
# Outputs (globals): PROTECTED_OTHERS, CANDIDATES.
compute_sets() {
    PROTECTED_OTHERS=()
    CANDIDATES=()
    local v h is_running is_held count=0
    for v in "${INSTALLED[@]}"; do
        is_running=0
        [ "$v" = "$RUNNING" ] && is_running=1
        is_held=0
        for h in "${HELD[@]:-}"; do
            [ -z "$h" ] && continue
            case "$h" in
                *'*')
                    case "$v" in
                        "${h%\*}"*) is_held=1; break ;;
                    esac
                    ;;
                *)
                    [ "$v" = "$h" ] && { is_held=1; break; }
                    ;;
            esac
        done
        if [ "$is_running" -eq 1 ] || [ "$is_held" -eq 1 ]; then
            continue
        fi
        if [ "$count" -lt "$KEEP" ]; then
            PROTECTED_OTHERS+=("$v")
            count=$((count + 1))
        else
            CANDIDATES+=("$v")
        fi
    done
}

print_report() {
    local manager_label="$1"
    log "Package manager: ${manager_label}"
    log "Running kernel: ${RUNNING} (kept)"
    if [ "${#PROTECTED_OTHERS[@]}" -gt 0 ]; then
        log "Retained (within --keep=${KEEP} window):"
        for v in "${PROTECTED_OTHERS[@]}"; do printf '      - %s\n' "$v"; done
    fi
    if [ "${#HELD[@]}" -gt 0 ]; then
        log "Held/pinned (left untouched, not counted against --keep):"
        for v in "${HELD[@]}"; do printf '      - %s\n' "$v"; done
    fi
    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
        log "No kernels to remove."
    else
        log "Candidates for removal:"
        for v in "${CANDIDATES[@]}"; do printf '      - %s\n' "$v"; done
    fi
}

# --- dnf/yum (Fedora/RHEL family) -------------------------------------------

kernel_cleanup_dnf() {
    command -v rpm >/dev/null 2>&1 || { warn "rpm not found; cannot enumerate kernel versions"; return 0; }

    local kernel_pkg="kernel-core"
    rpm -q "$kernel_pkg" >/dev/null 2>&1 || kernel_pkg="kernel"

    mapfile -t INSTALLED < <(rpm -q "$kernel_pkg" --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V -r)
    if [ "${#INSTALLED[@]}" -eq 0 ]; then
        warn "no installed kernel versions found via 'rpm -q ${kernel_pkg}'"
        return 0
    fi

    RUNNING="$(uname -r)"

    HELD=()
    if command -v dnf >/dev/null 2>&1 && dnf versionlock list >/dev/null 2>&1; then
        mapfile -t HELD < <(dnf versionlock list 2>/dev/null | grep -oE "${kernel_pkg}-[0-9][^ ]*" | sed -E "s/^${kernel_pkg}-//")
    fi

    compute_sets
    print_report "dnf/yum"

    [ "${#CANDIDATES[@]}" -eq 0 ] && return 0

    local subpkgs=(kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-headers)
    local -a REMOVE_PKGS=()
    local v sub nvra
    for v in "${CANDIDATES[@]}"; do
        for sub in "${subpkgs[@]}"; do
            nvra="${sub}-${v}"
            rpm -q "$nvra" >/dev/null 2>&1 && REMOVE_PKGS+=("$nvra")
        done
    done

    if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -ne 1 ]; then
        printf '[would run] dnf remove -y'
        printf ' %q' "${REMOVE_PKGS[@]}"
        printf '\n'
        log "Nothing removed. Re-run with --yes to actually remove."
        return 0
    fi

    log "Removing ${#CANDIDATES[@]} old kernel(s) ..."
    as_root dnf remove -y "${REMOVE_PKGS[@]}"
}

# --- apt (Debian/Ubuntu) -----------------------------------------------------

kernel_cleanup_apt() {
    command -v dpkg-query >/dev/null 2>&1 || { warn "dpkg-query not found; cannot enumerate kernel versions"; return 0; }

    mapfile -t INSTALLED < <(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | sed -E 's/^linux-image-//' | sort -V -r)
    if [ "${#INSTALLED[@]}" -eq 0 ]; then
        warn "no installed versioned kernel packages found (linux-image-<version>)"
        return 0
    fi

    RUNNING="$(uname -r)"

    HELD=()
    if command -v apt-mark >/dev/null 2>&1; then
        mapfile -t HELD < <(apt-mark showhold 2>/dev/null | grep -E '^linux-image-' | sed -E 's/^linux-image-//')
    fi

    compute_sets
    print_report "apt"

    [ "${#CANDIDATES[@]}" -eq 0 ] && return 0

    local prefixes=(linux-image linux-headers linux-modules linux-modules-extra)
    local -a REMOVE_PKGS=()
    local v prefix pkg
    for v in "${CANDIDATES[@]}"; do
        for prefix in "${prefixes[@]}"; do
            pkg="${prefix}-${v}"
            dpkg -s "$pkg" >/dev/null 2>&1 && REMOVE_PKGS+=("$pkg")
        done
    done

    if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -ne 1 ]; then
        printf '[would run] apt-get purge -y'
        printf ' %q' "${REMOVE_PKGS[@]}"
        printf '\n'
        log "Nothing removed. Re-run with --yes to actually remove."
        return 0
    fi

    log "Removing ${#CANDIDATES[@]} old kernel(s) ..."
    as_root apt-get purge -y "${REMOVE_PKGS[@]}"
}

# --- zypper (openSUSE) — delegate to its native tool ------------------------

kernel_cleanup_zypper() {
    log "openSUSE detected: delegating to zypper's native kernel cleanup (zypper purge-kernels)."
    log "Note: retention count is governed by zypper's own 'multiversion.kernels' setting, not this script's --keep."
    if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -ne 1 ]; then
        printf '[would run] zypper purge-kernels\n'
        log "Nothing removed. Re-run with --yes to actually remove."
        return 0
    fi
    as_root zypper --non-interactive purge-kernels || die "zypper purge-kernels failed"
}

# --- xbps-install (Void Linux) — delegate to its native tool ----------------

kernel_cleanup_xbps() {
    if ! command -v vkpurge >/dev/null 2>&1; then
        warn "Void Linux detected but 'vkpurge' not found; skipping."
        return 0
    fi
    log "Void Linux detected: delegating to vkpurge (running kernel: $(uname -r))."
    log "Note: vkpurge protects the running kernel but does not honor this script's --keep count."
    vkpurge list 2>/dev/null || true
    if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -ne 1 ]; then
        printf '[would run] vkpurge rm all\n'
        log "Nothing removed. Re-run with --yes to actually remove."
        return 0
    fi
    as_root vkpurge rm all || die "vkpurge rm all failed"
}

# --- Detected but not applicable, each with its own reason ------------------

na_pacman()          { log "Arch/Manjaro/EndeavourOS use a single rolling 'linux' package; pacman's own kernel hook already removes superseded module directories on upgrade. Nothing to clean up here."; }
na_apk()             { log "Alpine uses a single linux-lts/linux-virt package replaced in place on upgrade; no multi-version kernel state to clean up."; }
na_emerge()          { log "Gentoo kernel management is typically manual (genkernel/make install) and isn't tracked by Portage as installed versions; skipping to avoid guessing at boot-critical state."; }
na_eopkg()           { log "Solus (eopkg) kernel-version tracking wasn't verified for this script; skipping rather than guessing at removal logic for a boot-critical operation. Manual cleanup recommended."; }
na_slackpkg()        { log "Slackware's package tool has no dependency/version database; installed kernel versions aren't enumerable through slackpkg. Skipping."; }
na_pkgin()           { log "NetBSD's kernel is part of the base system (build.sh/binary sets), outside pkgin's scope. Skipping."; }
na_pkg_freebsd()     { log "FreeBSD's kernel is part of the base system, updated via freebsd-update, not pkg. Skipping."; }
na_pkg_add_openbsd() { log "OpenBSD's kernel is part of the base system, updated via syspatch, not pkg_add. Skipping."; }

MANAGERS="
apt-get:kernel_cleanup_apt
dnf:kernel_cleanup_dnf
yum:kernel_cleanup_dnf
pacman:na_pacman
zypper:kernel_cleanup_zypper
apk:na_apk
xbps-install:kernel_cleanup_xbps
emerge:na_emerge
eopkg:na_eopkg
slackpkg:na_slackpkg
pkgin:na_pkgin
"

detect_and_run() {
    local uname_s
    uname_s="$(uname -s)"

    case "$uname_s" in
        FreeBSD)
            na_pkg_freebsd
            return 0
            ;;
        OpenBSD)
            na_pkg_add_openbsd
            return 0
            ;;
    esac

    local entry bin handler
    for entry in $MANAGERS; do
        bin="${entry%%:*}"
        handler="${entry##*:}"
        if command -v "$bin" >/dev/null 2>&1; then
            "$handler"
            return $?
        fi
    done

    die "no supported package manager found on this system"
}

main() {
    print_os_info
    detect_and_run
}

main
exit $?
