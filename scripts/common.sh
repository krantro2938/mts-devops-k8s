# shellcheck shell=bash
# Shared helpers for all scripts. Source it, do not execute it.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# shellcheck source=../versions.env
source "${REPO_ROOT}/versions.env"

if [[ -t 1 ]]; then
  C_BLUE=$'\e[1;34m' C_GREEN=$'\e[1;32m' C_YELLOW=$'\e[1;33m' C_RED=$'\e[1;31m' C_OFF=$'\e[0m'
else
  C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_OFF=''
fi

log()  { printf '%s==>%s %s\n' "${C_BLUE}" "${C_OFF}" "$*"; }
ok()   { printf '%s ✔%s  %s\n' "${C_GREEN}" "${C_OFF}" "$*"; }
warn() { printf '%s !%s  %s\n' "${C_YELLOW}" "${C_OFF}" "$*" >&2; }
die()  { printf '%s ✘%s  %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; exit 1; }

trap 'die "failed at ${BASH_SOURCE[0]##*/}:${LINENO}: ${BASH_COMMAND}"' ERR

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# retry <attempts> <sleep-seconds> <command...>
retry() {
  local attempts=$1 delay=$2 i
  shift 2
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then return 0; fi
    ((i < attempts)) && sleep "$delay"
  done
  return 1
}

# IPv4 address of the interface that holds the default route.
node_ip() {
  if [[ -n "${NODE_IP:-}" ]]; then
    echo "${NODE_IP}"
    return
  fi
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}
