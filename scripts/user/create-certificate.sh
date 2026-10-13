#!/usr/bin/env bash
#
# create-certificate.sh - create SSL, SSH, or Let's Encrypt certificates/keys.
#
# Usage:
#   create-certificate.sh <type> <name> [options]
#
# Types:
#   ssl          Local CA (created once, then reused) plus a leaf certificate
#                signed by it, with Subject Alternative Names.
#   ssh          SSH key pair (ed25519 by default).
#   letsencrypt  Real certificate via certbot (requires certbot and root).
#
# Common options:
#   -o, --output-dir DIR   Where to write files (default: $PWD/_output)
#   -f, --force            Overwrite existing files
#   -h, --help             Show this help
#
# ssl options:
#   -d, --domain NAME      Hostname or IP for the certificate; repeatable.
#                          Default: localhost and 127.0.0.1
#   -D, --days N           Leaf validity in days (default: 825)
#   -b, --bits N           RSA key size (default: 4096)
#       --subject-base S   Subject prefix (default: /C=US/O=Development-Certificates)
#
# ssh options:
#   -a, --algorithm ALG    ed25519 (default) or rsa
#   -b, --bits N           RSA key size (default: 4096)
#   -c, --comment TEXT     Key comment (default: empty)
#
# letsencrypt options:
#   -d, --domain NAME      Domain to certify; repeatable, at least one required
#   -e, --email ADDR       Registration email (required)
#   -w, --webroot DIR      Use the webroot plugin (default: standalone)
#       --staging          Use the Let's Encrypt staging server
#
# Examples:
#   create-certificate.sh ssl devbox -d devbox.local -d 192.168.1.10
#   create-certificate.sh ssh github -c "me@laptop"
#   create-certificate.sh ssh legacy -a rsa -b 4096
#   create-certificate.sh letsencrypt example -d example.com -e me@example.com

set -euo pipefail

readonly PROGRAM="${0##*/}"

# defaults
output_dir="${PWD}/_output"
force=false
domains=()
days=825
bits=4096
algorithm="ed25519"
comment=""
email=""
webroot=""
staging=false
subject_base="/C=US/O=Development-Certificates"

usage() {
  # print the leading comment block (after the shebang) as help text
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

die() {
  echo "${PROGRAM}: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# refuse to clobber existing files unless --force was given
check_writable() {
  local path
  for path in "$@"; do
    if [[ -e "${path}" && "${force}" != true ]]; then
      die "${path} already exists (use --force to overwrite)"
    fi
  done
}

is_ip() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ || "$1" == *:* ]]
}

# ---------------------------------------------------------------------------
# ssl: local CA + leaf certificate
# ---------------------------------------------------------------------------
create_ssl() {
  local name="$1"
  need openssl

  local dir="${output_dir}/ssl"
  local ca_key="${dir}/ca.key" ca_crt="${dir}/ca.crt"
  local key="${dir}/${name}.key" csr="${dir}/${name}.csr" crt="${dir}/${name}.crt"

  ((${#domains[@]})) || domains=(localhost 127.0.0.1)

  mkdir -p "${dir}"
  chmod 700 "${dir}"
  check_writable "${key}" "${crt}"

  # The CA is created once and reused so every leaf cert chains to the same
  # root; trust ca.crt once and all certificates made here are trusted.
  if [[ ! -f "${ca_key}" || ! -f "${ca_crt}" ]]; then
    echo "Creating local CA in ${dir}"
    openssl req -x509 -new -nodes -sha256 \
      -days 3650 \
      -newkey "rsa:${bits}" \
      -subj "${subject_base}/CN=Development-Root-CA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -keyout "${ca_key}" \
      -out "${ca_crt}"
  else
    echo "Reusing existing CA in ${dir}"
  fi

  local san="" domain
  for domain in "${domains[@]}"; do
    if is_ip "${domain}"; then
      san+="IP:${domain},"
    else
      san+="DNS:${domain},"
    fi
  done
  san="${san%,}"

  local ext
  ext="$(mktemp)"
  cat >"${ext}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san}
EOF

  echo "Creating certificate for: ${domains[*]}"
  openssl req -new -nodes -sha256 \
    -newkey "rsa:${bits}" \
    -subj "${subject_base}/CN=${domains[0]}" \
    -keyout "${key}" \
    -out "${csr}"

  openssl x509 -req -sha256 \
    -days "${days}" \
    -in "${csr}" \
    -CA "${ca_crt}" -CAkey "${ca_key}" -CAcreateserial \
    -extfile "${ext}" \
    -out "${crt}"

  rm -f "${csr}" "${ext}"
  chmod 600 "${ca_key}" "${key}"
  chmod 644 "${ca_crt}" "${crt}"

  echo
  echo "CA certificate (trust this): ${ca_crt}"
  echo "Certificate:                 ${crt}"
  echo "Private key:                 ${key}"
}

# ---------------------------------------------------------------------------
# ssh: key pair
# ---------------------------------------------------------------------------
create_ssh() {
  local name="$1"
  need ssh-keygen

  local dir="${output_dir}/ssh"
  local key="${dir}/${name}"

  mkdir -p "${dir}"
  chmod 700 "${dir}"
  check_writable "${key}" "${key}.pub"
  rm -f "${key}" "${key}.pub"

  case "${algorithm}" in
    ed25519) ssh-keygen -t ed25519 -a 100 -C "${comment}" -f "${key}" ;;
    rsa)     ssh-keygen -t rsa -b "${bits}" -a 100 -C "${comment}" -f "${key}" ;;
    *)       die "unsupported ssh algorithm: ${algorithm} (use ed25519 or rsa)" ;;
  esac

  chmod 600 "${key}"
  chmod 644 "${key}.pub"

  echo
  echo "Private key: ${key}"
  echo "Public key:  ${key}.pub"
  echo "Install it:  ssh-copy-id -i ${key}.pub user@host"
}

# ---------------------------------------------------------------------------
# letsencrypt: certbot wrapper
# ---------------------------------------------------------------------------
create_letsencrypt() {
  local name="$1"
  need certbot

  ((${#domains[@]})) || die "letsencrypt requires at least one --domain"
  [[ -n "${email}" ]] || die "letsencrypt requires --email"

  local args=(certonly --non-interactive --agree-tos
              --email "${email}" --cert-name "${name}")
  if [[ -n "${webroot}" ]]; then
    args+=(--webroot -w "${webroot}")
  else
    args+=(--standalone)
  fi
  [[ "${staging}" == true ]] && args+=(--staging)

  local domain
  for domain in "${domains[@]}"; do
    args+=(-d "${domain}")
  done

  if ((EUID != 0)); then
    die "certbot needs root; re-run with sudo"
  fi

  certbot "${args[@]}"
  echo
  echo "Certificates are in /etc/letsencrypt/live/${name}/"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local positional=()

  while (($#)); do
    case "$1" in
      -h|--help)         usage; exit 0 ;;
      -o|--output-dir)   output_dir="${2:?$1 requires a value}"; shift 2 ;;
      -f|--force)        force=true; shift ;;
      -d|--domain)       domains+=("${2:?$1 requires a value}"); shift 2 ;;
      -D|--days)         days="${2:?$1 requires a value}"; shift 2 ;;
      -b|--bits)         bits="${2:?$1 requires a value}"; shift 2 ;;
      -a|--algorithm)    algorithm="${2:?$1 requires a value}"; shift 2 ;;
      -c|--comment)      comment="${2?$1 requires a value}"; shift 2 ;;
      -e|--email)        email="${2:?$1 requires a value}"; shift 2 ;;
      -w|--webroot)      webroot="${2:?$1 requires a value}"; shift 2 ;;
      --subject-base)    subject_base="${2:?$1 requires a value}"; shift 2 ;;
      --staging)         staging=true; shift ;;
      --)                shift; positional+=("$@"); break ;;
      -*)                die "unknown option: $1 (see --help)" ;;
      *)                 positional+=("$1"); shift ;;
    esac
  done

  ((${#positional[@]} == 2)) || { usage >&2; exit 1; }
  local type="${positional[0]}" name="${positional[1]}"

  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "name may only contain letters, digits, '.', '_' and '-'"
  [[ "${days}" =~ ^[0-9]+$ && "${bits}" =~ ^[0-9]+$ ]] \
    || die "--days and --bits must be integers"

  # keys must never exist with group/world access, even briefly; public files
  # are loosened to 644 explicitly after creation
  umask 077

  case "${type}" in
    ssl)         create_ssl "${name}" ;;
    ssh)         create_ssh "${name}" ;;
    letsencrypt) create_letsencrypt "${name}" ;;
    *)           die "unknown certificate type: ${type} (use ssl, ssh, or letsencrypt)" ;;
  esac
}

main "$@"
