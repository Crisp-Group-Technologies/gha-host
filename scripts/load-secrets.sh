#!/usr/bin/env bash
# load-secrets.sh - stage runtime copies of secrets in tmpfs (/run/gha-host).
# Source per secret: the configured local file if present, otherwise SSM
# Parameter Store at $SSM_PATH/<name>. Runs at every service start, because
# /run is cleared on reboot. Staged files are 0400 and owned by the runner uid
# (registry password: root only).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
load_config raw

install -d -m 0755 "$GHA_RUN_SECRETS"
if [[ -n ${SSM_PATH:-} ]]; then
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$(imds placement/region || true)}"
fi

# stage NAME SOURCE_FILE OWNER_UID
stage() {
  local name=$1 src=$2 owner=$3 dest="$GHA_RUN_SECRETS/$1" val
  if [[ -r $src ]]; then
    install -m 0400 -o "$owner" -g "$owner" "$src" "$dest.tmp"
    mv -f "$dest.tmp" "$dest"
    log "staged $name from $src"
  elif [[ -n ${SSM_PATH:-} ]] && command -v aws >/dev/null 2>&1 &&
    val=$(aws ssm get-parameter --name "$SSM_PATH/$name" --with-decryption \
      --query Parameter.Value --output text 2>/dev/null); then
    (umask 0277 && printf '%s\n' "$val" >"$dest.tmp")
    chown "$owner:$owner" "$dest.tmp"
    mv -f "$dest.tmp" "$dest"
    log "staged $name from SSM $SSM_PATH/$name"
  else
    rm -f "$dest"
  fi
}

stage pat "$GH_PAT_FILE" "$RUNNER_UID"
stage app-key "$GH_APP_KEY_FILE" "$RUNNER_UID"
stage registry-password "$REGISTRY_PASSWORD_FILE" 0
