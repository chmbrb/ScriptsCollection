#!/usr/bin/env bash
#
# monitor-layout.sh — Switch between laptop/external monitor layouts under
# X11 (i3 and friends).
#
# Consolidates 4 hardcoded xrandr scripts (mirror, extend-right,
# extend-left, laptop-only) into one, driven by a mode argument — meant to
# be bound directly to i3 keybindings, e.g.:
#   bindsym $mod+F1 exec ~/scripts/monitor-layout.sh laptop-only
#   bindsym $mod+F2 exec ~/scripts/monitor-layout.sh right
#
# Portability: the original scripts hardcoded this machine's exact output
# names (eDP-1, HDMI-1, HDMI-1-2) and resolution (1920x1080) — neither
# carries over to another machine. Verified live on a *different* machine
# than the one the original scripts came from: its outputs are eDP-1,
# HDMI-2, HDMI-1-1 — proving the names really do vary. So instead:
#   - The laptop panel is auto-detected as the first connected output
#     matching eDP*/LVDS*/DSI* (the standard internal-panel naming
#     conventions across Intel/AMD/older laptops).
#   - The external monitor is auto-detected as the first other connected
#     output (if more than one is connected, the rest are reported but
#     not used — this assumes the laptop+single-external setup the
#     original scripts were built for).
#   - Resolutions are read from each output's own advertised preferred
#     mode (the '+'-marked entry in `xrandr --query`) instead of a
#     hardcoded 1920x1080, so this works whatever the panel/monitor's
#     actual native resolution is.
#   - Every other known output (any state) is explicitly turned off, the
#     same way the originals always forced the unused HDMI-1 off.
#
# This is X11-only by design, not a gap: i3 itself has no Wayland variant,
# so xrandr is the correct tool for this script's actual use case (unlike
# screenshot.sh, which had to cover both).
#
# Usage:
#   ./monitor-layout.sh <mode> [-n|--dry-run] [-h|--help]
#
#   Modes:
#     mirror              Panel and external show the same image (requires
#                          the external to support the panel's resolution).
#     extend-right, right External positioned to the right of the panel.
#     extend-left, left   External positioned to the left of the panel.
#     laptop-only, single, off
#                         Panel only; all other outputs turned off.
#     status              Show detected panel/external and exit (no changes).

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
MODE=""

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} <mode> [-n|--dry-run] [-h|--help]

Modes:
  mirror                        Panel and external show the same image.
  extend-right, right           External positioned to the right of the panel.
  extend-left, left             External positioned to the left of the panel.
  laptop-only, single, off      Panel only; all other outputs turned off.
  status                        Show detected panel/external and exit.

  -n, --dry-run   Print the xrandr command instead of running it.
  -h, --help      Show this help text.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        mirror|extend-right|right|extend-left|left|laptop-only|single|off|status)
            MODE="$1"
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

[ -n "$MODE" ] || { usage >&2; exit 1; }
[ -n "${DISPLAY:-}" ] || die "no X11 session detected (\$DISPLAY is unset) — this script is X11-only"
command -v xrandr >/dev/null 2>&1 || die "xrandr not found"

QUERY="$(xrandr --query)"

detect_panel() {
    printf '%s\n' "$QUERY" | awk '$2=="connected" && $1 ~ /^(eDP|LVDS|DSI)/ {print $1; exit}'
}

detect_connected() {
    printf '%s\n' "$QUERY" | awk '$2=="connected"{print $1}'
}

detect_all_outputs() {
    printf '%s\n' "$QUERY" | awk '$2=="connected"||$2=="disconnected"{print $1}'
}

get_preferred_mode() {
    local output="$1"
    printf '%s\n' "$QUERY" | awk -v out="$output" '
        $0 ~ "^"out" " { infield=1; next }
        /^[A-Za-z]/ { infield=0 }
        infield && /\+/ { print $1; exit }
    '
}

PANEL="$(detect_panel)"
[ -n "$PANEL" ] || die "no internal laptop panel output detected (expected eDP*/LVDS*/DSI*) — this script assumes a laptop + optional external monitor"

mapfile -t CONNECTED < <(detect_connected)
EXTERNAL=""
EXTRA_CONNECTED=()
for out in "${CONNECTED[@]}"; do
    [ "$out" = "$PANEL" ] && continue
    if [ -z "$EXTERNAL" ]; then
        EXTERNAL="$out"
    else
        EXTRA_CONNECTED+=("$out")
    fi
done
[ "${#EXTRA_CONNECTED[@]}" -gt 0 ] && warn "additional connected output(s) ignored (single-external setup assumed): ${EXTRA_CONNECTED[*]}"

if [ "$MODE" = "status" ]; then
    log "Panel:    ${PANEL} (preferred: $(get_preferred_mode "$PANEL"))"
    if [ -n "$EXTERNAL" ]; then
        log "External: ${EXTERNAL} (preferred: $(get_preferred_mode "$EXTERNAL"))"
    else
        log "External: none connected"
    fi
    log "All outputs: $(detect_all_outputs | tr '\n' ' ')"
    exit 0
fi

needs_external=0
case "$MODE" in
    mirror|extend-right|right|extend-left|left) needs_external=1 ;;
esac
if [ "$needs_external" -eq 1 ] && [ -z "$EXTERNAL" ]; then
    die "no external monitor detected; connect one first, or use 'laptop-only'"
fi

CMD=(xrandr)

case "$MODE" in
    mirror)
        panel_mode="$(get_preferred_mode "$PANEL")"
        [ -n "$panel_mode" ] || die "could not determine ${PANEL}'s preferred mode"
        CMD+=(--output "$PANEL" --primary --mode "$panel_mode" --pos 0x0)
        CMD+=(--output "$EXTERNAL" --mode "$panel_mode" --pos 0x0)
        ;;
    extend-right|right)
        panel_mode="$(get_preferred_mode "$PANEL")"
        ext_mode="$(get_preferred_mode "$EXTERNAL")"
        [ -n "$panel_mode" ] || die "could not determine ${PANEL}'s preferred mode"
        [ -n "$ext_mode" ] || die "could not determine ${EXTERNAL}'s preferred mode"
        panel_width="${panel_mode%%x*}"
        CMD+=(--output "$PANEL" --primary --mode "$panel_mode" --pos 0x0)
        CMD+=(--output "$EXTERNAL" --mode "$ext_mode" --pos "${panel_width}x0")
        ;;
    extend-left|left)
        panel_mode="$(get_preferred_mode "$PANEL")"
        ext_mode="$(get_preferred_mode "$EXTERNAL")"
        [ -n "$panel_mode" ] || die "could not determine ${PANEL}'s preferred mode"
        [ -n "$ext_mode" ] || die "could not determine ${EXTERNAL}'s preferred mode"
        ext_width="${ext_mode%%x*}"
        CMD+=(--output "$PANEL" --primary --mode "$panel_mode" --pos "${ext_width}x0")
        CMD+=(--output "$EXTERNAL" --mode "$ext_mode" --pos 0x0)
        ;;
    laptop-only|single|off)
        panel_mode="$(get_preferred_mode "$PANEL")"
        [ -n "$panel_mode" ] || die "could not determine ${PANEL}'s preferred mode"
        CMD+=(--output "$PANEL" --primary --mode "$panel_mode" --pos 0x0)
        ;;
esac

mapfile -t ALL_OUTPUTS < <(detect_all_outputs)
for out in "${ALL_OUTPUTS[@]}"; do
    if [ "$out" != "$PANEL" ] && [ "$out" != "$EXTERNAL" ]; then
        CMD+=(--output "$out" --off)
    elif [ "$out" = "$EXTERNAL" ] && [ "$needs_external" -eq 0 ]; then
        CMD+=(--output "$out" --off)
    fi
done

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run]'
    printf ' %q' "${CMD[@]}"
    printf '\n'
    exit 0
fi

log "Applying layout: ${MODE}"
"${CMD[@]}"
