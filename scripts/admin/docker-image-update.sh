#!/usr/bin/env bash
#
# docker-image-update.sh — Batch-update remotely hosted Docker images.
#
# Walks every image present on the local Docker daemon and re-pulls it from
# its origin registry, skipping images that were built locally (which have
# no RepoDigests, since they were never pulled from or pushed to a
# registry). This does NOT recreate or restart any containers — it only
# refreshes the image cache, so a container must still be recreated
# (e.g. `docker compose up -d`, `docker stop && docker rm && docker run`)
# to actually start using an updated image.
#
# Usage:
#   ./docker-image-update.sh [-y|--yes] [-n|--dry-run] [-h|--help]
#
#   -y, --yes       Non-interactive: skip the confirmation prompt.
#   -n, --dry-run   List what would be pulled, without pulling anything.
#   -h, --help      Show this help text.

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [-y|--yes] [-n|--dry-run] [-h|--help]

  -y, --yes       Non-interactive: skip the confirmation prompt.
  -n, --dry-run   List what would be pulled, without pulling anything.
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

for ref in "${ALL_IMAGES[@]}"; do
    digests="$("${DOCKER_CMD[@]}" image inspect "$ref" --format '{{json .RepoDigests}}' 2>/dev/null)"
    if [ -z "$digests" ] || [ "$digests" = "[]" ] || [ "$digests" = "null" ]; then
        LOCAL_IMAGES+=("$ref")
    else
        REMOTE_IMAGES+=("$ref")
    fi
done

log "Found ${#ALL_IMAGES[@]} image(s): ${#REMOTE_IMAGES[@]} remotely hosted, ${#LOCAL_IMAGES[@]} built locally."

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

if [ "${#UPDATED[@]}" -gt 0 ]; then
    log "Note: pulled images are not in use until their containers are recreated."
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
    exit 1
fi
