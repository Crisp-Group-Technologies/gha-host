#!/usr/bin/env bash
# healthcheck.sh - exit 0 if healthy, 1 otherwise. Prints one line per check.
# Options: --no-api   skip the GitHub API check (offline checks only)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
# shellcheck source=lib/github.sh
source "$SELF_DIR/lib/github.sh"
load_config

use_api=1
[[ ${1:-} == --no-api ]] && use_api=0
fail=0
ok() { printf 'OK    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }

if docker info >/dev/null 2>&1; then ok "docker daemon responding"; else bad "docker daemon not responding"; fi

running=$(docker ps -q --filter label=gha-host.runner --filter status=running 2>/dev/null | wc -l)
if ((running >= RUNNER_COUNT)); then ok "runner containers: $running/$RUNNER_COUNT"; else bad "runner containers: $running/$RUNNER_COUNT running"; fi

use=$(df --output=pcent "$DATA_DIR" | tail -1 | tr -dc '0-9')
if ((use < PRUNE_SOFT_PCT)); then
  ok "disk $DATA_DIR at ${use}%"
elif ((use < PRUNE_HARD_PCT)); then
  ok "disk $DATA_DIR at ${use}% (above soft limit ${PRUNE_SOFT_PCT}%, prune will trim)"
else
  bad "disk $DATA_DIR at ${use}% (>= ${PRUNE_HARD_PCT}%)"
fi

if ((use_api)); then
  if runners=$(gh_runners_with_prefix "$HOST_NAME-" 2>/dev/null); then
    online=$(jq '[.[] | select(.status == "online")] | length' <<<"$runners")
    busy=$(jq '[.[] | select(.busy)] | length' <<<"$runners")
    if ((online >= RUNNER_COUNT)); then ok "runners online in GitHub: $online/$RUNNER_COUNT ($busy busy)"; else bad "runners online in GitHub: $online/$RUNNER_COUNT"; fi
  else
    bad "could not query the GitHub API (credentials/permissions/network)"
  fi
fi

exit "$fail"
