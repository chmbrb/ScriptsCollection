#!/usr/bin/env bash
#
# screenshot.sh — Interactive area-select screenshot, portable across
# desktop environments.
#
# Enters "screenshot mode": select a rectangular area of the screen with
# the mouse, and it's saved to ~/Pictures/Screenshots/ with a timestamped
# filename (permissions locked to 0600), then copied to the clipboard
# (xclip on X11, wl-copy on Wayland — best-effort; a missing/failing
# clipboard tool only warns, since the screenshot is already saved by then).
#
# The real compatibility boundary here is the display server and desktop
# environment, not the Linux distribution — a distro's package manager has
# no bearing on which screenshot mechanism actually works:
#
#   - X11 (any window manager: i3, XFCE, Openbox, KDE-on-X11, GNOME-on-X11,
#     ...) shares one screenshot API, so any of these work everywhere:
#     import (ImageMagick) -> scrot -> maim.
#   - Wayland has no single universal mechanism. GNOME and KDE Plasma use
#     their own compositor-integrated tools (gnome-screenshot, spectacle).
#     Everything else (Sway, Hyprland, river, wayfire, labwc, ...) is
#     covered generically by grim+slurp, which work via the shared
#     wlr-screencopy protocol most non-GNOME/KDE compositors implement —
#     this is what gives "unforeseen" compositors a real chance of working
#     without being individually named here.
#   - Wayland is preferred over X11 whenever $WAYLAND_DISPLAY is set, even
#     if $DISPLAY is also set (common under Xwayland): capturing through
#     Xwayland only sees Xwayland-rendered content, not the real compositor
#     output.
#
# Usage:
#   ./screenshot.sh [-h|--help]

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [-h|--help]

Select a rectangular screen area with the mouse; save it to
\$HOME/Pictures/Screenshots/ with a timestamped filename.
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        echo "${SCRIPT_NAME}: unknown argument '$1'" >&2
        usage >&2
        exit 1
        ;;
esac

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

path="$HOME/Pictures/Screenshots/"
mkdir -p "$path" || die "failed to create ${path}"
filename="$(date "+%Y-%m-%d_%H-%M-%S")_screenshot.png"
screenshot="${path}${filename}"

capture_x11() {
    if command -v import >/dev/null 2>&1; then
        import "$screenshot"
    elif command -v scrot >/dev/null 2>&1; then
        scrot -s "$screenshot"
    elif command -v maim >/dev/null 2>&1; then
        maim -s "$screenshot"
    else
        die "no X11 screenshot tool found; install one of: imagemagick (import), scrot, maim"
    fi
}

capture_wayland() {
    local desktop
    desktop="$(printf '%s %s' "${XDG_CURRENT_DESKTOP:-}" "${DESKTOP_SESSION:-}" | tr '[:upper:]' '[:lower:]')"

    case "$desktop" in
        *gnome*)
            command -v gnome-screenshot >/dev/null 2>&1 \
                || die "GNOME (Wayland) detected but 'gnome-screenshot' is not installed"
            gnome-screenshot -a -f "$screenshot"
            ;;
        *kde*|*plasma*)
            command -v spectacle >/dev/null 2>&1 \
                || die "KDE Plasma (Wayland) detected but 'spectacle' is not installed"
            # spectacle: -b background (no capture-mode GUI), -n no notification,
            # -r rectangular region, -o output file.
            spectacle -b -n -r -o "$screenshot"
            ;;
        *)
            if command -v grim >/dev/null 2>&1 && command -v slurp >/dev/null 2>&1; then
                grim -g "$(slurp)" "$screenshot"
            else
                die "Wayland compositor '${XDG_CURRENT_DESKTOP:-unknown}' has no known screenshot path here; install grim+slurp (works on most wlroots-based compositors: Sway, Hyprland, river, wayfire, ...), or use this compositor's native screenshot tool"
            fi
            ;;
    esac
}

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    capture_wayland
elif [ -n "${DISPLAY:-}" ]; then
    capture_x11
else
    die "no graphical session detected (\$WAYLAND_DISPLAY and \$DISPLAY are both unset)"
fi

copy_to_clipboard() {
    # Best-effort: the screenshot is already saved at this point, so a
    # missing/failing clipboard tool is a warning, not a failure.
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        if command -v wl-copy >/dev/null 2>&1; then
            wl-copy --type image/png < "$screenshot" \
                && log "Copied to clipboard (wl-copy)." \
                || warn "wl-copy failed; screenshot saved but not copied to clipboard"
        else
            warn "'wl-copy' not found (wl-clipboard package); screenshot saved but not copied to clipboard"
        fi
    elif [ -n "${DISPLAY:-}" ]; then
        if command -v xclip >/dev/null 2>&1; then
            xclip -selection clipboard -t image/png -i "$screenshot" \
                && log "Copied to clipboard (xclip)." \
                || warn "xclip failed; screenshot saved but not copied to clipboard"
        else
            warn "'xclip' not found; screenshot saved but not copied to clipboard (xsel isn't used here — it doesn't reliably handle binary image data)"
        fi
    fi
}

if [ -s "$screenshot" ]; then
    chmod 0600 "$screenshot"
    log "Saved: ${screenshot}"
    copy_to_clipboard
else
    rm -f "$screenshot"
    die "no screenshot was saved (selection cancelled, or the capture tool failed)"
fi
