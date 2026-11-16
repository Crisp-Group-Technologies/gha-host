#!/usr/bin/env bash
# registry-login.sh - log the host Docker daemon in to the runner image registry.
# REGISTRY_AUTH: auto | ecr | basic | none. Nothing to do for local/anonymous images.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
load_config

[[ ${BUILD_IMAGE:-false} == true ]] && { log "BUILD_IMAGE=true, no registry login needed"; exit 0; }
[[ -n ${RUNNER_IMAGE:-} ]] || die "RUNNER_IMAGE is not set"

host="${RUNNER_IMAGE%%/*}"
if [[ $host != *.* && $host != *:* && $host != localhost ]]; then
  log "image '$RUNNER_IMAGE' has no registry host (Docker Hub / local), skipping login"
  [[ ${REGISTRY_AUTH:-auto} == auto ]] && exit 0
fi

mode="${REGISTRY_AUTH:-auto}"
if [[ $mode == auto ]]; then
  if [[ $host =~ ^[0-9]+\.dkr\.ecr(-fips)?\.([a-z0-9-]+)\.amazonaws\.com(\.cn)?$ ]]; then
    mode=ecr
  elif [[ -n ${REGISTRY_USERNAME:-} ]]; then
    mode=basic
  else
    mode=none
  fi
fi

case "$mode" in
  none) log "registry auth: none (anonymous pull from $host)" ;;
  ecr)
    command -v aws >/dev/null || die "aws CLI not found (needed for ECR login)"
    region="${ECR_REGION:-}"
    if [[ -z $region && $host =~ \.ecr(-fips)?\.([a-z0-9-]+)\.amazonaws\. ]]; then region="${BASH_REMATCH[2]}"; fi
    [[ -n $region ]] || die "cannot determine ECR region; set ECR_REGION"
    aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$host" >/dev/null
    log "logged in to ECR $host"
    ;;
  basic)
    [[ -n ${REGISTRY_USERNAME:-} ]] || die "REGISTRY_USERNAME is required for basic registry auth"
    pw="$GHA_RUN_SECRETS/registry-password"
    [[ -r $pw ]] || pw="${REGISTRY_PASSWORD_FILE:-}"
    [[ -r $pw ]] || die "registry password file not found (REGISTRY_PASSWORD_FILE)"
    docker login --username "$REGISTRY_USERNAME" --password-stdin "$host" <"$pw" >/dev/null
    log "logged in to $host as $REGISTRY_USERNAME"
    ;;
  *) die "REGISTRY_AUTH must be auto, ecr, basic or none (got '$mode')" ;;
esac
