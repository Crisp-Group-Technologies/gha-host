# gha-host

Self-hosted GitHub Actions runners on a single VM (AWS EC2 or Proxmox/local), installed with one script.
Several runner containers share the host Docker daemon, so Docker layer and build cache carries over
between jobs, and tools are pre-baked into the runner image.

Based on [kubeblogs: Fixing slow CI/CD pipelines after migrating from Jenkins to GitHub Actions](https://www.kubeblogs.com/fixing-slow-ci-cd-pipelines-after-migrating-from-jenkins-to-github-actions/),
with token-minting registration, systemd management, tuned cache eviction and a defined security model.

> **Status: first implementation, not yet run on a real host.** Installer, runner image, scripts,
> systemd units and CI workflows are written. See [PLAN.md](PLAN.md) for what is verified and what
> is still open. Replace `OWNER/gha-host` in `install.sh` and the docs with your repo path.

## Quick start (planned)

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/<org>/gha-host/v0.1.0/install.sh
less install.sh
sudo install -D -m 0600 /path/to/pat /etc/gha-host/pat     # or use a GitHub App
sudo bash install.sh --org my-org --runners 5 --labels gha-host,build --build-image --data-disk /dev/sdb
```

Then in a workflow:

```yaml
runs-on: [self-hosted, gha-host, build]
```

## Docs

- [PLAN.md](PLAN.md): implementation plan, phases, open decisions
- [Architecture](docs/architecture.md)
- [Installation](docs/install.md): EC2, Proxmox, existing VM
- [Configuration](docs/configuration.md)
- [Operations](docs/operations.md)
- [Security](docs/security.md)
- [Workflow usage](docs/workflow-usage.md)
