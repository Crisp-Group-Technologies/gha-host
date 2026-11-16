#!/usr/bin/env bash
# prune.sh - watermark-based Docker cleanup that tries to keep the build cache warm.
#   always:          stopped job containers > 24h, dangling images
#   >= SOFT_PCT:     trim build cache to its budget, remove unused images older than PRUNE_IMAGE_AGE
#   >= HARD_PCT:     docker system prune -af  (cache is lost; builds will be slow afterwards)
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
load_config

pct() { df --output=pcent "$DATA_DIR" | tail -1 | tr -dc '0-9'; }
before=$(pct)
log "disk usage on $DATA_DIR: ${before}%"

docker container prune -f --filter "until=24h" --filter "label!=gha-host.runner" >/dev/null
docker image prune -f >/dev/null

now=$(pct)
if ((now >= PRUNE_HARD_PCT)); then
  warn "usage ${now}% >= ${PRUNE_HARD_PCT}%: full prune, the build cache will be lost"
  docker system prune -af >/dev/null
elif ((now >= PRUNE_SOFT_PCT)); then
  keep="$(keep_storage)"
  log "usage ${now}% >= ${PRUNE_SOFT_PCT}%: trimming build cache to $keep and old unused images"
  docker builder prune -f --reserved-space "$keep" >/dev/null 2>&1 ||
    docker builder prune -f --keep-storage "$keep" >/dev/null
  docker image prune -af --filter "until=$PRUNE_IMAGE_AGE" >/dev/null
fi

after=$(pct)
log "done: ${before}% -> ${after}%"
if ((after >= PRUNE_HARD_PCT)); then
  warn "still at ${after}% after pruning: grow the disk or lower BUILDKIT_KEEP_STORAGE"
  exit 1
fi
