# gha-host — Implementation Plan

A self-hosted GitHub Actions runner host you can stand up with one install script on
**AWS EC2** or a **local VM (Proxmox, etc.)**. It is based on the approach in
[Fixing slow CI/CD pipelines after migrating from Jenkins to GitHub Actions](https://www.kubeblogs.com/fixing-slow-ci-cd-pipelines-after-migrating-from-jenkins-to-github-actions/)
(kubeblogs), with changes where the article's approach is fragile or insecure.

> Status: **Phases 1–3 written, Phase 4 partly.** The runner image, installer, scripts, systemd
> units, provisioning helpers and CI workflows exist. Static checks pass, and the token script,
> compose generation and the image build were exercised locally (see "Verification status" at the
> end). **The installer has not been run on a real EC2 instance or Proxmox VM yet.** Still to do:
> scale-down draining, benchmarks and failure drills.

---

## 1. What we're taking from the article

The article's main points:

| Article idea | Why it matters | Keep? |
|---|---|---|
| Several runner containers on **one larger host**, managed by Docker Compose | Simpler to run than one VM per runner | ✅ Keep |
| A **custom runner image** with AWS CLI, jq, Docker CLI and Python pre-installed | Jobs stop installing tools on every run | ✅ Keep, and make it extensible |
| Runners **share the host Docker daemon** (socket mount) | Docker layer cache is shared across runners and jobs. This is the main source of the claimed ~6x speedup | ✅ Keep, on a dedicated VM only (see security) |
| **Persist runner credentials** on a volume, with a 5-min backup loop and a SIGTERM trap | Registration tokens expire after 1 hour, so a container restart would lose its registration | 🔁 **Replace** with token minting (below) |
| A large dedicated disk for Docker (200 GB EBS) | Layer cache needs space | ✅ Keep, for EC2 and Proxmox |
| A **prune cron** at 75% disk: `docker system prune -af --filter until=72h` | Stops the disk filling up | 🔁 **Replace** with BuildKit GC plus a gentler watermark prune |
| `chmod 666 /var/run/docker.sock` | Lets the runner user reach Docker | ❌ **Drop**. Map the docker group GID instead |

### Changes from the article and why

1. **Mint registration tokens on demand instead of backing up `.credentials` files.**
   With a GitHub App (preferred) or a fine-grained PAT, the entrypoint calls
   `POST /orgs/{org}/actions/runners/registration-token` whenever it needs to register.
   That removes the backup loop, the trap handlers, the 1-hour token window and the
   edge cases around corrupt credentials. It also makes **ephemeral runners** possible:
   each job gets a fresh workspace, and the Docker layer cache on the host daemon
   still survives.
2. **Generate the runner count instead of hard-coding it.** The article copies five
   Compose services by hand. We generate `docker-compose.yml` from `RUNNER_COUNT`.
3. **Run under systemd.** A `gha-host.service` unit owns `docker compose up`, so the
   host comes back cleanly after a reboot or patching.
4. **Use the same installer everywhere.** One idempotent `install.sh` detects
   EC2 or a generic VM and differs only in where it reads secrets (SSM Parameter
   Store vs a local root-only file) and how it names the host.
5. **Tune cache eviction.** A 72-hour prune throws away the cache that gives the
   speedup. We set a BuildKit `gc` policy (`keepStorage`) in `daemon.json` and only do a
   full prune above a high watermark of about 85%.

---

## 2. Target architecture (summary)

```
┌───────────────────────── VM (EC2 or Proxmox) ───────────────────────────┐
│ systemd: gha-host.service ──► docker compose (generated)               │
│                                                                         │
│   runner-1   runner-2   ...   runner-N      (custom image, non-root)    │
│      │          │                │                                      │
│      └──────────┴── /var/run/docker.sock ──► host dockerd + BuildKit    │
│                                                  │                       │
│                                   /data (docker + work) on own disk      │
│                                   (shared layer + build cache)           │
│                                                                         │
│ systemd timers: gha-prune.timer (disk watermark), gha-update.timer (opt) │
│ secrets: SSM Parameter Store (EC2)  |  /etc/gha-host/secrets (VM)        │
└─────────────────────────────────────────────────────────────────────────┘
          ▲ outbound HTTPS only (github.com, *.actions.githubusercontent.com, registry)
```

Details are in [docs/architecture.md](docs/architecture.md).

---

## 3. Repository layout (to build)

```
gha-host/
├── install.sh                 # entry point: curl | bash, or download + run
├── uninstall.sh               # deregister runners, stop services, optional purge
├── VERSION
├── runner/
│   ├── Dockerfile             # FROM ghcr.io/actions/actions-runner:<pinned>
│   ├── entrypoint.sh          # mint token → config.sh → run.sh; deregister on exit
│   └── tools.d/               # optional extra tool install scripts (kubectl, helm, ...)
├── scripts/
│   ├── gen-compose.sh         # renders compose file from RUNNER_COUNT + labels
│   ├── get-token.sh           # GitHub App JWT / PAT (auto) → registration/remove token
│   ├── registry-login.sh      # ECR / GHCR / generic registry login
│   ├── load-secrets.sh        # SSM (EC2) or local file (VM) → env
│   ├── prune.sh               # watermark-based cleanup
│   ├── healthcheck.sh         # local + GitHub API runner status
│   └── lib/common.sh          # logging, OS detection, platform detection
├── config/
│   ├── gha-host.env.example   # all tunables, documented
│   └── daemon.json            # log rotation, BuildKit GC, data-root
├── systemd/
│   ├── gha-host.service
│   ├── gha-prune.service / gha-prune.timer
│   └── gha-update.service / gha-update.timer   (optional image refresh)
├── provisioning/
│   ├── ec2/
│   │   ├── user-data.sh       # bootstraps install.sh at launch
│   │   └── iam-policy.json    # ssm:GetParameter(s) on /gha-host/* + kms:Decrypt (+ ECR pull, optional)
│   └── proxmox/
│       ├── cloud-init.yaml    # user-data snippet that runs install.sh
│       └── create-vm.sh       # qm commands: clone cloud image template, add disk
├── .github/workflows/
│   ├── build-runner-image.yml # build + push runner image (weekly + on change)
│   ├── lint.yml               # shellcheck, hadolint
│   └── smoke-test.yml         # runs on the self-hosted runner itself
└── docs/
    ├── architecture.md
    ├── install.md
    ├── configuration.md
    ├── operations.md
    ├── security.md
    └── workflow-usage.md
```

---

## 4. Phased delivery

### Phase 0: Decisions ✅ (settled 2026-11-16)
- [x] **Runner scope:** **org-level only.** Runners are shared across the org through a runner
      group. Repo-level registration is out of scope.
- [x] **Auth for token minting:** **support both, auto-detected.** If GitHub App settings are
      present, use the App. Otherwise use a fine-grained PAT. The PAT is the quick start (one
      value). The App is recommended for long-lived hosts (not tied to a person, higher rate
      limits, rotatable).
- [x] **Image registry:** **configurable.** `RUNNER_IMAGE` can point at any registry. Login is
      handled per type: ECR via the instance profile or AWS creds, GHCR or other registries via
      username + token file, or no registry at all with `--build-image` (build on the host).
- [x] **Base image tools:** AWS CLI v2, Azure CLI, python3 + pip, jq, `docker.io` (with
      `docker-buildx` and `docker-compose-v2`), plus the basics the scripts need (git, curl,
      unzip, openssl, ca-certificates). Anything else goes in `runner/tools.d/`.
- [x] **Labels:** **set by the user.** The installer adds only `gha-host` by default (GitHub
      adds `self-hosted`, `linux` and the arch itself). Platform labels such as `aws` or `onprem`
      are not added automatically. Pass them with `--labels` if you want them.
- [x] **Terraform:** **out of scope.** EC2 provisioning is user-data + IAM policy + docs only.
- [x] **Runner mode default:** `persistent` (matches the article). `ephemeral` is available per host.
- [x] **Base OS:** Ubuntu 24.04 LTS (primary target). 22.04 supported. Debian 12 as best effort.
- [x] **Repos allowed:** private or internal only. Self-hosted runners must **never** be
      used by public repos. Enforce this with an org runner group.

### Phase 1: Runner image
- [x] `runner/Dockerfile` from a **pinned** `ghcr.io/actions/actions-runner:<version>`,
      adding:
  - `docker.io`, `docker-buildx`, `docker-compose-v2` (Ubuntu packages. Only the CLI is used,
    and the daemon is never started in the container)
  - AWS CLI v2 (official installer, arch-aware)
  - Azure CLI (Microsoft apt repo)
  - `python3`, `python3-pip`, `python3-venv`
  - `jq`, plus basics: `git`, `curl`, `unzip`, `openssl` (GitHub App JWT signing), `ca-certificates`
  - Added after first use: `gettext-base` (`envsubst`), Node.js LTS + npm (`INSTALL_NODEJS`, `NODE_MAJOR`),
    `build-essential`, `gh`, optional PostgreSQL client (`POSTGRES_CLIENT_VERSION`) and Playwright Chromium
    libraries (`PLAYWRIGHT_DEPS_VERSION`); host-level arm64 emulation via QEMU binfmt (`QEMU_BINFMT`)
- [x] `tools.d/*.sh` hook for extra tools baked in at build time (kubectl, helm, terraform)
      so each team can extend the image without forking the Dockerfile.
- [x] Build args for image size: `INSTALL_AZURE_CLI=true`, `INSTALL_AWS_CLI=true`, so slim
      variants are possible. The Azure CLI adds roughly 1 GB.
- [x] `entrypoint.sh`:
  - Load credentials from env or a mounted secret file, and auto-select App or PAT
    (App if `GH_APP_ID` and a key file are present).
  - Mint a registration token and run `config.sh --unattended --replace --name ... --labels ...
    --runnergroup ... --work ...` (add `--ephemeral` in ephemeral mode).
  - Run `run.sh`. On SIGTERM, mint a remove-token and run `config.sh remove`.
  - Always re-registers with `--replace` on start (fresh token, nothing persisted), in both modes.
  - No `chmod` on the socket. The container is started with `group_add: [<docker GID>]`.
- [x] CI workflow that builds weekly and on change, scans with Trivy, and pushes `:latest` + `:<date>-<sha>`.

### Phase 2: Install script (core deliverable)
`install.sh` must be **idempotent**, safe to re-run for upgrades and reconfiguration, and
non-interactive when given flags or env.

- [x] Preflight: root check, OS/arch check (x86_64 + arm64), outbound connectivity to
      `api.github.com`, CPU/RAM/disk sanity warnings.
- [x] Platform detection: EC2 via IMDSv2 token request; otherwise a generic VM. Install
      `qemu-guest-agent` when a QEMU/KVM hypervisor is detected (Proxmox).
- [x] Optional data disk (`--data-disk /dev/xxx`): format ext4/xfs **only if blank**,
      mount at `DATA_DIR` (default `/data`; Docker `data-root` is `$DATA_DIR/docker`, runner workspaces are `$DATA_DIR/work`) by UUID in fstab. Refuse to touch a disk that has a filesystem
      unless `--force-format` is passed.
- [x] Install Docker Engine + compose plugin from Docker's apt repo. Write
      `config/daemon.json` (log rotation, BuildKit GC `keepStorage`, `live-restore`).
- [x] Create `/opt/gha-host` (code), `/etc/gha-host/gha-host.env` (config),
      `/etc/gha-host/secrets` (VM only, `0600 root`).
- [x] Secrets: EC2 reads `/gha-host/<name>/*` from SSM Parameter Store with the instance
      profile. The VM path uses the secrets file or flags.
- [x] Registry login based on the `RUNNER_IMAGE` host: `*.dkr.ecr.*.amazonaws.com` → `aws ecr
      get-login-password` (instance profile), refreshed at every service start (ECR
      tokens last 12h; the planned update timer logs in again before pulling). Any other host → `REGISTRY_USERNAME` + `REGISTRY_PASSWORD_FILE` if set,
      otherwise an anonymous pull.
- [x] Pull the runner image, or build it locally with `--build-image` (no registry needed. Good
      for a single Proxmox host).
- [x] Render compose with `gen-compose.sh` and install and enable the systemd units and timers.
- [x] Start, then wait until all N runners show `online` in the GitHub API and print a summary.
- [x] `uninstall.sh`: stop, deregister all runners via API, remove units. `--purge` also
      removes the Docker data, runner workspaces and config.

Intended usage (details in [docs/install.md](docs/install.md)):

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/<org>/gha-host/<tag>/install.sh
less install.sh   # review before running as root
sudo bash install.sh --org my-org --pat-file /root/gh-pat --runners 5 --labels build --data-disk /dev/nvme1n1
```

### Phase 3: Provisioning helpers
- [x] EC2: `user-data.sh` (downloads a pinned release tag of install.sh, reads config from
      SSM), IAM policy JSON, recommended Security Group (no inbound, egress 443 + 80 for apt).
- [x] Proxmox: `create-vm.sh` (clone an Ubuntu cloud-image template, set CPU/RAM, add a second
      disk for Docker, attach cloud-init), plus a `cloud-init.yaml` snippet that runs the installer.
- [ ] Docs for both paths, including manual install on an existing VM.

### Phase 4: Operations
- [x] `prune.sh` + timer (hourly):
  - Always: remove stopped containers older than 24h and dangling images.
  - Above 75% use: `docker builder prune --keep-storage <X>` and remove unused images older than 7d.
  - Above 90% use: full `docker system prune -af` and log a warning.
- [x] `healthcheck.sh`: containers running, runners online in the API, disk %, docker
      daemon responsive. Exit codes suit cron, CloudWatch agent or Uptime Kuma.
- [x] Optional `gha-update.timer`: pull a new image tag, then rolling-restart runners one at a
      time, waiting for each to go idle (`busy=false` via API) first.
- [ ] Log shipping notes: journald for the host, Docker `json-file` with rotation for runners.

### Phase 5: Validation and benchmark
- [x] Smoke-test workflow: `runs-on: [self-hosted, gha-host]`, runs `docker build` twice and
      asserts the second build is cached.
- [ ] Benchmark 2–3 real pipelines on GitHub-hosted vs gha-host (cold and warm cache) and
      record the numbers in `docs/benchmarks.md`. Don't rely on the article's 6x figure.
- [ ] Failure drills: reboot the host, `docker restart` one runner, kill the instance and
      re-provision, fill the disk to 90%.

### Phase 6: Optional hardening and scale (later)
- [ ] Docs for a hand-built EC2 launch template + ASG of 1 for self-healing (no Terraform).
- [ ] Rootless Docker mode (existing hosts of this org ran rootless). Needs per-user daemon, different socket path and `data-root`, and no privileged steps.
- [ ] Shared BuildKit sidecar (`moby/buildkit`) as an alternative to the host socket, so
      jobs don't get host Docker access. Teams then build with `driver: remote`.
- [ ] Registry pull-through cache (`registry:2` as a Docker Hub mirror) to avoid Docker Hub
      rate limits and speed up base-image pulls.
- [ ] Shared dependency cache volumes (npm, pip, Maven, Go) mounted into runners.
- [ ] Multiple hosts per environment or label for HA. Move to ARC on Kubernetes if scale demands it.

---

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| A job can take over the host through the Docker socket | Dedicated VM per trust boundary, private repos only, runner group restricted to named repos, no secrets stored on the host beyond the runner's own. Phase 6 BuildKit sidecar. See [docs/security.md](docs/security.md) |
| A single host is a single point of failure | Host is disposable: re-run the installer or let the ASG replace it. Token minting means no state to restore. The only loss is warm cache |
| Disk fills and builds fail | Dedicated disk, BuildKit GC, watermark prune, healthcheck alert |
| Persistent runners leak workspace state between jobs | Offer `ephemeral` mode. Add `actions/checkout` `clean: true` guidance in the workflow docs |
| Runner version goes stale (GitHub stops accepting old runners) | Runner self-update stays enabled. Weekly image rebuild from the pinned base, with a bump PR |
| CPU and IO contention with many concurrent runners | Sizing guidance, `cpus`/`mem_limit` per runner (optional), gp3 IOPS/throughput tuning |

---

## 6. Open questions

All Phase 0 questions are answered (see Phase 0 above). The only thing left to decide is
where the repo is hosted (`<org>/gha-host`), which goes into the `raw.githubusercontent.com`
URLs in the docs.

## 7. Documentation index

- [docs/architecture.md](docs/architecture.md): components, data flow, design decisions
- [docs/install.md](docs/install.md): EC2, Proxmox, and existing-VM install paths
- [docs/configuration.md](docs/configuration.md): every setting and flag
- [docs/operations.md](docs/operations.md): day-2 work: scaling, upgrades, cleanup, troubleshooting
- [docs/security.md](docs/security.md): threat model and hardening
- [docs/workflow-usage.md](docs/workflow-usage.md): how teams target these runners and use the cache

---

## 8. Verification status (as of the first implementation)

**Checked locally (Windows, Git Bash + Docker Desktop):**
- `bash -n` on every script. `shellcheck -S warning` clean (only info-level notes remain).
- `get-token.sh` against a mocked GitHub API: PAT and GitHub App paths, installation-id lookup, the
  App JWT is correctly RS256-signed (verified with `openssl`), tokens go via stdin not argv, and
  missing or bad credentials abort with one clear error and no API calls.
- `gen-compose.sh` output (labels, per-index labels, limits, extra volumes) passes `docker compose config`.
- `runner/Dockerfile` builds (linux/amd64, about 2.9 GB with both cloud CLIs). In the image: Docker CLI
  29.1, buildx, compose, AWS CLI 2.40, Azure CLI 2.93, Python 3.12 + pip, jq 1.7, git, openssl.
- `entrypoint.sh` with fake `config.sh`/`run.sh`: registers with the right flags, forwards SIGTERM to
  the runner, deregisters, exits 0 within a second.

**Not verified (needs a real host and real GitHub credentials):**
- `install.sh` and `uninstall.sh` end to end: data-disk handling, Docker install, `daemon.json`
  merge and restart, systemd units, the wait-for-runners step. **Try on a throwaway VM first.**
- Real registration against GitHub (`config.sh` / `run.sh`), the Docker socket group mapping, ECR
  login, SSM secret loading, `--platform ec2` path, Proxmox helpers, `arm64`.
- `build-runner-image`, `lint` and `smoke-test` workflows have never run.
- Shared-cache behaviour and the speedup. No benchmarks yet (Phase 5).

**Known gaps:** drain-aware scale-down (Phase 4), `OWNER/gha-host` placeholder
in `install.sh` and the docs, no `docs/benchmarks.md`.

**`update.sh` / `gha-update.timer`:** tested in a Linux container with a stubbed `docker` and GitHub
API: dry run, a busy runner being waited for and then skipped (exit 3, other runners still updated),
the retry updating it, and the up-to-date no-op. Not yet run against real Docker and GitHub.
