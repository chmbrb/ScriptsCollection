#!/usr/bin/env bash
#
# flatpak-cleanup.sh — Reclaim disk space from unused Flatpak runtimes.
#
# Flatpak-only, deliberately: never requires root (see flatpak-update.sh
# for the same reasoning). Snap's equivalent, scripts/admin/snap-cleanup.sh,
# needs root and lives in admin/ instead.
#
# Flatpak doesn't keep old app versions installed side by side — updating
# replaces the active commit, and the old commit's data becomes
# unreferenced OSTree garbage. The standard, official cleanup is
# `flatpak uninstall --unused` (runtimes/locales no longer required by any
# installed app). There is, verified live, no dry-run for this: even
# `--noninteractive` alone (no -y) still actually performed a real removal
# when tested against genuinely unused runtimes on a real system. So
# unlike other cleanup scripts in this repo, this one cannot show an exact
# "here's what would be removed" preview — only --yes actually invokes it.
#
# Usage:
#   ./flatpak-cleanup.sh [-y|--yes] [-n|--dry-run] [-h|--help]

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [-y|--yes] [-n|--dry-run] [-h|--help]

  -y, --yes       Actually remove unused runtimes (default is to only list
                   currently installed runtimes for context).
  -n, --dry-run   Explicit no-op (also the default with no flags).
  -h, --help      Show this help text.

Note: Flatpak has no non-mutating way to preview '--unused' cleanup (verified
live — even its --noninteractive flag alone still applies the removal), so
list mode can only show currently installed runtimes, not exactly what
--unused would remove.
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

if ! command -v flatpak >/dev/null 2>&1; then
    log "Flatpak not found on this system."
    exit 0
fi

log "Currently installed runtimes (see --help note above):"
any=0
for scope in "" "--user"; do
    mapfile -t runtimes < <(flatpak list ${scope:+$scope} --runtime --columns=application,branch 2>/dev/null)
    for line in "${runtimes[@]:-}"; do
        [ -z "$line" ] && continue
        any=1
        log "  [${scope:-system}] ${line}"
    done
done
[ "$any" -eq 0 ] && log "  (none installed)"

if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -ne 1 ]; then
    printf '[would run] flatpak uninstall --unused -y --noninteractive\n'
    printf '[would run] flatpak uninstall --unused -y --noninteractive --user\n'
    log "Nothing removed. Re-run with --yes to actually check-and-remove unused runtimes."
    exit 0
fi

log "Removing unused runtimes ..."
status=0
flatpak uninstall --unused -y --noninteractive || status=1
flatpak uninstall --unused -y --noninteractive --user || status=1
exit "$status"
