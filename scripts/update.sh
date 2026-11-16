#!/usr/bin/env bash
# update.sh - refresh the runner image and roll it out one runner at a time,
# waiting for each runner to go idle first so running jobs are not cancelled.
#
#   update.sh             refresh image, recreate outdated runners that are idle
#   update.sh --dry-run   refresh the image and list what would be recreated
#
# Exit codes: 0 all runners current, 1 error, 3 some runners were still busy after
# UPDATE_DRAIN_TIMEOUT and were left on the old image (the next run retries them).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
# shellcheck source=lib/github.sh
source "$SELF_DIR/lib/github.sh"
load_config

DRY=0
[[ ${1:-} == --dry-run ]] && DRY=1
POLL=15
LOCK="${GHA_UPDATE_LOCK:-/run/gha-update.lock}"

exec 9>"$LOCK"
flock -n 9 || die "another update is already running"
[[ -n ${RUNNER_IMAGE:-} ]] || die "RUNNER_IMAGE is not set"
cd "$GHA_HOME/compose"

# runner_state NAME -> "busy" | "idle" | "gone" ; returns 1 if GitHub cannot be queried
runner_state() {
  local list
  list="$(gh_runners_with_prefix "$1")" || return 1
  jq -r --arg n "$1" '[.[] | select(.name == $n)] | if length == 0 then "gone" elif .[0].busy then "busy" else "idle" end' <<<"$list"
}

wait_online() { # NAME TIMEOUT_SECONDS
  local deadline=$((SECONDS + $2)) list
  while ((SECONDS < deadline)); do
    list="$(gh_runners_with_prefix "$1" 2>/dev/null || echo '[]')"
    [[ $(jq -r --arg n "$1" '[.[] | select(.name == $n and .status == "online")] | length' <<<"$list") -ge 1 ]] && return 0
    sleep 5
  done
  return 1
}

# --- 1. refresh the image ------------------------------------------------------------
if [[ $BUILD_IMAGE == true ]]; then
  log "rebuilding $RUNNER_IMAGE (--pull for a fresh base image)"
  build_runner_image --pull
else
  "$GHA_HOME/scripts/registry-login.sh"
  log "pulling $RUNNER_IMAGE"
  docker pull "$RUNNER_IMAGE" >/dev/null
fi
want="$(docker image inspect -f '{{.Id}}' "$RUNNER_IMAGE")"

# --- 2. which runners are behind -----------------------------------------------------
outdated=()
for ((i = 1; i <= RUNNER_COUNT; i++)); do
  have="$(docker inspect -f '{{.Image}}' "gha-runner-$i" 2>/dev/null || echo none)"
  [[ $have == "$want" ]] || outdated+=("$i")
done
if ((${#outdated[@]} == 0)); then
  log "all $RUNNER_COUNT runners are on the current image"
  docker image prune -f >/dev/null
  exit 0
fi
log "runners to update: ${outdated[*]}"
if ((DRY)); then
  log "dry run: not touching any runner"
  exit 0
fi

# --- 3. roll them one at a time ------------------------------------------------------
updated=0
skipped=()
for i in "${outdated[@]}"; do
  name="$HOST_NAME-$i"
  deadline=$((SECONDS + UPDATE_DRAIN_TIMEOUT))
  ready=0
  while :; do
    if ! state="$(runner_state "$name")"; then
      warn "cannot query GitHub for $name; leaving it alone"
      break
    fi
    if [[ $state != busy ]]; then
      ready=1
      break
    fi
    ((SECONDS < deadline)) || break
    log "$name is busy, waiting (up to $((deadline - SECONDS))s)"
    sleep "$POLL"
  done
  if ((!ready)); then
    warn "skipping $name (busy or unknown after ${UPDATE_DRAIN_TIMEOUT}s); the next run retries it"
    skipped+=("$i")
    continue
  fi
  log "recreating gha-runner-$i"
  docker compose up -d --no-deps --force-recreate "runner-$i"
  if wait_online "$name" 180; then
    log "$name is back online"
    updated=$((updated + 1))
  else
    warn "$name did not come back online within 180s; stopping the roll-out so the rest keep serving jobs"
    exit 1
  fi
done

docker image prune -f >/dev/null
log "updated $updated runner(s); skipped ${#skipped[@]}${skipped:+ (${skipped[*]})}"
((${#skipped[@]} == 0)) || exit 3
