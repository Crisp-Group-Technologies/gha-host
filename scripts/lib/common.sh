#!/usr/bin/env bash
# Shared helpers for gha-host scripts. Source this file, do not execute it.

GHA_HOME="${GHA_HOME:-/opt/gha-host}"
GHA_ETC="${GHA_ETC:-/etc/gha-host}"
GHA_ENV_FILE="${GHA_ENV_FILE:-$GHA_ETC/gha-host.env}"
GHA_RUN_SECRETS="${GHA_RUN_SECRETS:-/run/gha-host}"

# Every setting that lives in gha-host.env (and can be set by flag, env or SSM).
CONFIG_VARS=(
  GH_ORG GH_API_URL GH_SERVER_URL GH_AUTH GH_APP_ID GH_APP_INSTALLATION_ID
  GH_APP_KEY_FILE GH_PAT_FILE RUNNER_GROUP
  RUNNER_COUNT RUNNER_MODE HOST_NAME RUNNER_LABELS RUNNER_PER_INDEX_LABEL
  RUNNER_CPUS RUNNER_MEMORY RUNNER_EXTRA_VOLUMES RUNNER_DISABLE_UPDATE RUNNER_UID
  RUNNER_IMAGE BUILD_IMAGE INSTALL_AWS_CLI INSTALL_AZURE_CLI INSTALL_NODEJS NODE_MAJOR
  POSTGRES_CLIENT_VERSION PLAYWRIGHT_DEPS_VERSION QEMU_BINFMT
  REGISTRY_AUTH REGISTRY_USERNAME REGISTRY_PASSWORD_FILE ECR_REGION
  PLATFORM DATA_DISK DATA_DIR DATA_FS BUILDKIT_KEEP_STORAGE SSM_PATH
  PRUNE_INTERVAL PRUNE_SOFT_PCT PRUNE_HARD_PCT PRUNE_IMAGE_AGE
  AUTO_UPDATE UPDATE_SCHEDULE UPDATE_DRAIN_TIMEOUT
)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() {
  printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2
  exit 1
}

require_root() { [[ $EUID -eq 0 ]] || die "run as root (use sudo)"; }

set_defaults() {
  : "${GH_API_URL:=https://api.github.com}"
  : "${GH_SERVER_URL:=https://github.com}"
  : "${GH_AUTH:=auto}"
  : "${GH_APP_KEY_FILE:=$GHA_ETC/github-app.pem}"
  : "${GH_PAT_FILE:=$GHA_ETC/pat}"
  : "${RUNNER_GROUP:=Default}"
  : "${RUNNER_MODE:=persistent}"
  : "${RUNNER_LABELS:=gha-host}"
  : "${RUNNER_PER_INDEX_LABEL:=false}"
  : "${RUNNER_DISABLE_UPDATE:=false}"
  : "${RUNNER_UID:=1001}"
  : "${BUILD_IMAGE:=false}"
  : "${INSTALL_AWS_CLI:=true}"
  : "${INSTALL_AZURE_CLI:=true}"
  : "${INSTALL_NODEJS:=true}"
  : "${NODE_MAJOR:=24}"
  : "${QEMU_BINFMT:=false}"
  : "${REGISTRY_AUTH:=auto}"
  : "${REGISTRY_PASSWORD_FILE:=$GHA_ETC/registry-password}"
  : "${DATA_DIR:=/data}"
  : "${DATA_FS:=ext4}"
  : "${PRUNE_INTERVAL:=hourly}"
  : "${PRUNE_SOFT_PCT:=75}"
  : "${PRUNE_HARD_PCT:=90}"
  : "${PRUNE_IMAGE_AGE:=168h}"
  : "${AUTO_UPDATE:=false}"
  : "${UPDATE_SCHEDULE:=Sun 03:00}"
  : "${UPDATE_DRAIN_TIMEOUT:=3600}"
  : "${HOST_NAME:=$(hostname -s)}"
  if [[ -z "${RUNNER_COUNT:-}" ]]; then
    RUNNER_COUNT=$(($(nproc) / 2))
    ((RUNNER_COUNT >= 1)) || RUNNER_COUNT=1
  fi
}

# Load the installed config for runtime scripts (prune, healthcheck, ...).
# `load_config raw` keeps GH_*_FILE pointing at the configured source files
# instead of the staged tmpfs copies (used by load-secrets.sh itself).
load_config() {
  if [[ -f $GHA_ENV_FILE ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$GHA_ENV_FILE"
    set +a
  fi
  set_defaults
  if [[ ${1:-} != raw ]]; then
    # runtime copies of the secrets (staged by load-secrets.sh) win over the source paths
    if [[ -r $GHA_RUN_SECRETS/pat ]]; then GH_PAT_FILE="$GHA_RUN_SECRETS/pat"; fi
    if [[ -r $GHA_RUN_SECRETS/app-key ]]; then GH_APP_KEY_FILE="$GHA_RUN_SECRETS/app-key"; fi
  fi
  export GH_ORG GH_API_URL GH_AUTH GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_KEY_FILE GH_PAT_FILE
  return 0
}

# apply_kv_file FILE: apply KEY=VALUE lines, accepting known config keys only
apply_kv_file() {
  local file=$1 line key val v ok
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    [[ -z $line || $line == \#* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    val="${val%\"}"
    val="${val#\"}"
    ok=0
    for v in "${CONFIG_VARS[@]}"; do [[ $v == "$key" ]] && ok=1 && break; done
    if ((ok)); then printf -v "$key" '%s' "$val"; else warn "ignoring unknown key '$key' in $file"; fi
  done <"$file"
}

# --- platform --------------------------------------------------------------
_IMDS_TOKEN=""
imds_token() {
  [[ -n $_IMDS_TOKEN ]] && return 0
  _IMDS_TOKEN=$(curl -fsS -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || return 1
}
imds() { # imds PATH
  imds_token || return 1
  curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null
}
is_ec2() { imds_token && imds instance-id >/dev/null; }
detect_platform() { if is_ec2; then echo ec2; else echo vm; fi; }

# keep_storage_gb: BuildKit cache budget, 60% of the data filesystem (min 10)
keep_storage() {
  if [[ -n ${BUILDKIT_KEEP_STORAGE:-} ]]; then
    echo "$BUILDKIT_KEEP_STORAGE"
    return
  fi
  local gb
  gb=$(df -BG --output=size "${DATA_DIR:-/data}" 2>/dev/null | tail -1 | tr -dc '0-9')
  gb=$((${gb:-50} * 60 / 100))
  ((gb >= 10)) || gb=10
  echo "${gb}GB"
}

docker_gid() { getent group docker | cut -d: -f3; }

# build_runner_image [extra docker build args]: build runner/Dockerfile as $RUNNER_IMAGE
# with every image option from the config. Used by install.sh and update.sh.
build_runner_image() {
  docker build "$@" -f "$GHA_HOME/runner/Dockerfile" -t "$RUNNER_IMAGE" \
    --build-arg "INSTALL_AWS_CLI=$INSTALL_AWS_CLI" \
    --build-arg "INSTALL_AZURE_CLI=$INSTALL_AZURE_CLI" \
    --build-arg "INSTALL_NODEJS=$INSTALL_NODEJS" \
    --build-arg "NODE_MAJOR=$NODE_MAJOR" \
    --build-arg "POSTGRES_CLIENT_VERSION=${POSTGRES_CLIENT_VERSION:-}" \
    --build-arg "PLAYWRIGHT_DEPS_VERSION=${PLAYWRIGHT_DEPS_VERSION:-}" \
    "$GHA_HOME"
}
