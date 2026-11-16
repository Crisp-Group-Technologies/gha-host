# Security

## Threat model in one paragraph

Any workflow that can run on these runners can run arbitrary code. Because runners use the
**host Docker socket** (that is what makes the cache shared), a job can start a privileged
container and effectively become **root on the VM**. So the trust boundary is the
**VM**, not the runner container. Anyone who can push a workflow to an allowed repo can
reach everything the VM can reach: networks, the IMDS role, other jobs' cache and artifacts.

The article treats this as low risk ("nothing meaningful to escalate to"). We plan on the
assumption that it is a real risk and limit what that root access can reach.

## Required controls

1. **Private/internal repos only.** Never attach these runners to public repos, because fork PRs could
   run code on your network. Use an **org runner group** set to *Selected repositories*.
2. **One host per trust level.** Don't mix "build anything" runners with "deploy to prod" runners
   on the same VM. Use separate hosts and labels (`build` vs `deploy-prod`), and separate runner groups.
3. **No `chmod 666` on the Docker socket.** Containers get access through `group_add` with the host's
   docker GID. That's still root-equivalent, but nothing else on the host gets access.
4. **Minimal host secrets.** The only secret on the host is the GitHub App key or PAT, used to mint
   runner tokens. Deploy credentials come from GitHub secrets or OIDC per job, never from files on the host.
5. **Least-privilege token-minting credentials.** Both PAT and App are supported. Grant only
   *Organization → Self-hosted runners: R/W*. Prefer the App for long-lived hosts (not tied to one
   person's account, rotatable). If you use a PAT, make it fine-grained, scoped to the org, with an expiry.
6. **EC2: no long-lived AWS keys.** Use an instance profile for SSM reads only. For deploys, use
   [GitHub OIDC → AWS](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
   per workflow, so the role is chosen per repo and branch rather than granted to the whole host.
7. **IMDS hop limit 1.** Containers on bridge networks then can't read the instance role. Jobs
   that need AWS use OIDC. (A job using `--network host` through the socket can get around this,
   which is one more reason to keep the instance role minimal.)
8. **No inbound network access.** Admin through SSM Session Manager (EC2) or SSH from a management VLAN.

## Recommended controls

- **Ephemeral mode** for build hosts: a fresh workspace per job stops one job's files leaking into
  the next (the Docker cache is still shared).
- **Pin the runner base image** by version (or digest) and rebuild weekly. Scan with Trivy in CI.
- **Pin third-party actions by SHA** in workflows that run on these runners.
- **Egress filtering**: restrict outbound to GitHub, the registry, package mirrors and deploy targets
  (Security Group / NACL / firewall). This limits damage from compromised dependencies.
- **Patch the host**: `unattended-upgrades` enabled by the installer.
- **Audit**: GitHub org audit log for runner registration events. Ship `journald` off-host.

## Stronger isolation options (phase 6)

| Option | Keeps shared cache? | Effort | Notes |
|---|---|---|---|
| Shared **BuildKit daemon** container, jobs use `buildx --driver remote` | ✅ | Medium | Jobs can build but can't run arbitrary containers on the host. Breaks `docker run` / service containers |
| **Rootless Docker** on host | ✅ | Medium | Root inside = unprivileged user on host. Some build features limited |
| **Sysbox** runtime for runner containers | ⚠️ per-runner | Medium | Docker-in-Docker without privileged mode, but cache becomes per-runner |
| **One VM per job** (ARC, or Firecracker-style tooling) | ❌ / remote cache | High | Strongest isolation. Use registry/S3 cache (`type=registry` / `type=s3`) |

## Secret handling summary

| Secret | Location | Permissions |
|---|---|---|
| GitHub App key / PAT (VM) | `/etc/gha-host/github-app.pem` or `/etc/gha-host/pat` | `0600 root`, mounted read-only into runners as a Docker secret |
| GitHub App key / PAT (EC2) | SSM SecureString `/gha-host/<name>/*` | Fetched at every service start into tmpfs `/run/gha-host/`, never written to disk |
| Staged copies (all platforms) | `/run/gha-host/{pat,app-key}` | `0400`, owned by the runner uid; mounted read-only into runner containers at `/run/gha-secrets` |
| Runner `.credentials` | Inside the runner container | Created by `config.sh` at each start, lost with the container. Replaceable at any time by re-registering |

**Know this:** the staged token-minting credential is readable by the runner user, so a workflow
running on the runner can read it, and (via the Docker socket) so can anyone who can reach the host
filesystem. A leaked PAT or App key can register rogue runners into your org. That is why it must
carry only *Self-hosted runners: read & write*, and why runner groups should restrict which repos
may use these hosts. The runner user also has passwordless `sudo` inside the container (inherited
from GitHub's base image; used to clean root-owned workspace files), which is no extra exposure
beyond the Docker socket but worth knowing.
