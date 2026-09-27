#!/usr/bin/env bash
#
# snap-update.sh — Update installed Snap packages.
#
# Snap-only, deliberately: unlike Flatpak (which never requires root — see
# scripts/user/flatpak-update.sh), Snap always requires root, confirmed
# live on a real system ("access denied (try with sudo)") since snaps are
# installed system-wide only, with no per-user install concept. That's
# exactly why this script lives in admin/ rather than user/.
#
# Listing is the default; nothing is updated without -y/--yes. The list
# command is genuinely read-only, confirmed both by its own documentation
# ("Show the new versions of snaps that would be updated with the next
# refresh") and by live testing against a real pending update.
#
# Usage:
#   ./snap-update.sh [-y|--yes] [-n|--dry-run] [-h|--help]

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [-y|--yes] [-n|--dry-run] [-h|--help]

  -y, --yes       Actually perform the update (default is to only list
                   pending updates).
  -n, --dry-run   Explicit no-op: list pending updates (also the default
                   with no flags).
  -h, --help      Show this help text.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "${SCRIPT_NAME}: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || die "not running as root and 'sudo' is not available"
        sudo "$@"
    fi
}

if ! command -v snap >/dev/null 2>&1; then
    log "Snap not found on this system."
    exit 0
fi

list_output="$(snap refresh --list 2>/dev/null)"

if ! printf '%s' "$list_output" | grep -q '^Name '; then
    log "Everything up to date."
    exit 0
fi

printf '%s\n' "$list_output" | while IFS= read -r line; do log "$line"; done

if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -ne 1 ]; then
    printf '[would run] sudo snap refresh\n'
    log "Nothing updated. Re-run with --yes to actually update."
    exit 0
fi

log "Updating (requires root) ..."
as_root snap refresh
