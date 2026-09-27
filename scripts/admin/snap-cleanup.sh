#!/usr/bin/env bash
#
# snap-cleanup.sh — Remove disabled old Snap revisions.
#
# Snap-only, deliberately: needs root (see scripts/admin/snap-update.sh for
# the same reasoning, confirmed live: "access denied (try with sudo)").
# Flatpak's equivalent, scripts/user/flatpak-cleanup.sh, never needs root
# and lives in user/ instead.
#
# Snap is the closer analog to the distro kernel-cleanup script: snapd
# keeps old revisions on disk by design (`refresh.retain`, default 3
# total) so you can roll back. `snap list --all` shows them, old ones
# marked "disabled" — confirmed live. Removing a specific old revision
# (`snap remove <name> --revision=<rev>`) is the standard, documented
# cleanup, and unlike Flatpak's --unused, it IS safely listable first —
# `snap list --all` is a pure read; nothing is removed until --yes.
#
# Usage:
#   ./snap-cleanup.sh [-y|--yes] [-n|--dry-run] [-h|--help]

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [-y|--yes] [-n|--dry-run] [-h|--help]

  -y, --yes       Actually remove disabled old revisions (default is to
                   only list them).
  -n, --dry-run   Explicit no-op (also the default with no flags).
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
warn() { printf 'warning: %s\n' "$*" >&2; }
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

log "Scanning for disabled old revisions ..."

# snap list --all marks every non-current revision of a snap "disabled" in
# the Notes column; the active one for that name has no such mark.
NAMES=()
REVS=()
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        Name*) continue ;;
    esac
    if printf '%s' "$line" | grep -qw disabled; then
        name="$(awk '{print $1}' <<< "$line")"
        rev="$(awk '{print $3}' <<< "$line")"
        NAMES+=("$name")
        REVS+=("$rev")
        log "Disabled: ${name} (revision ${rev})"
    fi
done < <(snap list --all 2>/dev/null)

if [ "${#NAMES[@]}" -eq 0 ]; then
    log "No disabled old revisions found."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -ne 1 ]; then
    for i in "${!NAMES[@]}"; do
        printf '[would run] sudo snap remove %s --revision=%s\n' "${NAMES[$i]}" "${REVS[$i]}"
    done
    log "Nothing removed. Re-run with --yes to actually remove these revisions."
    log "Note: snapd's own 'refresh.retain' setting (default 3) controls how many revisions it keeps going forward; this only cleans up what has already accumulated."
    exit 0
fi

log "Removing ${#NAMES[@]} disabled revision(s) (requires root) ..."
REMOVED=()
FAILED=()
for i in "${!NAMES[@]}"; do
    if as_root snap remove "${NAMES[$i]}" --revision="${REVS[$i]}"; then
        REMOVED+=("${NAMES[$i]}/${REVS[$i]}")
    else
        warn "failed to remove ${NAMES[$i]} revision ${REVS[$i]}"
        FAILED+=("${NAMES[$i]}/${REVS[$i]}")
    fi
done

echo
log "Summary:"
printf '      removed: %d (%s)\n' "${#REMOVED[@]}" "${REMOVED[*]:-none}"
printf '      failed:  %d (%s)\n' "${#FAILED[@]}" "${FAILED[*]:-none}"

[ "${#FAILED[@]}" -gt 0 ] && exit 1
exit 0
