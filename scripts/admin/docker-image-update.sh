#!/usr/bin/env bash
#
# docker-image-update.sh — Batch-update remotely hosted Docker images.
#
# Walks every image present on the local Docker daemon and re-pulls it from
# its origin registry. An image counts as remotely hosted only if one of its
# RepoDigests belongs to the same repository as the repo:tag being checked;
# this skips images built locally and images merely retagged from a pulled
# one (which inherit the original's digests). Images that were built locally
# and then pushed look identical to pulled ones, so use --skip for those.
# This does NOT recreate or restart any containers — it only refreshes the
# image cache, so a container must still be recreated
# (e.g. `docker compose up -d`, `docker stop && docker rm && docker run`)
# to actually start using an updated image.
#
# Usage:
#   ./docker-image-update.sh [-y|--yes] [-n|--dry-run] [-s|--skip PATTERN]... [-f|--file FILE]... [-h|--help]
#
#   -y, --yes          Non-interactive: skip the confirmation prompt.
#   -n, --dry-run      List what would be pulled, without pulling anything.
#   -s, --skip PATTERN Never pull images matching PATTERN (shell glob, matched
#                      against both repo:tag and repo). Repeatable.
#                      e.g. --skip 'myorg/*' --skip redis:latest
#   -f, --file FILE    Read skip patterns from FILE, one per line (same glob
#                      semantics as --skip). Blank lines and lines starting
#                      with '#' are ignored. Repeatable; combines with --skip.
#   -h, --help         Show this help text.

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ASSUME_YES=0
DRY_RUN=0
SKIP_PATTERNS=()

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [-y|--yes] [-n|--dry-run] [-s|--skip PATTERN]... [-f|--file FILE]... [-h|--help]

  -y, --yes          Non-interactive: skip the confirmation prompt.
  -n, --dry-run      List what would be pulled, without pulling anything.
  -s, --skip PATTERN Never pull images matching PATTERN (shell glob, matched
                     against both repo:tag and repo). Repeatable.
  -f, --file FILE    Read skip patterns from FILE, one per line. Blank lines
                     and lines starting with '#' are ignored. Repeatable.
  -h, --help         Show this help text.
EOF
}

# Append each pattern in the given file (one per line) to SKIP_PATTERNS.
load_skip_file() {
    local file="$1" line
    [ -f "$file" ] && [ -r "$file" ] || { echo "${SCRIPT_NAME}: cannot read skip file '$file'" >&2; exit 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        SKIP_PATTERNS+=("$line")
    done < "$file"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)
            ASSUME_YES=1
            ;;
        -n|--dry-run)
            DRY_RUN=1
            ;;
        -s|--skip)
            [ $# -ge 2 ] || { echo "${SCRIPT_NAME}: $1 requires a pattern" >&2; usage >&2; exit 1; }
            SKIP_PATTERNS+=("$2")
            shift
            ;;
        --skip=*)
            SKIP_PATTERNS+=("${1#--skip=}")
            ;;
        -f|--file)
            [ $# -ge 2 ] || { echo "${SCRIPT_NAME}: $1 requires a file" >&2; usage >&2; exit 1; }
            load_skip_file "$2"
            shift
            ;;
        --file=*)
            load_skip_file "${1#--file=}"
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

command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"

# Figure out whether we can talk to the daemon directly, or need sudo.
DOCKER_CMD=(docker)
if ! docker info >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
        DOCKER_CMD=(sudo docker)
    else
        die "cannot connect to the Docker daemon (tried with and without sudo)"
    fi
fi

# Every locally present image reference, excluding dangling <none> entries
# (dangling images have no repo:tag to pull by).
mapfile -t ALL_IMAGES < <("${DOCKER_CMD[@]}" images --format '{{.Repository}}:{{.Tag}}' | grep -v '^<none>:' | grep -v ':<none>$')

if [ "${#ALL_IMAGES[@]}" -eq 0 ]; then
    log "No local Docker images found."
    exit 0
fi

REMOTE_IMAGES=()
LOCAL_IMAGES=()
SKIPPED_IMAGES=()

# Strip the implicit Docker Hub prefixes so "nginx", "library/nginx" and
# "docker.io/library/nginx" compare equal.
normalize_repo() {
    local r="$1"
    r="${r#docker.io/}"
    r="${r#index.docker.io/}"
    r="${r#library/}"
    printf '%s' "$r"
}

# True if the ref matches any --skip pattern (against repo:tag or repo).
is_skipped() {
    local ref="$1" repo="${1%:*}" pattern
    for pattern in "${SKIP_PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$ref" == $pattern || "$repo" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# True if one of the ref's RepoDigests belongs to the ref's own repository.
# RepoDigests are per image ID, so a retagged image inherits the digests of
# the image it was tagged from; comparing repo names filters those out.
has_own_digest() {
    local ref="$1" want digest
    want="$(normalize_repo "${ref%:*}")"
    while IFS= read -r digest; do
        [ -n "$digest" ] || continue
        [ "$(normalize_repo "${digest%@*}")" = "$want" ] && return 0
    done < <("${DOCKER_CMD[@]}" image inspect "$ref" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null)
    return 1
}

for ref in "${ALL_IMAGES[@]}"; do
    if is_skipped "$ref"; then
        SKIPPED_IMAGES+=("$ref")
    elif has_own_digest "$ref"; then
        REMOTE_IMAGES+=("$ref")
    else
        LOCAL_IMAGES+=("$ref")
    fi
done

log "Found ${#ALL_IMAGES[@]} image(s): ${#REMOTE_IMAGES[@]} remotely hosted, ${#LOCAL_IMAGES[@]} built locally, ${#SKIPPED_IMAGES[@]} skipped by --skip."

if [ "${#SKIPPED_IMAGES[@]}" -gt 0 ]; then
    log "Skipping image(s) matching --skip:"
    for ref in "${SKIPPED_IMAGES[@]}"; do
        printf '      - %s\n' "$ref"
    done
fi

if [ "${#LOCAL_IMAGES[@]}" -gt 0 ]; then
    log "Skipping locally built image(s) (no registry to pull from):"
    for ref in "${LOCAL_IMAGES[@]}"; do
        printf '      - %s\n' "$ref"
    done
fi

if [ "${#REMOTE_IMAGES[@]}" -eq 0 ]; then
    log "No remotely hosted images to update."
    exit 0
fi

log "Remotely hosted image(s) to update:"
for ref in "${REMOTE_IMAGES[@]}"; do
    printf '      - %s\n' "$ref"
done

if [ "$DRY_RUN" -eq 1 ]; then
    for ref in "${REMOTE_IMAGES[@]}"; do
        printf '[dry-run] docker pull %s\n' "$ref"
    done
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Proceed pulling %d image(s)? [y/N] ' "${#REMOTE_IMAGES[@]}"
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) log "Aborted."; exit 0 ;;
    esac
fi

UPDATED=()
UNCHANGED=()
FAILED=()

for ref in "${REMOTE_IMAGES[@]}"; do
    before_id="$("${DOCKER_CMD[@]}" image inspect "$ref" --format '{{.Id}}' 2>/dev/null)"

    log "Pulling ${ref} ..."
    if ! "${DOCKER_CMD[@]}" pull "$ref"; then
        warn "failed to pull ${ref}"
        FAILED+=("$ref")
        continue
    fi

    after_id="$("${DOCKER_CMD[@]}" image inspect "$ref" --format '{{.Id}}' 2>/dev/null)"
    if [ "$before_id" != "$after_id" ]; then
        UPDATED+=("$ref")
    else
        UNCHANGED+=("$ref")
    fi
done

echo
log "Summary:"
printf '      updated:        %d\n' "${#UPDATED[@]}"
for ref in "${UPDATED[@]}"; do printf '        - %s\n' "$ref"; done
printf '      already latest: %d\n' "${#UNCHANGED[@]}"
printf '      failed:         %d\n' "${#FAILED[@]}"
for ref in "${FAILED[@]}"; do printf '        - %s\n' "$ref"; done
printf '      skipped local:  %d\n' "${#LOCAL_IMAGES[@]}"
printf '      skipped (--skip): %d\n' "${#SKIPPED_IMAGES[@]}"

if [ "${#UPDATED[@]}" -gt 0 ]; then
    log "Note: pulled images are not in use until their containers are recreated."
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
    exit 1
fi
