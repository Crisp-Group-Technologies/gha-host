#!/usr/bin/env bash
# gha-host uninstaller.
#   uninstall.sh                      stop runners, deregister them, remove services
#   uninstall.sh --purge              also delete config, workspaces and all Docker data
#   uninstall.sh --deregister-only    only remove this host's runners from GitHub
#   --name PREFIX                     runner name prefix to deregister (default: this host's)
#   --yes                             no prompts
# Docker itself, the data disk mount and /etc/fstab are left alone.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHA_HOME="${GHA_HOME:-$SELF_DIR}"
# shellcheck source=scripts/lib/common.sh
source "$GHA_HOME/scripts/lib/common.sh"
# shellcheck source=scripts/lib/github.sh
source "$GHA_HOME/scripts/lib/github.sh"

PURGE=0 DEREG_ONLY=0 YES=0 PREFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge) PURGE=1 ;;
    --deregister-only) DEREG_ONLY=1 ;;
    --name) PREFIX="${2:?--name needs a value}"; shift ;;
    --yes | -y) YES=1 ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
require_root
load_config
PREFIX="${PREFIX:-$HOST_NAME}-"

deregister_leftovers() {
  local runners id name
  runners="$(gh_runners_with_prefix "$PREFIX")" || { warn "could not list runners (credentials?)"; return 0; }
  while IFS=$'\t' read -r id name; do
    [[ -n $id ]] || continue
    log "removing runner $name ($id) from GitHub"
    gh_delete_runner "$id" || warn "could not remove $name (it may be busy)"
  done < <(jq -r '.[] | [.id, .name] | @tsv' <<<"$runners")
}

if ((DEREG_ONLY)); then
  deregister_leftovers
  exit 0
fi

if ((!YES)); then
  echo "This stops all gha-host runners and removes the services."
  ((PURGE)) && echo "--purge: it ALSO deletes $GHA_ETC, $GHA_HOME, $DATA_DIR/work and ALL Docker images/volumes/cache."
  read -r -p "Continue? [y/N] " ans
  [[ $ans == y || $ans == Y ]] || exit 1
fi

log "stopping services (runners deregister themselves on shutdown)"
systemctl disable --now gha-update.timer gha-prune.timer gha-host.service 2>/dev/null || true
deregister_leftovers
rm -f /etc/systemd/system/gha-host.service /etc/systemd/system/gha-prune.{service,timer} \
  /etc/systemd/system/gha-update.{service,timer}
systemctl daemon-reload
rm -rf "$GHA_RUN_SECRETS"

if ((PURGE)); then
  log "purging data"
  if command -v docker >/dev/null && systemctl is-active --quiet docker; then docker system prune -af --volumes >/dev/null || true; fi
  rm -rf "${DATA_DIR:?}/work"
  rm -rf "${GHA_ETC:?}"
  log "removing $GHA_HOME"
  rm -rf "${GHA_HOME:?}"
fi
log "done. Docker, $DATA_DIR and /etc/fstab were left in place."
