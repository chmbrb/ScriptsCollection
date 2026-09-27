#!/usr/bin/env bash
#
# set-boot-target.sh — Switch the systemd default boot target between
# graphical (GUI login) and multi-user (text-only) mode.
#
# Two ways to drive it:
#   - Explicit: pass 'graphical' or 'text' to set that target directly.
#     Safe to run repeatedly — re-running with the same argument is a no-op.
#   - Toggle: run with no argument to flip between whichever of the two
#     is currently set and the other one.
#
# Setting the default target only affects the *next* boot. Pass --now to
# also switch the running system immediately via `systemctl isolate`.
#
# Usage:
#   ./set-boot-target.sh [graphical|text] [--now] [-y|--yes] [-n|--dry-run] [-h|--help]
#
#   graphical       Set default (and optionally current) target to graphical.target.
#   text            Set default (and optionally current) target to multi-user.target.
#                   (no argument = toggle between the two)
#   --now           Also apply the target to the running system immediately,
#                   not just on next boot. WARNING: switching away from
#                   graphical.target while logged in via a GUI session will
#                   end that session right away.
#   -y, --yes       Non-interactive: skip the --now confirmation prompt.
#   -n, --dry-run   Print what would be done, without changing anything.
#   -h, --help      Show this help text.

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
ASSUME_YES=0
SWITCH_NOW=0
MODE=""

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [graphical|text] [--now] [-y|--yes] [-n|--dry-run] [-h|--help]

  graphical       Set default (and optionally current) target to graphical.target.
  text            Set default (and optionally current) target to multi-user.target.
                  (no argument = toggle between the two)
  --now           Also apply the target to the running system immediately,
                  not just on next boot. WARNING: switching away from
                  graphical.target while logged in via a GUI session will
                  end that session right away.
  -y, --yes       Non-interactive: skip the --now confirmation prompt.
  -n, --dry-run   Print what would be done, without changing anything.
  -h, --help      Show this help text.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        graphical|text|multi-user)
            if [ -n "$MODE" ]; then
                echo "${SCRIPT_NAME}: only one target may be specified (got '${MODE}' and '$1')" >&2
                exit 1
            fi
            MODE="$1"
            ;;
        --now)
            SWITCH_NOW=1
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
            echo "${SCRIPT_NAME}: unknown argument '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v systemctl >/dev/null 2>&1 || die "this script requires systemd (systemctl not found)"

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

CURRENT="$(systemctl get-default 2>/dev/null)" || die "failed to query the current default target"

case "$MODE" in
    graphical)
        TARGET="graphical.target"
        ;;
    text|multi-user)
        TARGET="multi-user.target"
        ;;
    "")
        case "$CURRENT" in
            graphical.target)
                TARGET="multi-user.target"
                ;;
            multi-user.target)
                TARGET="graphical.target"
                ;;
            *)
                die "current default target '${CURRENT}' is neither graphical.target nor multi-user.target; specify one explicitly ('${SCRIPT_NAME} graphical' or '${SCRIPT_NAME} text')"
                ;;
        esac
        log "No target given — toggling from current default (${CURRENT})."
        ;;
esac

log "Current default target: ${CURRENT}"
log "Requested default target: ${TARGET}"

if [ "$CURRENT" = "$TARGET" ]; then
    log "Default target is already ${TARGET}; nothing to do."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] systemctl set-default %s\n' "$TARGET"
    if [ "$SWITCH_NOW" -eq 1 ]; then
        printf '[dry-run] systemctl isolate %s\n' "$TARGET"
    fi
    exit 0
fi

as_root systemctl set-default "$TARGET" || die "failed to set default target to ${TARGET}"
log "Default target set to ${TARGET} (takes effect on next boot)."

if [ "$SWITCH_NOW" -eq 1 ]; then
    if [ "$ASSUME_YES" -ne 1 ]; then
        warn "This will switch the running system to ${TARGET} immediately."
        warn "If you are in a graphical session, moving to multi-user.target will end it right away."
        printf 'Proceed? [y/N] '
        read -r reply
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) log "Skipped immediate switch; the new target takes effect on next boot."; exit 0 ;;
        esac
    fi
    log "Switching running system to ${TARGET} now ..."
    as_root systemctl isolate "$TARGET" || die "failed to isolate ${TARGET}"
else
    log "Reboot for the change to take effect, or re-run with --now to switch immediately."
fi
