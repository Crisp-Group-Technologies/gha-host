# Operations

## Everyday commands

```bash
sudo systemctl status gha-host                 # compose stack
sudo journalctl -u gha-host -f                 # host-side logs
docker logs -f gha-runner-3                    # one runner's logs
sudo /opt/gha-host/scripts/healthcheck.sh      # full health summary (exit 0 = healthy)
df -h /data; docker system df                  # cache and disk usage
```

## Scaling runners on a host

```bash
sudo /opt/gha-host/install.sh --reconfigure --runners 8
```

Scaling up starts new containers. Scaling down stops and removes the highest-numbered runners
**immediately**, which cancels any job they are running (graceful draining is planned). Check the
runner list in GitHub for busy runners first, or scale down during a quiet period.

Signs you've hit the host's limit: load average above vCPUs, `iowait` over 20%, jobs queued
while runners show busy. At that point add a second host with the same labels rather than
growing one host past about 10 runners.

## Upgrading

| What | How |
|---|---|
| **gha-host scripts** | Re-run `install.sh` from the new release tag. Idempotent |
| **Runner image** (tools, base runner version) | Preferred: `sudo /opt/gha-host/scripts/update.sh`, or `AUTO_UPDATE=true` for a weekly run. It recreates runners one at a time **when idle**. If you changed `RUNNER_IMAGE`, run `install.sh --reconfigure` first so the new reference is stored. Re-running `install.sh` recreates changed runners immediately and cancels their jobs |
| **Runner binary** | Self-updates by default when GitHub requires it. The weekly image rebuild keeps the baked version current so containers don't self-update on every start |
| **Docker / OS** | `unattended-upgrades` for security patches. Plan reboots. `live-restore` keeps containers up through dockerd restarts, but **not** through reboots |

What `update.sh` does: refresh the image, then for each runner on an older image, wait until GitHub
reports it idle (up to `UPDATE_DRAIN_TIMEOUT`), run `docker compose up -d --no-deps --force-recreate
runner-<n>`, wait until it is online again, and move on. A runner still busy at the timeout is
skipped and the script exits with status 3 (the timer unit shows as failed, and the next run retries).
If a recreated runner does not come back within 3 minutes it stops the roll-out and exits 1, so the
remaining runners keep serving jobs.

Small race: a runner can take a job in the moment between the idle check and the recreate. That job
is cancelled and GitHub shows it as failed, so re-run it. Ephemeral mode narrows the window, because
a runner is only busy for the duration of a single job.

## Disk and cache

- BuildKit GC keeps build cache under `BUILDKIT_KEEP_STORAGE` without any intervention.
- `gha-prune.timer` (hourly):
  - always: stopped containers > 24h, dangling images
  - over `PRUNE_SOFT_PCT`: `docker builder prune --keep-storage`, unused images older than `PRUNE_IMAGE_AGE`
  - over `PRUNE_HARD_PCT`: `docker system prune -af` and a warning in the journal. Expect slow builds afterwards
- Manual full reset: `sudo systemctl stop gha-host && docker system prune -af --volumes && sudo systemctl start gha-host`
  (in persistent mode this also wipes runner work volumes).
- **Grow the disk**: resize the EBS volume or Proxmox disk, then `sudo resize2fs /dev/<disk>` (ext4)
  or `sudo xfs_growfs /data`, then `--reconfigure` to recompute keep-storage.

## Monitoring

`healthcheck.sh` checks:
1. `dockerd` responds
2. `RUNNER_COUNT` containers running
3. Each runner shows `online` via `GET /orgs/{org}/actions/runners` (filtered by name prefix)
4. `/data` (`DATA_DIR`) usage below `PRUNE_HARD_PCT` (above `PRUNE_SOFT_PCT` is reported but healthy)

Hook it into what you already use:
- **EC2**: CloudWatch agent (disk/mem metrics) + a cron that runs `healthcheck.sh` and
  `aws cloudwatch put-metric-data`. Alarm on `HealthyRunners < RUNNER_COUNT` for 10 minutes.
- **Proxmox / on-prem**: Uptime Kuma push monitor, node_exporter + Prometheus, or cron + email.
- **GitHub side**: watch queued-job time. A job sitting in *Queued* with a matching label means
  runners are offline or saturated.

## Disaster recovery

The host holds no state you can't recreate:

1. Provision a new VM or instance (or let the ASG do it).
2. Run the installer with the same `HOST_NAME`. `--replace` takes over the existing runner registrations.
3. The first builds are cold. The cache warms within a few runs.

Clean up stale offline runners from a dead host: `uninstall.sh --deregister-only --name <old-host>`
(or GitHub removes offline ephemeral runners automatically; persistent ones go after 14 days offline).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Runner container restarts in a loop, `Http response code: Unauthorized` | App key or PAT wrong, expired, or missing permission | Check `GH_*` settings. Test with `scripts/get-token.sh --test` |
| `A runner exists with the same name` | Old registration and `--replace` not applied | Re-run the installer, or remove the runner in the GitHub UI |
| `permission denied ... docker.sock` in a job | docker GID mismatch after a Docker reinstall | `--reconfigure` (re-detects the GID for `group_add`) |
| Builds not using cache | Workflow uses `docker-container` buildx driver or `--no-cache`, or a hard prune ran | See [workflow-usage.md](workflow-usage.md#docker-builds-and-cache). Check `journalctl -u gha-prune` |
| Job stuck in *Queued* | Labels don't match, runner group excludes repo, or all busy | Check `runs-on` labels and runner group repo access |
| Disk full despite pruning | Large volumes or images from jobs (`docker volume ls`), job containers left running | `docker ps -a`, `docker volume prune`. Lower `BUILDKIT_KEEP_STORAGE` |
| Workspace contains files from previous job | Persistent mode | Use `actions/checkout` with `clean: true` (default), or switch to `ephemeral` |
