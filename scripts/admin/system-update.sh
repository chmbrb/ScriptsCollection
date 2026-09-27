#!/usr/bin/env bash
#
# system-update.sh — Universal OS package updater.
#
# Detects whichever package manager is actually installed on the running
# system (rather than matching against a fixed distro list) and runs its
# update + upgrade sequence. Works across Linux distributions and the
# common BSDs.
#
# Usage:
#   ./system-update.sh [-y|--yes] [-n|--dry-run] [-h|--help]
#
#   -y, --yes       Non-interactive: auto-confirm the package manager's prompts.
#   -n, --dry-run   Print the commands that would run, without executing them.
#   -h, --help      Show this help text.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [-y|--yes] [-n|--dry-run] [-h|--help]

  -y, --yes       Non-interactive: auto-confirm the package manager's prompts.
  -n, --dry-run   Print the commands that would run, without executing them.
  -h, --help      Show this help text.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
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

# Print OS metadata (best-effort, informational only — detection itself is
# based on which package-manager binary is present, not on this).
print_os_info() {
    if [ -r /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        log "Detected OS: ${PRETTY_NAME:-${NAME:-unknown}}"
    else
        log "Detected OS: $(uname -s) $(uname -r)"
    fi
}

# Wrap a command with sudo when not already running as root.
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

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        as_root "$@"
    fi
}

# Each *_update function runs the refresh + upgrade sequence for one
# package manager, respecting ASSUME_YES.

update_apt() {
    run apt-get update
    if [ "$ASSUME_YES" -eq 1 ]; then
        run apt-get -y upgrade
        run apt-get -y autoremove
    else
        run apt-get upgrade
    fi
}

update_dnf() {
    if [ "$ASSUME_YES" -eq 1 ]; then
        run dnf -y upgrade --refresh
    else
        run dnf upgrade --refresh
    fi
}

update_yum() {
    if [ "$ASSUME_YES" -eq 1 ]; then
        run yum -y update
    else
        run yum update
    fi
}

update_pacman() {
    if [ "$ASSUME_YES" -eq 1 ]; then
        run pacman -Syu --noconfirm
    else
        run pacman -Syu
    fi
}

update_zypper() {
    run zypper refresh
    if [ "$ASSUME_YES" -eq 1 ]; then
        run zypper --non-interactive update
    else
        run zypper update
    fi
}

update_apk() {
    run apk update
    run apk upgrade
}

update_xbps() {
    if [ "$ASSUME_YES" -eq 1 ]; then
        run xbps-install -Suy
    else
        run xbps-install -Su
    fi
}

update_emerge() {
    run emerge --sync
    run emerge --update --deep --newuse @world
}

update_eopkg() {
    run eopkg update-repo
    if [ "$ASSUME_YES" -eq 1 ]; then
        run eopkg upgrade -y
    else
        run eopkg upgrade
    fi
}

update_slackpkg() {
    run slackpkg update
    if [ "$ASSUME_YES" -eq 1 ]; then
        run slackpkg -batch=on -default_answer=yes upgrade-all
    else
        run slackpkg upgrade-all
    fi
}

update_pkg_freebsd() {
    run pkg update
    if [ "$ASSUME_YES" -eq 1 ]; then
        run pkg upgrade -y
    else
        run pkg upgrade
    fi
}

update_pkg_add_openbsd() {
    run pkg_add -u
}

update_pkgin() {
    if [ "$ASSUME_YES" -eq 1 ]; then
        run pkgin -y update
        run pkgin -y upgrade
    else
        run pkgin update
        run pkgin upgrade
    fi
}

# Ordered list of "binary:handler" pairs. Order matters where more than one
# manager could plausibly be present (rare, but e.g. rescue/compat layers).
MANAGERS="
apt-get:update_apt
dnf:update_dnf
yum:update_yum
pacman:update_pacman
zypper:update_zypper
apk:update_apk
xbps-install:update_xbps
emerge:update_emerge
eopkg:update_eopkg
slackpkg:update_slackpkg
pkgin:update_pkgin
"

detect_and_run() {
    local uname_s
    uname_s="$(uname -s)"

    # BSDs first: their package manager binary names ('pkg', 'pkg_add') are
    # either ambiguous with Linux tooling or too generic to search for
    # generically, so key off the kernel name directly.
    case "$uname_s" in
        FreeBSD)
            command -v pkg >/dev/null 2>&1 || die "FreeBSD detected but 'pkg' not found"
            log "Using package manager: pkg (FreeBSD)"
            update_pkg_freebsd
            return $?
            ;;
        OpenBSD)
            command -v pkg_add >/dev/null 2>&1 || die "OpenBSD detected but 'pkg_add' not found"
            log "Using package manager: pkg_add (OpenBSD)"
            update_pkg_add_openbsd
            return $?
            ;;
    esac

    local entry bin handler
    for entry in $MANAGERS; do
        bin="${entry%%:*}"
        handler="${entry##*:}"
        if command -v "$bin" >/dev/null 2>&1; then
            log "Using package manager: ${bin}"
            "$handler"
            return $?
        fi
    done

    die "no supported package manager found on this system"
}

main() {
    print_os_info
    detect_and_run
    local status=$?
    [ "$status" -eq 0 ] && log "Done."
    return "$status"
}

main
exit $?
