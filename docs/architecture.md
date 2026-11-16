# Architecture

## Goals

- **Fast builds**: a persistent, shared Docker layer and build cache, plus tools baked into the image.
- **One install path**: the same `install.sh` on EC2 and on a local hypervisor (Proxmox, ESXi, Hyper-V, bare metal).
- **Disposable hosts**: no state that can't be recreated. Losing a host costs only a warm cache.
- **Reachability**: runners sit inside your network (VPC or LAN), so they can deploy to private targets.

## Non-goals

- Autoscaling to zero or to hundreds of runners. Use [actions-runner-controller](https://github.com/actions/actions-runner-controller) for that.
- Running untrusted or public-repo workloads.

## Components

| Component | Where | Purpose |
|---|---|---|
| `install.sh` | repo root → `/opt/gha-host` | Installs Docker, config, systemd units. Idempotent |
| Runner image | `runner/Dockerfile` → any registry, or built on the host | `actions-runner` + AWS CLI, Azure CLI, python3/pip, jq, docker.io CLI + entrypoint |
| `entrypoint.sh` | inside the image | Mints a registration token, registers, runs, and deregisters on shutdown |
| `docker-compose.yml` | `/opt/gha-host/compose/` (generated) | N runner services, one per runner |
| `gha-host.service` | systemd | Runs `docker compose up` and restarts on failure |
| `gha-prune.timer` | systemd | Watermark-based disk cleanup |
| `gha-update.timer` | systemd (optional, `AUTO_UPDATE=true`) | Drain-aware rolling runner image refresh (`scripts/update.sh`) |
| Host `dockerd` + BuildKit | host | Shared build engine and cache for all runners |
| Data disk | `/data` (`DATA_DIR`) | `/data/docker` holds images, layers and build cache (Docker `data-root`); `/data/work/<n>` holds each runner's workspace |

## Runner lifecycle

```
container start
   │
   ├─ load credentials from /run/secrets or env
   │    GH_AUTH=auto → App if GH_APP_ID + key present, else PAT
   │
   ├─ (every start, both modes: nothing is persisted, so always register fresh)
   ├─ mint registration token  (POST /orgs/{org}/actions/runners/registration-token)
   ├─ config.sh --unattended --replace --name <host>-<n> --labels ... [--ephemeral]
   ├─ run.sh   (receives jobs)
   │
   └─ on SIGTERM / exit:
        persistent: remove-token → config.sh remove (it registers again on the next start)
        ephemeral:  runner deregisters itself after one job, container exits,
                    compose restarts it, and it registers again with a fresh token
```

**Why token minting beats credential backup (the article's approach):** the article saves
`.runner`, `.credentials` and `.credentials_rsaparams` to a volume every 5 minutes because
registration tokens expire after an hour. With an App or PAT the host can always get a new
token. A lost or corrupt credentials file then just causes a re-register, and ephemeral
mode works.

## Caching model

All runners talk to the **host** Docker daemon through `/var/run/docker.sock`. So:

- `docker build` / `docker buildx build` (default `docker` driver) reuse layers built by any
  runner in any earlier job.
- Pulled base images are shared.
- The cache survives runner restarts, ephemeral runner cycling and image upgrades. It is lost
  only when the data disk is replaced or pruned.

BuildKit GC (in `daemon.json`) keeps the build cache under a set size:

```json
{
  "data-root": "/data/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "live-restore": true,
  "features": { "buildkit": true },
  "builder": {
    "gc": { "enabled": true, "defaultKeepStorage": "120GB" }
  }
}
```

`defaultKeepStorage` is set by the installer to about 60% of the data disk size.

**Workspaces:** each runner gets `/data/work/<n>` on the host, bind-mounted into its container at
the **same path**. That matters because jobs talk to the host daemon: `docker run -v
$GITHUB_WORKSPACE:/w` and container jobs resolve paths on the host, so the path has to exist there
too. In persistent mode the workspace survives between jobs (incremental `git` checkouts). In
ephemeral mode it is wiped on every start, and the Docker cache still applies.

**Optional (phase 6):** a pull-through registry mirror and shared language-package cache
volumes (`~/.npm`, `~/.cache/pip`, `~/.m2`, `~/go/pkg/mod`).

## Naming and labels

- Runner name: `<HOST_NAME>-<n>`. `HOST_NAME` defaults to the EC2 `Name` tag (or instance-id)
  or the VM hostname.
- Labels added by GitHub: `self-hosted`, `linux`, `X64`/`ARM64`.
- Labels added by the installer: `gha-host` (default value of `--labels`, which you can replace).
- Everything else is up to you via `--labels`, e.g. `aws`, `onprem`, `prod`, `deploy`, `<product>-<env>`.
  The installer adds no platform labels on its own.
- Optional per-runner label `runner-<n>` (the article does this). Off by default because
  pinning jobs to one runner defeats pooling.

## Network

- **Inbound:** none required. SSH or SSM Session Manager for admin only.
- **Outbound (HTTPS 443):** `github.com`, `api.github.com`, `*.actions.githubusercontent.com`,
  `codeload.github.com`, your image registry (e.g. `ghcr.io` + `pkg-containers.githubusercontent.com`,
  or `*.dkr.ecr.<region>.amazonaws.com`; none if building on the host), your
  package mirrors, plus whatever the deploy targets are. Port 80 for apt is needed only at install.
- See GitHub's [self-hosted runner communication requirements](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#communication-between-self-hosted-runners-and-github).

## Sizing guidance (starting point, validate with benchmarks)

| Runners | vCPU | RAM | Data disk | EC2 example | Notes |
|---|---|---|---|---|---|
| 2–3 | 4 | 16 GB | 100 GB | `m7i.xlarge` | Small team |
| 5 | 8 | 32 GB | 200 GB | `m7i.2xlarge` / `c7i.2xlarge` | Article's setup (article doesn't state instance type) |
| 8–10 | 16 | 64 GB | 400 GB | `m7i.4xlarge` | Consider splitting across 2 hosts |

- EBS: gp3, raise throughput to 250–500 MB/s and IOPS to 6000+ for build-heavy hosts.
  Docker IO is often the bottleneck.
- Proxmox: put the data disk on SSD/NVMe storage, enable `discard` + `iothread`, CPU type `host`.
- Use Graviton (`m7g`/`c7g`) only if all images you build support arm64, or use separate hosts per arch.
