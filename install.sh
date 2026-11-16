#!/usr/bin/env bash
# gha-host installer: self-hosted GitHub Actions runners (org-level) on one VM.
# Idempotent: re-run it to upgrade or change settings. Run as root.
# See docs/install.md and docs/configuration.md.
set -euo pipefail

DEFAULT_REPO="OWNER/gha-host" # set to the repo that hosts this project
SELF="${BASH_SOURCE[0]:-$0}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || echo .)"

usage() {
  cat <<'EOF'
Usage: sudo bash install.sh --org ORG [options]

GitHub
  --org ORG                    GitHub org to register runners with (required first time)
  --runner-group NAME          org runner group (default: Default)
  --pat-file FILE              fine-grained PAT file (default /etc/gha-host/pat)
  --app-id ID                  GitHub App ID (use with --app-key)
  --installation-id ID         App installation ID (optional, looked up if omitted)
  --app-key FILE               App private key (default /etc/gha-host/github-app.pem)
  --auth auto|app|pat          default auto (App if configured, else PAT)
  --api-url URL / --server-url URL   GitHub Enterprise Server endpoints

Runners
  --runners N                  number of runner containers (default: vCPUs / 2)
  --mode persistent|ephemeral  default persistent
  --name NAME                  runner name prefix -> NAME-1..N (default: EC2 Name tag / hostname)
  --labels a,b,c               custom labels (default: gha-host). Replaces the default.
  --index-labels               also add runner-<n> labels
  --cpus N / --memory 6g       per-runner limits

Image
  --image REF                  runner image (default ghcr.io/<org>/gha-host-runner:latest,
                               or gha-host-runner:local with --build-image)
  --build-image                build runner/Dockerfile on this host instead of pulling
  --no-aws-cli / --no-azure-cli   leave a CLI out of the image (build only)
  --registry-auth auto|ecr|basic|none
  --registry-user USER / --registry-password-file FILE

Host
  --platform ec2|vm            default: auto-detect
  --data-disk DEV|auto         blank block device for Docker + workspaces
  --force-format               allow formatting a disk that already has data (DESTRUCTIVE)
  --data-dir DIR               mount point / data directory (default /data)
  --fs ext4|xfs                filesystem for a new data disk
  --ssm-path PATH              EC2: read config/secrets from SSM (e.g. /gha-host/my-host)

Other
  --auto-update                weekly drain-aware image update (gha-update.timer)
  --repo OWNER/NAME --ref REF  where to fetch the project from when install.sh is run standalone
  --reconfigure                re-apply with existing config (no other flags needed)
  --yes                        no prompts
  -h, --help
EOF
}

# --- pre-scan for bootstrap flags, then fetch the project if running standalone ----
REPO="${GHA_HOST_REPO:-$DEFAULT_REPO}"
REF="${GHA_HOST_REF:-main}"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --repo) REPO="${args[$((i + 1))]:-}" ;;
    --ref) REF="${args[$((i + 1))]:-}" ;;
    -h | --help) usage; exit 0 ;;
  esac
done

if [[ ! -f $SELF_DIR/scripts/lib/common.sh ]]; then
  [[ $EUID -eq 0 ]] || { echo "ERROR: run as root (use sudo)" >&2; exit 1; }
  [[ $REPO != OWNER/* ]] || { echo "ERROR: standalone run needs --repo OWNER/NAME (or GHA_HOST_REPO) to fetch the project" >&2; exit 1; }
  command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates; }
  tmp="$(mktemp -d)"
  echo "Fetching $REPO@$REF ..."
  hdr=()
  [[ -n ${GITHUB_TOKEN:-} ]] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL "${hdr[@]}" "https://api.github.com/repos/$REPO/tarball/$REF" | tar -xz -C "$tmp" --strip-components=1
  exec bash "$tmp/install.sh" "$@"
fi

# shellcheck source=scripts/lib/common.sh
source "$SELF_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/github.sh
source "$SELF_DIR/scripts/lib/github.sh"
SRC="$SELF_DIR"

# --- flags ----------------------------------------------------------------------
declare -A FLAGS=()
# --yes is accepted for scripted use; the installer never prompts
need() { [[ $# -ge 2 && -n ${2:-} ]] || die "$1 needs a value"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) need "$@"; FLAGS[GH_ORG]=$2; shift 2 ;;
    --runner-group) need "$@"; FLAGS[RUNNER_GROUP]=$2; shift 2 ;;
    --pat-file) need "$@"; FLAGS[GH_PAT_FILE]=$2; shift 2 ;;
    --app-id) need "$@"; FLAGS[GH_APP_ID]=$2; shift 2 ;;
    --installation-id) need "$@"; FLAGS[GH_APP_INSTALLATION_ID]=$2; shift 2 ;;
    --app-key) need "$@"; FLAGS[GH_APP_KEY_FILE]=$2; shift 2 ;;
    --auth) need "$@"; FLAGS[GH_AUTH]=$2; shift 2 ;;
    --api-url) need "$@"; FLAGS[GH_API_URL]=$2; shift 2 ;;
    --server-url) need "$@"; FLAGS[GH_SERVER_URL]=$2; shift 2 ;;
    --runners) need "$@"; FLAGS[RUNNER_COUNT]=$2; shift 2 ;;
    --mode) need "$@"; FLAGS[RUNNER_MODE]=$2; shift 2 ;;
    --name) need "$@"; FLAGS[HOST_NAME]=$2; shift 2 ;;
    --labels) need "$@"; FLAGS[RUNNER_LABELS]=$2; shift 2 ;;
    --index-labels) FLAGS[RUNNER_PER_INDEX_LABEL]=true; shift ;;
    --cpus) need "$@"; FLAGS[RUNNER_CPUS]=$2; shift 2 ;;
    --memory) need "$@"; FLAGS[RUNNER_MEMORY]=$2; shift 2 ;;
    --image) need "$@"; FLAGS[RUNNER_IMAGE]=$2; shift 2 ;;
    --build-image) FLAGS[BUILD_IMAGE]=true; shift ;;
    --no-aws-cli) FLAGS[INSTALL_AWS_CLI]=false; shift ;;
    --no-azure-cli) FLAGS[INSTALL_AZURE_CLI]=false; shift ;;
    --registry-auth) need "$@"; FLAGS[REGISTRY_AUTH]=$2; shift 2 ;;
    --registry-user) need "$@"; FLAGS[REGISTRY_USERNAME]=$2; shift 2 ;;
    --registry-password-file) need "$@"; FLAGS[REGISTRY_PASSWORD_FILE]=$2; shift 2 ;;
    --platform) need "$@"; FLAGS[PLATFORM]=$2; shift 2 ;;
    --data-disk) need "$@"; FLAGS[DATA_DISK]=$2; shift 2 ;;
    --force-format) FORCE_FORMAT=1; shift ;;
    --data-dir) need "$@"; FLAGS[DATA_DIR]=$2; shift 2 ;;
    --fs) need "$@"; FLAGS[DATA_FS]=$2; shift 2 ;;
    --ssm-path) need "$@"; FLAGS[SSM_PATH]=$2; shift 2 ;;
    --auto-update) FLAGS[AUTO_UPDATE]=true; shift ;;
    --repo | --ref) shift 2 ;;
    --reconfigure) shift ;;
    --yes | -y) shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
FORCE_FORMAT="${FORCE_FORMAT:-0}"

require_root
LOG=/var/log/gha-host-install.log
exec > >(tee -a "$LOG") 2>&1
log "gha-host installer $(cat "$SRC/VERSION" 2>/dev/null || echo dev) starting (log: $LOG)"

# --- preflight --------------------------------------------------------------------
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  ubuntu | debian) ;;
  *) [[ ${ID_LIKE:-} == *ubuntu* || ${ID_LIKE:-} == *debian* ]] || die "unsupported OS '${ID:-?}': need Ubuntu or Debian" ;;
esac
DOCKER_DISTRO=ubuntu
[[ ${ID:-} == debian || ( ${ID_LIKE:-} == *debian* && ${ID_LIKE:-} != *ubuntu* ) ]] && DOCKER_DISTRO=debian
[[ ${ID:-} == ubuntu || ${ID_LIKE:-} == *ubuntu* ]] && DOCKER_DISTRO=ubuntu
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ -n $CODENAME ]] || die "cannot determine the OS codename"
case "$(uname -m)" in x86_64 | aarch64) ;; *) die "unsupported architecture $(uname -m)" ;; esac
command -v systemctl >/dev/null || die "systemd is required"

export DEBIAN_FRONTEND=noninteractive
log "installing base packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl jq openssl gnupg unzip util-linux e2fsprogs xfsprogs \
  unattended-upgrades >/dev/null

# --- platform ---------------------------------------------------------------------
PLATFORM_FLAG="${FLAGS[PLATFORM]:-${PLATFORM:-}}"
DETECTED="$(detect_platform)"
log "platform: ${PLATFORM_FLAG:-$DETECTED} (detected: $DETECTED)"
virt="$(systemd-detect-virt 2>/dev/null || true)"
if [[ $virt == kvm || $virt == qemu ]]; then
  apt-get install -y -qq qemu-guest-agent >/dev/null && systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
fi

ensure_aws_cli() {
  command -v aws >/dev/null && return 0
  log "installing AWS CLI v2 on the host"
  local t
  t="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$t/aws.zip"
  unzip -q "$t/aws.zip" -d "$t"
  "$t/aws/install" --update >/dev/null
  rm -rf "$t"
}

# --- configuration (flag > env > SSM > env file > default) ----------------------------
declare -A ENVSNAP=()
for v in "${CONFIG_VARS[@]}"; do
  if [[ -n ${!v+x} ]]; then ENVSNAP[$v]="${!v}"; fi
done
if [[ -f $GHA_ENV_FILE ]]; then
  log "loading existing config $GHA_ENV_FILE"
  apply_kv_file "$GHA_ENV_FILE"
fi
SSM_PATH_EFFECTIVE="${FLAGS[SSM_PATH]:-${ENVSNAP[SSM_PATH]:-${SSM_PATH:-}}}"
if [[ -n $SSM_PATH_EFFECTIVE ]]; then
  ensure_aws_cli
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$(imds placement/region || true)}"
  ssm() { aws ssm get-parameter --name "$SSM_PATH_EFFECTIVE/$1" --with-decryption --query Parameter.Value --output text 2>/dev/null; }
  log "reading config from SSM $SSM_PATH_EFFECTIVE"
  if cfg="$(ssm config)"; then
    printf '%s\n' "$cfg" >/run/gha-host-ssm.conf
    apply_kv_file /run/gha-host-ssm.conf
    rm -f /run/gha-host-ssm.conf
  fi
  for pair in org:GH_ORG app-id:GH_APP_ID installation-id:GH_APP_INSTALLATION_ID; do
    name="${pair%%:*}"
    var="${pair##*:}"
    if val="$(ssm "$name")" && [[ -n $val && $val != None ]]; then printf -v "$var" '%s' "$val"; fi
  done
fi
for v in "${!ENVSNAP[@]}"; do printf -v "$v" '%s' "${ENVSNAP[$v]}"; done
for v in "${!FLAGS[@]}"; do printf -v "$v" '%s' "${FLAGS[$v]}"; done
SSM_PATH="${SSM_PATH_EFFECTIVE}"

PLATFORM="${PLATFORM:-$DETECTED}"
if [[ -z ${HOST_NAME:-} && $PLATFORM == ec2 ]]; then
  HOST_NAME="$(imds tags/instance/Name 2>/dev/null || imds instance-id)"
fi
set_defaults
[[ -n ${GH_ORG:-} ]] || die "--org is required"
if [[ -z ${RUNNER_IMAGE:-} ]]; then
  if [[ $BUILD_IMAGE == true ]]; then RUNNER_IMAGE="gha-host-runner:local"; else RUNNER_IMAGE="ghcr.io/${GH_ORG,,}/gha-host-runner:latest"; fi
fi
[[ $RUNNER_COUNT =~ ^[0-9]+$ && $RUNNER_COUNT -ge 1 ]] || die "--runners must be a positive integer"
[[ $RUNNER_MODE == persistent || $RUNNER_MODE == ephemeral ]] || die "--mode must be persistent or ephemeral"
[[ $DATA_FS == ext4 || $DATA_FS == xfs ]] || die "--fs must be ext4 or xfs"
[[ $HOST_NAME =~ ^[A-Za-z0-9._-]+$ ]] || die "runner name prefix '$HOST_NAME' has unsupported characters"
for v in "${CONFIG_VARS[@]}"; do
  case "${!v:-}" in
    *'"'* | *'$'* | *'`'* | *'\'* | *$'\n'*)
      die "$v contains a character that is not allowed (double quote, \$, backtick, backslash or newline)" ;;
  esac
done

# --- data disk ------------------------------------------------------------------------
find_blank_disk() {
  local d
  while read -r d; do
    [[ $d == /dev/zram* ]] && continue
    # blank = no partitions, no filesystem signature, nothing mounted
    [[ $(lsblk -n -o NAME "$d" | wc -l) -eq 1 ]] || continue
    [[ -z $(lsblk -n -o FSTYPE,MOUNTPOINT "$d" | tr -d ' \n') ]] || continue
    echo "$d"
    return 0
  done < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}')
  return 1
}

prepare_data_disk() {
  mkdir -p "$DATA_DIR"
  [[ -n ${DATA_DISK:-} ]] || { log "no data disk requested: using $DATA_DIR on the root filesystem"; return 0; }
  local dev=$DATA_DISK fstype label uuid parts
  if [[ $dev == auto ]]; then
    dev="$(find_blank_disk)" || die "--data-disk auto: no blank disk found"
    log "auto-selected data disk $dev"
  fi
  [[ -b $dev ]] || die "data disk $dev is not a block device"
  if mountpoint -q "$DATA_DIR"; then
    log "$DATA_DIR is already a mount point, leaving it alone"
    return 0
  fi
  fstype="$(lsblk -no FSTYPE "$dev" | head -1)"
  label="$(lsblk -no LABEL "$dev" | head -1)"
  parts="$(lsblk -n -o NAME "$dev" | wc -l)"
  if [[ $fstype == "$DATA_FS" && $label == GHADATA ]]; then
    log "reusing existing gha-host data filesystem on $dev"
  elif [[ -z $fstype && $parts -eq 1 ]] || ((FORCE_FORMAT)); then
    log "formatting $dev as $DATA_FS (label GHADATA)"
    if [[ $DATA_FS == xfs ]]; then mkfs.xfs -f -L GHADATA "$dev" >/dev/null; else mkfs.ext4 -F -m 0 -L GHADATA "$dev" >/dev/null; fi
  else
    die "$dev is not blank (fs='${fstype:-none}', partitions=$((parts - 1))). Refusing to format; use --force-format if you are sure."
  fi
  uuid="$(blkid -s UUID -o value "$dev")"
  grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $DATA_DIR $DATA_FS defaults,noatime,nofail 0 2" >>/etc/fstab
  mount "$DATA_DIR"
  log "mounted $dev at $DATA_DIR"
}
prepare_data_disk

# --- docker -----------------------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
    return
  fi
  log "installing Docker Engine from Docker's apt repository"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$DOCKER_DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DOCKER_DISTRO $CODENAME stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
}

configure_docker() {
  local keep want cur=/etc/docker/daemon.json
  keep="$(keep_storage)"
  want="$(jq --arg root "$DATA_DIR/docker" --arg keep "$keep" \
    '. + {"data-root": $root} | .builder.gc.defaultKeepStorage = $keep' "$SRC/config/daemon.json")"
  if [[ -s $cur ]]; then
    want="$(jq -s '.[0] * .[1]' "$cur" <(echo "$want"))"
    cmp -s <(jq -S . "$cur") <(jq -S . <<<"$want") && { log "docker daemon.json unchanged"; return 0; }
  fi
  mkdir -p /etc/docker "$DATA_DIR/docker"
  systemctl stop docker.socket docker.service 2>/dev/null || true
  echo "$want" >"$cur"
  systemctl enable docker >/dev/null 2>&1
  systemctl start docker
  log "docker configured: data-root=$DATA_DIR/docker, build cache budget=$keep"
}
install_docker
configure_docker
systemctl is-active --quiet docker || systemctl start docker

# --- install files ----------------------------------------------------------------------
log "installing to $GHA_HOME"
install -d -m 0755 "$GHA_HOME" "$GHA_ETC" "$GHA_HOME/compose"
chmod 0750 "$GHA_ETC"
if [[ $(realpath "$SRC") != "$(realpath "$GHA_HOME")" ]]; then
  for d in runner scripts config systemd provisioning docs; do
    [[ -d $SRC/$d ]] || continue
    rm -rf "${GHA_HOME:?}/$d"
    cp -a "$SRC/$d" "$GHA_HOME/$d"
  done
  for f in install.sh uninstall.sh VERSION README.md; do [[ -f $SRC/$f ]] && cp -a "$SRC/$f" "$GHA_HOME/$f"; done
fi
chmod +x "$GHA_HOME"/scripts/*.sh "$GHA_HOME"/install.sh "$GHA_HOME"/uninstall.sh 2>/dev/null || true

write_env() {
  local tmp v
  tmp="$(mktemp)"
  {
    echo "# gha-host configuration, written by install.sh on $(date -u +%FT%TZ). Edit and re-run install.sh --reconfigure."
    for v in "${CONFIG_VARS[@]}"; do printf '%s="%s"\n' "$v" "${!v:-}"; done
  } >"$tmp"
  install -m 0640 "$tmp" "$GHA_ENV_FILE"
  rm -f "$tmp"
}
write_env

# --- secrets + credential check ----------------------------------------------------------
"$GHA_HOME/scripts/load-secrets.sh"
load_config
if [[ ! -r ${GH_PAT_FILE:-} && ! ( -n ${GH_APP_ID:-} && -r ${GH_APP_KEY_FILE:-} ) ]]; then
  die "no GitHub credentials found. Provide a PAT ($GHA_ETC/pat or --pat-file) or an App (--app-id + --app-key), or SSM parameters."
fi
log "checking GitHub credentials for org '$GH_ORG'"
gh_call GET "/orgs/$GH_ORG/actions/runners?per_page=1" >/dev/null ||
  die "GitHub rejected the credentials for org '$GH_ORG' (need 'Self-hosted runners: read & write' on the org)"
gh_call GET "/orgs/$GH_ORG/actions/runner-groups" 2>/dev/null |
  jq -e --arg g "$RUNNER_GROUP" '.runner_groups | map(.name) | index($g)' >/dev/null ||
  warn "runner group '$RUNNER_GROUP' was not found (or cannot be listed); registration fails if it does not exist"

# --- image -------------------------------------------------------------------------------
if [[ $BUILD_IMAGE == true ]]; then
  log "building runner image $RUNNER_IMAGE (this takes a few minutes the first time)"
  docker build -f "$GHA_HOME/runner/Dockerfile" -t "$RUNNER_IMAGE" \
    --build-arg "INSTALL_AWS_CLI=$INSTALL_AWS_CLI" --build-arg "INSTALL_AZURE_CLI=$INSTALL_AZURE_CLI" "$GHA_HOME"
else
  if [[ $RUNNER_IMAGE == *.dkr.ecr.* ]]; then ensure_aws_cli; fi
  "$GHA_HOME/scripts/registry-login.sh"
  log "pulling $RUNNER_IMAGE"
  docker pull "$RUNNER_IMAGE"
fi
# the runner user's uid inside the image
img_uid="$(docker run --rm --entrypoint id "$RUNNER_IMAGE" -u 2>/dev/null || true)"
if [[ -n $img_uid && $img_uid != "$RUNNER_UID" ]]; then
  warn "image runner uid is $img_uid, config says $RUNNER_UID; using $img_uid"
  RUNNER_UID="$img_uid"
  write_env
  "$GHA_HOME/scripts/load-secrets.sh"
fi

# --- compose + systemd ---------------------------------------------------------------------
"$GHA_HOME/scripts/gen-compose.sh"
for u in gha-host.service gha-prune.service gha-prune.timer gha-update.service gha-update.timer; do
  sed -e "s|@PRUNE_INTERVAL@|$PRUNE_INTERVAL|g" -e "s|@UPDATE_SCHEDULE@|$UPDATE_SCHEDULE|g" \
    "$GHA_HOME/systemd/$u" >"/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable gha-prune.timer >/dev/null 2>&1
systemctl start gha-prune.timer
if [[ $AUTO_UPDATE == true ]]; then
  systemctl enable gha-update.timer >/dev/null 2>&1
  systemctl start gha-update.timer
  log "automatic updates enabled: $UPDATE_SCHEDULE"
else
  systemctl disable --now gha-update.timer >/dev/null 2>&1 || true
fi
if systemctl is-active --quiet gha-host.service; then
  log "applying changes to the running stack"
  (cd "$GHA_HOME/compose" && docker compose up -d --remove-orphans)
else
  systemctl enable gha-host.service >/dev/null 2>&1
  systemctl start gha-host.service
fi

# --- wait for runners ---------------------------------------------------------------------------
log "waiting for $RUNNER_COUNT runner(s) to come online in GitHub (up to 3 min)"
online=0
for _ in $(seq 1 36); do
  online="$(gh_runners_with_prefix "$HOST_NAME-" 2>/dev/null | jq '[.[] | select(.status=="online")] | length' 2>/dev/null || echo 0)"
  ((online >= RUNNER_COUNT)) && break
  sleep 5
done

echo
if ((online >= RUNNER_COUNT)); then
  log "SUCCESS: $online/$RUNNER_COUNT runners online"
else
  warn "only $online/$RUNNER_COUNT runners online. Check: docker logs gha-runner-1 ; journalctl -u gha-host"
fi
cat <<EOF

  org            : $GH_ORG   (runner group: $RUNNER_GROUP)
  runners        : $HOST_NAME-1 .. $HOST_NAME-$RUNNER_COUNT   mode: $RUNNER_MODE
  labels         : self-hosted, linux, ${RUNNER_LABELS}
  image          : $RUNNER_IMAGE
  data dir       : $DATA_DIR  (docker: $DATA_DIR/docker, workspaces: $DATA_DIR/work)
  use in a job   : runs-on: [self-hosted, ${RUNNER_LABELS%%,*}]
  health         : sudo $GHA_HOME/scripts/healthcheck.sh
  config         : $GHA_ENV_FILE
  uninstall      : sudo $GHA_HOME/uninstall.sh
EOF
((online >= RUNNER_COUNT))
