#!/usr/bin/env bash
#
# find-large-files.sh — Find the largest files on the system, for when
# ncdu isn't available.
#
# Rebuilt from two one-liners: one that parsed `ls -lh` column output
# (fragile — breaks on filenames with spaces, and on symlinks whose extra
# "-> target" field shifts the column count) and a `find / -size +10M
# -size -12M -ls` example with no -type/-xdev, meaning it would also
# traverse into /proc, /sys, /dev and any other mounted filesystem from
# the true root — confirmed live that those are all separate mounts on a
# real system, which is exactly what -xdev (the default here) skips.
#
# This is deliberately an admin-scoped tool: run as root (or via sudo) for
# genuinely whole-machine coverage into directories a regular user can't
# read; run unprivileged and it still works, just limited to what the
# invoking user can see (find silently skips unreadable paths rather than
# erroring the whole run, and permission-denied noise is suppressed by
# default — pass --verbose to see it).
#
# Portable across GNU and BSD find/stat (verified: this machine's `find`
# is actually `bfs`, a GNU-compatible alternative, and its `stat` is GNU-
# style; the byte-size lookup tries GNU syntax first, falling back to BSD
# syntax, rather than assuming one or the other).
#
# Usage:
#   ./find-large-files.sh [PATH] [-s|--min-size SIZE] [-S|--max-size SIZE]
#                          [-n|--count N] [-t|--type TYPE]
#                          [-x|--cross-filesystems] [-v|--verbose] [-h|--help]
#
#   PATH                  Directory to search (default: /).
#   -s, --min-size SIZE   Only files at least this size (default: 100M).
#                          Accepts find's own size suffixes: c/k/M/G/T.
#   -S, --max-size SIZE   Only files at most this size (optional).
#   -n, --count N         Show the top N largest matches (default: 25).
#   -t, --type TYPE       find -type to match (default: f, regular files).
#                          Note: for directories this is a single entry's
#                          own metadata size, not a recursive total — that
#                          needs `du`, a different kind of tool.
#   -x, --cross-filesystems
#                         Don't stay on PATH's filesystem (default: stay,
#                         via -xdev — this is what skips /proc, /sys, /dev
#                         and other mounts automatically).
#   -v, --verbose         Show permission-denied and other find errors
#                          (suppressed by default).
#   -h, --help            Show this help text.

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ROOT="/"
MIN_SIZE="100M"
MAX_SIZE=""
COUNT=25
FIND_TYPE="f"
XDEV=1
VERBOSE=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [PATH] [-s|--min-size SIZE] [-S|--max-size SIZE]
                       [-n|--count N] [-t|--type TYPE]
                       [-x|--cross-filesystems] [-v|--verbose] [-h|--help]

  PATH                  Directory to search (default: /).
  -s, --min-size SIZE   Only files at least this size (default: 100M).
                         Accepts find's own size suffixes: c/k/M/G/T.
  -S, --max-size SIZE   Only files at most this size (optional).
  -n, --count N         Show the top N largest matches (default: 25).
  -t, --type TYPE       find -type to match (default: f, regular files).
  -x, --cross-filesystems
                        Don't stay on PATH's filesystem (default: stay).
  -v, --verbose         Show permission-denied and other find errors.
  -h, --help            Show this help text.
EOF
}

PATH_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--min-size) MIN_SIZE="${2:-}"; shift ;;
        --min-size=*) MIN_SIZE="${1#*=}" ;;
        -S|--max-size) MAX_SIZE="${2:-}"; shift ;;
        --max-size=*) MAX_SIZE="${1#*=}" ;;
        -n|--count) COUNT="${2:-}"; shift ;;
        --count=*) COUNT="${1#*=}" ;;
        -t|--type) FIND_TYPE="${2:-}"; shift ;;
        --type=*) FIND_TYPE="${1#*=}" ;;
        -x|--cross-filesystems) XDEV=0 ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help) usage; exit 0 ;;
        -*)
            echo "${SCRIPT_NAME}: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [ "$PATH_SET" -eq 1 ]; then
                echo "${SCRIPT_NAME}: only one path may be specified" >&2
                exit 1
            fi
            ROOT="$1"
            PATH_SET=1
            ;;
    esac
    shift
done

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -d "$ROOT" ] || die "'${ROOT}' is not a directory"
case "$COUNT" in ''|*[!0-9]*) die "invalid --count value '${COUNT}': must be a positive integer" ;; esac

# find's size suffixes: c=bytes, k/M/G/T=KiB/MiB/GiB/TiB. A bare number
# defaults to 512-byte blocks, which surprises people expecting bytes —
# normalize a suffix-less value to exact bytes instead.
normalize_size() {
    case "$1" in
        *[ckMGT]) printf '%s' "$1" ;;
        *) printf '%sc' "$1" ;;
    esac
}

stat_bytes() {
    stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1" 2>/dev/null
}

human_size() {
    local bytes="$1" units=(B K M G T P) i=0
    while [ "$bytes" -ge 1024 ] && [ "$i" -lt 5 ]; do
        bytes=$((bytes / 1024))
        i=$((i + 1))
    done
    printf '%d%s' "$bytes" "${units[$i]}"
}

FIND_ARGS=("$ROOT")
[ "$XDEV" -eq 1 ] && FIND_ARGS+=(-xdev)
FIND_ARGS+=(-type "$FIND_TYPE" -size "+$(normalize_size "$MIN_SIZE")")
[ -n "$MAX_SIZE" ] && FIND_ARGS+=(-size "-$(normalize_size "$MAX_SIZE")")

log "Searching ${ROOT} for files >= ${MIN_SIZE}${MAX_SIZE:+ and <= ${MAX_SIZE}} (this may take a while) ..."

RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

if [ "$VERBOSE" -eq 1 ]; then
    find "${FIND_ARGS[@]}" -print0
else
    find "${FIND_ARGS[@]}" -print0 2>/dev/null
fi | while IFS= read -r -d '' file; do
    bytes="$(stat_bytes "$file")"
    [ -n "$bytes" ] && printf '%s\t%s\n' "$bytes" "$file"
done > "$RESULTS"

TOTAL="$(wc -l < "$RESULTS")"
if [ "$TOTAL" -eq 0 ]; then
    log "No files found matching the size criteria."
    exit 0
fi

log "Found ${TOTAL} matching file(s); showing top ${COUNT} by size:"
echo

# Sort in place first, then let `head` read a plain file rather than a live
# pipe from `sort` — piping sort straight into head causes head's early
# exit (after N lines) to SIGPIPE sort under `pipefail`, which would leak
# a spurious 141 exit status up through this being the script's last command.
sort -t $'\t' -k1,1nr -o "$RESULTS" "$RESULTS"
head -n "$COUNT" "$RESULTS" | while IFS=$'\t' read -r bytes file; do
    printf '%8s  %s\n' "$(human_size "$bytes")" "$file"
done
