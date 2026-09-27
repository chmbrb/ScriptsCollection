#!/usr/bin/env bash
#
# flatpak-update.sh — Update installed Flatpak apps/runtimes.
#
# Flatpak-only, deliberately: Flatpak never requires root (both --user and
# --system scope operations run as the invoking user; system-scope changes
# go through polkit, not classic sudo). Snap is the opposite — it always
# requires root, confirmed live ("access denied (try with sudo)") — so its
# equivalent lives in scripts/admin/snap-update.sh instead. Anything
# root-required belongs in admin/, anything a normal user can run belongs
# in user/; this script and that one used to be combined and were split
# apart for exactly this reason.
#
# Listing is the default; nothing is updated without -y/--yes. Getting a
# safe, non-mutating "what's pending" preview took real verification:
# `flatpak update --noninteractive` (even without -y) turned out to still
# apply pending changes when tested live — it means "don't prompt", not
# "don't act". The genuinely read-only command is
# `flatpak remote-ls --updates <remote>`, confirmed by testing it against
# a real pending update without it touching anything.
#
# Usage:
#   ./flatpak-update.sh [-y|--yes] [-n|--dry-run] [-h|--help]

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

if ! command -v flatpak >/dev/null 2>&1; then
    log "Flatpak not found on this system."
    exit 0
fi

any_pending=0
for scope in "" "--user"; do
    scope_label="system"; [ "$scope" = "--user" ] && scope_label="user"

    mapfile -t remotes < <(flatpak remotes ${scope:+$scope} --columns=name 2>/dev/null)
    [ "${#remotes[@]}" -eq 0 ] && continue

    for remote in "${remotes[@]}"; do
        [ -z "$remote" ] && continue
        mapfile -t pending < <(flatpak remote-ls ${scope:+$scope} --updates "$remote" --columns=application,branch,version 2>/dev/null)
        for line in "${pending[@]:-}"; do
            [ -z "$line" ] && continue
            any_pending=1
            log "[${scope_label}/${remote}] ${line}"
        done
    done
done

if [ "$any_pending" -eq 0 ]; then
    log "Everything up to date."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -ne 1 ]; then
    printf '[would run] flatpak update -y --noninteractive\n'
    printf '[would run] flatpak update -y --noninteractive --user\n'
    log "Nothing updated. Re-run with --yes to actually update."
    exit 0
fi

log "Updating ..."
status=0
flatpak update -y --noninteractive || status=1
flatpak update -y --noninteractive --user || status=1
exit "$status"
