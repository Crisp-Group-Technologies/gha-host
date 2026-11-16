#!/usr/bin/env bash
# gha-host runner entrypoint.
# Mints a fresh registration token on every start, registers the runner with
# --replace, runs it, and deregisters on shutdown. No credentials are persisted.
set -euo pipefail

: "${GH_ORG:?GH_ORG is required}"
: "${RUNNER_NAME:?RUNNER_NAME is required}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_LABELS="${RUNNER_LABELS:-gha-host}"
RUNNER_MODE="${RUNNER_MODE:-persistent}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/home/runner/_work}"
SERVER_URL="${GH_SERVER_URL:-https://github.com}"

cd /home/runner
log() { echo "[gha-entrypoint] $*"; }

child=0
stopping=0
on_term() {
  stopping=1
  if [[ $child -ne 0 ]]; then kill -TERM "$child" 2>/dev/null || true; fi
}
trap on_term TERM INT

deregister() {
  [[ -f .runner ]] || return 0
  local tok
  if tok=$(gha-get-token remove 2>/dev/null); then
    ./config.sh remove --token "$tok" || log "deregister failed (the runner may already be gone)"
  else
    log "could not get a removal token; leaving the registration for GitHub to expire"
  fi
}

# --- workspace -------------------------------------------------------------
mkdir -p "$RUNNER_WORKDIR"
if [[ $RUNNER_MODE == ephemeral ]]; then
  # fresh workspace per job; files made by job containers may be root-owned
  sudo find "$RUNNER_WORKDIR" -mindepth 1 -delete 2>/dev/null ||
    find "$RUNNER_WORKDIR" -mindepth 1 -delete 2>/dev/null || true
fi

if ! docker info >/dev/null 2>&1; then
  log "WARNING: cannot talk to the Docker daemon (socket mounted? group_add set?)"
fi

# --- register --------------------------------------------------------------
rm -f .runner .credentials .credentials_rsaparams

token=""
for attempt in 1 2 3 4 5 6; do
  if token=$(gha-get-token registration); then break; fi
  log "registration token request failed (attempt $attempt/6), retrying in 10s"
  token=""
  sleep 10
done
[[ -n $token ]] || { log "giving up: no registration token"; exit 1; }

args=(--unattended --replace
  --url "$SERVER_URL/$GH_ORG" --token "$token"
  --name "$RUNNER_NAME" --labels "$RUNNER_LABELS"
  --runnergroup "$RUNNER_GROUP" --work "$RUNNER_WORKDIR")
[[ $RUNNER_MODE == ephemeral ]] && args+=(--ephemeral)
[[ ${RUNNER_DISABLE_UPDATE:-false} == true ]] && args+=(--disableupdate)

log "registering $RUNNER_NAME with $SERVER_URL/$GH_ORG (group=$RUNNER_GROUP, mode=$RUNNER_MODE, labels=$RUNNER_LABELS)"
./config.sh "${args[@]}"
unset token

# --- run -------------------------------------------------------------------
./run.sh &
child=$!
rc=0
wait "$child" || rc=$?
# a trapped signal interrupts the first wait; keep waiting for the real exit
while kill -0 "$child" 2>/dev/null; do
  rc=0
  wait "$child" || rc=$?
done

log "runner exited with status $rc (stopping=$stopping)"
deregister
exit "$rc"
