#!/usr/bin/env bash
#
# pip-upgrade.sh — Safely upgrade all outdated pip packages in the active
# virtual environment.
#
# Rebuilt from a one-liner that had a real, concrete bug (the quotes and
# double-dash had been mangled into smart quotes/an em dash somewhere along
# the way — `pip freeze — local` and `grep -v ‘^\-e’` aren't valid shell,
# so the original never actually ran) plus several best-practice issues
# this version fixes:
#
#   - Refuses to run against a non-isolated Python (no active venv/conda
#     env) unless --force is passed — the single biggest risk in the
#     original, since a stray unactivated shell would have upgraded
#     packages system/user-wide instead.
#   - Uses `pip list --outdated --format=json` instead of parsing
#     `pip freeze` with grep/cut — structured data instead of fragile
#     text-munging, and it already excludes packages with no newer
#     version available.
#   - Editable (`pip install -e .`) packages are still excluded, but via
#     the `editable_project_location` field pip actually reports, not a
#     `grep -v '^-e'` line-prefix guess.
#   - Upgrades everything in one joint `pip install --upgrade` call so
#     pip's resolver can consider all the new versions together (upgrading
#     one package at a time, like the original's `xargs -n1`, can make the
#     resolver thrash a shared dependency back and forth between
#     packages). If that joint call fails, falls back to per-package
#     upgrades so one broken package doesn't block every other package in
#     the batch — confirmed via live testing that pip aborts the *entire*
#     joint transaction if even one requested package can't be resolved.
#   - Lists what's outdated by default; nothing is upgraded without -y.
#
# Usage:
#   ./pip-upgrade.sh [-y|--yes] [-n|--dry-run] [-x|--exclude NAME] [--force] [-h|--help]
#
#   -y, --yes         Actually perform the upgrade (default is to only list
#                      outdated packages).
#   -n, --dry-run     Explicit no-op: list what would be upgraded (also the
#                      default with no flags).
#   -x, --exclude NAME  Skip this package (repeatable, or comma-separated).
#   --force           Allow running outside an active venv/conda env.
#   -h, --help        Show this help text.

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ASSUME_YES=0
DRY_RUN=0
FORCE=0
EXCLUDE=()

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [-y|--yes] [-n|--dry-run] [-x|--exclude NAME] [--force] [-h|--help]

  -y, --yes           Actually perform the upgrade (default is to only list
                       outdated packages).
  -n, --dry-run       Explicit no-op: list what would be upgraded (also the
                       default with no flags).
  -x, --exclude NAME  Skip this package (repeatable, or comma-separated).
  --force             Allow running outside an active venv/conda env.
  -h, --help          Show this help text.
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
        -x|--exclude)
            IFS=',' read -ra _names <<< "${2:-}"
            EXCLUDE+=("${_names[@]}")
            shift
            ;;
        --exclude=*)
            IFS=',' read -ra _names <<< "${1#*=}"
            EXCLUDE+=("${_names[@]}")
            ;;
        --force)
            FORCE=1
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

PYTHON_BIN="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON_BIN" ] || die "no python3/python interpreter found on PATH"

# Safety guard: refuse to touch a non-isolated Python. Checks both the
# activation env vars (what a user would normally have set) and asks
# Python itself for a second opinion (sys.prefix != sys.base_prefix),
# since env vars alone could be stale or manually exported without an
# actually-active environment.
in_isolated_env() {
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        return 0
    fi
    if [ -n "${CONDA_PREFIX:-}" ] && [ "${CONDA_DEFAULT_ENV:-}" != "base" ]; then
        return 0
    fi
    return 1
}

if ! in_isolated_env; then
    if [ "$FORCE" -eq 1 ]; then
        warn "no active venv/conda env detected; proceeding anyway because --force was given"
    else
        die "no active virtual environment detected (\$VIRTUAL_ENV / \$CONDA_PREFIX unset, or conda env is 'base'). Activate one first, or pass --force to upgrade the system/user Python's packages anyway."
    fi
fi

if ! "$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)'; then
    if [ "$FORCE" -eq 1 ]; then
        warn "'${PYTHON_BIN}' does not report an isolated environment (sys.prefix == sys.base_prefix); proceeding anyway because --force was given"
    else
        die "'${PYTHON_BIN}' does not report an isolated environment (sys.prefix == sys.base_prefix) — refusing to touch it without --force"
    fi
fi

log "Using interpreter: ${PYTHON_BIN} ($("$PYTHON_BIN" -c 'import sys; print(sys.prefix)'))"

# --- Step 1: upgrade pip itself first ---------------------------------------

if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -ne 1 ]; then
    printf '[would run] %s -m pip install --upgrade pip\n' "$PYTHON_BIN"
else
    log "Upgrading pip ..."
    "$PYTHON_BIN" -m pip install --upgrade pip || die "failed to upgrade pip itself"
fi

# --- Step 2: gather outdated + editable packages (structured, not text-munged) ---

mapfile -t OUTDATED < <("$PYTHON_BIN" -m pip list --outdated --format=json 2>/dev/null | "$PYTHON_BIN" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for pkg in data:
    print("{}\t{}\t{}".format(pkg["name"], pkg["version"], pkg["latest_version"]))
')

mapfile -t EDITABLE_NAMES < <("$PYTHON_BIN" -m pip list --format=json 2>/dev/null | "$PYTHON_BIN" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for pkg in data:
    if "editable_project_location" in pkg:
        print(pkg["name"])
')

is_in() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

TO_UPGRADE=()
SKIPPED_EDITABLE=()
SKIPPED_EXCLUDED=()

for line in "${OUTDATED[@]:-}"; do
    [ -z "$line" ] && continue
    name="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    current="${rest%%$'\t'*}"
    latest="${rest#*$'\t'}"

    [ "$name" = "pip" ] && continue  # already handled in step 1

    if is_in "$name" "${EDITABLE_NAMES[@]:-}"; then
        SKIPPED_EDITABLE+=("$name")
        continue
    fi
    if is_in "$name" "${EXCLUDE[@]:-}"; then
        SKIPPED_EXCLUDED+=("$name")
        continue
    fi

    TO_UPGRADE+=("$name")
    log "Outdated: ${name} (${current} -> ${latest})"
done

[ "${#SKIPPED_EDITABLE[@]}" -gt 0 ] && log "Skipping editable/local package(s): ${SKIPPED_EDITABLE[*]}"
[ "${#SKIPPED_EXCLUDED[@]}" -gt 0 ] && log "Skipping excluded package(s): ${SKIPPED_EXCLUDED[*]}"

if [ "${#TO_UPGRADE[@]}" -eq 0 ]; then
    log "Everything else is already up to date."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -ne 1 ]; then
    printf '[would run] %s -m pip install --upgrade' "$PYTHON_BIN"
    printf ' %q' "${TO_UPGRADE[@]}"
    printf '\n'
    log "Nothing upgraded. Re-run with --yes to actually upgrade."
    exit 0
fi

# --- Step 3: joint upgrade, falling back to per-package on failure ----------

log "Upgrading ${#TO_UPGRADE[@]} package(s) in one resolver pass ..."
if "$PYTHON_BIN" -m pip install --upgrade "${TO_UPGRADE[@]}"; then
    log "Done: upgraded ${TO_UPGRADE[*]}"
    exit 0
fi

warn "joint upgrade failed; falling back to one-at-a-time so a single bad package doesn't block the rest"

UPGRADED=()
FAILED=()
for name in "${TO_UPGRADE[@]}"; do
    log "Upgrading ${name} ..."
    if "$PYTHON_BIN" -m pip install --upgrade "$name"; then
        UPGRADED+=("$name")
    else
        warn "failed to upgrade ${name}"
        FAILED+=("$name")
    fi
done

echo
log "Summary:"
printf '      upgraded: %d (%s)\n' "${#UPGRADED[@]}" "${UPGRADED[*]:-none}"
printf '      failed:   %d (%s)\n' "${#FAILED[@]}" "${FAILED[*]:-none}"

[ "${#FAILED[@]}" -gt 0 ] && exit 1
exit 0
