# Configuration

Settings live in `/etc/gha-host/gha-host.env`. Every installer flag maps to a variable there.
Precedence, highest first: **CLI flag → environment → SSM `/config` (EC2) → existing env file → default**.

Runners are always registered at **org level** and shared through a runner group.

Values may not contain double quotes, `$`, backticks, backslashes or newlines (the installer rejects them).

Installer-only flags: `--repo OWNER/NAME` and `--ref REF` (where to download the project from when
`install.sh` is run on its own; set `GITHUB_TOKEN` if the repo is private), `--force-format`,
`--yes`, `--reconfigure` (re-apply the stored config, no other flags needed).

After editing the env file by hand, run `sudo /opt/gha-host/install.sh --reconfigure`. That
re-renders compose and restarts runners one at a time.

## GitHub

| Variable | Flag | Default | Description |
|---|---|---|---|
| `GH_ORG` | `--org` | — | **Required.** Org the runners register to (org-level runners only) |
| `GH_API_URL` | `--api-url` | `https://api.github.com` | Change for GitHub Enterprise Server |
| `GH_AUTH` | `--auth` | `auto` | `auto`, `app` or `pat`. `auto` uses the App if `GH_APP_ID` and the key file exist, otherwise the PAT |
| `GH_APP_ID` | `--app-id` | — | GitHub App ID |
| `GH_APP_INSTALLATION_ID` | `--installation-id` | looked up | App installation ID on the org. Optional: if empty it is looked up through the API |
| `GH_SERVER_URL` | `--server-url` | `https://github.com` | Web URL runners register against. Change for GitHub Enterprise Server |
| `GH_APP_KEY_FILE` | `--app-key` | `/etc/gha-host/github-app.pem` | Path to the private key (0600) |
| `GH_PAT_FILE` | `--pat-file` | `/etc/gha-host/pat` | Path to the PAT (0600). Never pass a PAT as a flag |
| `RUNNER_GROUP` | `--runner-group` | `Default` | Org runner group |

### PAT vs GitHub App

| | Fine-grained PAT | GitHub App |
|---|---|---|
| Setup | One token, about 2 minutes | Create the App, install it on the org, download the key: about 10 minutes |
| Permission | Org → *Self-hosted runners: Read & write* | Same |
| Expiry | Has to be rotated (max 1 year, or per org policy) | Key doesn't expire. Rotate when you choose |
| Tied to a person | Yes: stops working if they leave the org | No |
| Best for | Trying it out, a single host | Long-lived or multiple hosts |

Switching later: add the App settings and re-run `install.sh --reconfigure`. With `GH_AUTH=auto` the App takes over.

## Runners

| Variable | Flag | Default | Description |
|---|---|---|---|
| `RUNNER_COUNT` | `--runners` | `nproc / 2` (min 1) | Number of runner containers |
| `RUNNER_MODE` | `--mode` | `persistent` | `persistent` or `ephemeral` |
| `HOST_NAME` | `--name` | EC2 Name tag, else hostname | Runner name prefix → `<HOST_NAME>-<n>` |
| `RUNNER_LABELS` | `--labels` | `gha-host` | Comma-separated custom labels. **Replaces** the default. Include `gha-host` yourself if you want to keep it |
| `RUNNER_PER_INDEX_LABEL` | `--index-labels` | `false` | Add `runner-<n>` label (article style) |
| `RUNNER_CPUS` | `--cpus` | unset | Per-runner CPU limit (compose `cpus`) |
| `RUNNER_MEMORY` | `--memory` | unset | Per-runner memory limit, e.g. `6g` |
| `RUNNER_EXTRA_VOLUMES` | — | — | Extra `host:container[:ro]` mounts, comma separated |
| `RUNNER_DISABLE_UPDATE` | — | `false` | Pass `--disableupdate` (only if you rebuild the image often) |

GitHub always adds `self-hosted`, `linux` and `X64`/`ARM64`. The installer adds nothing else
automatically. Platform, environment and purpose labels (`aws`, `onprem`, `prod`, `deploy`, …)
are up to you.

## Runner image and registry

| Variable | Flag | Default | Description |
|---|---|---|---|
| `RUNNER_IMAGE` | `--image` | `ghcr.io/<org>/gha-host-runner:latest`, or `gha-host-runner:local` with `--build-image` | Image reference, from any registry |
| `BUILD_IMAGE` | `--build-image` | `false` | Build `runner/Dockerfile` on the host instead of pulling. Tags it as `RUNNER_IMAGE`. No registry needed |
| `REGISTRY_AUTH` | `--registry-auth` | `auto` | `auto`, `ecr`, `basic` or `none`. `auto` picks `ecr` for `*.dkr.ecr.*.amazonaws.com`, `basic` if `REGISTRY_USERNAME` is set, otherwise `none` |
| `REGISTRY_USERNAME` | `--registry-user` | — | For `basic` (GHCR: any username, e.g. the bot account) |
| `REGISTRY_PASSWORD_FILE` | `--registry-password-file` | `/etc/gha-host/registry-password` | Token or password file (0600). GHCR: PAT with `read:packages` |
| `ECR_REGION` | — | parsed from image host | Override if needed |

For ECR, `registry-login.sh` runs at install time and at every `gha-host` service start (ECR tokens
last 12 hours), using the instance profile on EC2 or AWS credentials in `/root/.aws` on other VMs.
Runner containers never pull images themselves; only the host does, so a long-running host does
not need a refresh timer until you pull a new image (re-run `install.sh` or `registry-login.sh`).

Image build args (when building with `--build-image` or in CI):

| Build arg | Default | Description |
|---|---|---|
| `RUNNER_VERSION` | pinned in Dockerfile | `actions-runner` base tag |
| `INSTALL_AWS_CLI` | `true` | AWS CLI v2 |
| `INSTALL_AZURE_CLI` | `true` | Azure CLI (about 1 GB, so turn it off for slim hosts) |

## Host and storage

| Variable | Flag | Default | Description |
|---|---|---|---|
| `PLATFORM` | `--platform` | auto | `ec2` or `vm` |
| `DATA_DISK` | `--data-disk` | none | Block device, or `auto` (first blank, unmounted disk). Mounted at `DATA_DIR` by UUID in `/etc/fstab` |
| `DATA_DIR` | `--data-dir` | `/data` | Holds Docker (`$DATA_DIR/docker`, set as `data-root`) and runner workspaces (`$DATA_DIR/work/<n>`). A plain directory if no data disk is given |
| `RUNNER_UID` | — | `1001` | uid of the `runner` user in the image. The installer reads the real value from the image |
| `DATA_FS` | `--fs` | `ext4` | `ext4` or `xfs` |
| `FORCE_FORMAT` | `--force-format` | `false` | Allow formatting a disk that already has a filesystem. **Destructive** |
| `BUILDKIT_KEEP_STORAGE` | — | 60% of data disk | BuildKit GC target |
| `SSM_PATH` | `--ssm-path` | `/gha-host/<HOST_NAME>` | EC2 only |

## Cleanup (`gha-prune.timer`)

| Variable | Default | Description |
|---|---|---|
| `PRUNE_INTERVAL` | `hourly` | systemd `OnCalendar` value |
| `PRUNE_SOFT_PCT` | `75` | Above this: builder prune to keep-storage, remove unused images > `PRUNE_IMAGE_AGE` |
| `PRUNE_HARD_PCT` | `90` | Above this: `docker system prune -af` (cache lost) |
| `PRUNE_IMAGE_AGE` | `168h` | Age filter for unused image removal |

## Updates (`gha-update.timer`, optional)

When `AUTO_UPDATE=true`, `gha-update.timer` runs `scripts/update.sh` on `UPDATE_SCHEDULE`. It
refreshes the runner image (`docker pull`, or `docker build --pull` with `BUILD_IMAGE=true`), then
recreates runners that are on an older image **one at a time, only when each is idle**. A busy
runner is waited for up to `UPDATE_DRAIN_TIMEOUT`, then skipped until the next run. Run it by hand
with `sudo /opt/gha-host/scripts/update.sh` (add `--dry-run` to only list what would change).

It only has something to do if the tag moves (for example `:latest`), or if you changed
`RUNNER_IMAGE` and re-ran `install.sh`. A pinned, unchanged tag is reported as up to date.

| Variable | Default | Description |
|---|---|---|
| `AUTO_UPDATE` | `false` | Enable the timer (`--auto-update`) |
| `UPDATE_SCHEDULE` | `Sun 03:00` | systemd `OnCalendar` |
| `UPDATE_DRAIN_TIMEOUT` | `3600` | Seconds to wait for a busy runner before skipping it |

## Example env file

```bash
GH_ORG=my-org
GH_AUTH=auto
GH_APP_ID=123456
GH_APP_INSTALLATION_ID=7890123
GH_APP_KEY_FILE=/etc/gha-host/github-app.pem
RUNNER_GROUP=build-runners

HOST_NAME=gha-aws-prod-01
RUNNER_COUNT=5
RUNNER_MODE=persistent
RUNNER_LABELS=gha-host,aws,build,deploy,myproduct-prod
RUNNER_IMAGE=123456789012.dkr.ecr.eu-west-2.amazonaws.com/gha-host-runner:2026.11.10
REGISTRY_AUTH=auto   # -> ecr

DATA_DISK=/dev/nvme1n1
DATA_DIR=/data
PRUNE_SOFT_PCT=75
PRUNE_HARD_PCT=90
```

## Customising the runner image

Add a script to `runner/tools.d/`, for example `20-kubectl.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
KUBECTL_VERSION=v1.31.2
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"
chmod +x /usr/local/bin/kubectl
```

Scripts run in lexical order at image build time as root. Pin versions. Rebuild and push with the
`build-runner-image` workflow, then set `RUNNER_IMAGE` to the new tag and re-run `install.sh`. With
`--build-image`, just edit the script and re-run `install.sh` (the host rebuilds).

Scripts run during `docker build`, so they must not need anything from the host. Build context is
the repo root (`docker build -f runner/Dockerfile .`); only `runner/` and `scripts/get-token.sh`
are sent (see `.dockerignore`).
