# Using gha-host runners in workflows

## Targeting runners

```yaml
jobs:
  build:
    runs-on: [self-hosted, gha-host, build]     # all labels must match
```

Labels other than `self-hosted`, `linux` and the arch are whatever the host's operator set with
`--labels` (default `gha-host`). Check the runner list in org settings for what's available.
Example conventions an operator might use:

| Want | `runs-on` |
|---|---|
| Any gha-host runner | `[self-hosted, gha-host]` |
| AWS-hosted runners (if labelled `aws`) | `[self-hosted, gha-host, aws]` |
| On-prem runners (if labelled `onprem`) | `[self-hosted, gha-host, onprem]` |
| Prod deploy host (if labelled `deploy-prod`) | `[self-hosted, gha-host, deploy-prod]` |

Avoid targeting a single runner (`runner-3`). It defeats pooling.

## Pre-installed tools

The base image includes: `docker.io` CLI + buildx + compose, AWS CLI v2 (`aws`), Azure CLI (`az`),
`python3` + `pip`, `jq`, plus `git`, `curl`, `unzip`, `openssl`. (Operators can build slim variants
without the AWS or Azure CLI.)

`pip install` works directly (the image sets `PIP_BREAK_SYSTEM_PACKAGES=1` because Ubuntu 24.04's
system Python is otherwise "externally managed"). For isolation use `python3 -m venv` as usual.

For cloud auth, prefer OIDC over stored credentials: `aws-actions/configure-aws-credentials` and
`azure/login` both support it. Check `runner/tools.d/` for anything your org has added. **Don't** reinstall these
in workflows. Removing those install steps saves time on every run.

`actions/setup-node`, `setup-python`, `setup-java` and similar still work. Their tool cache persists in
`persistent` mode, so later runs skip the download.

## Docker builds and cache

The speedup depends on building with the **host daemon's** BuildKit. Use the default `docker`
driver:

```yaml
- uses: actions/checkout@v4

# Do NOT add docker/setup-buildx-action with the default (docker-container) driver:
# it creates a throwaway builder per job and the shared cache is lost.
# If you need buildx features, use:
- uses: docker/setup-buildx-action@v3
  with:
    driver: docker

- uses: docker/build-push-action@v6
  with:
    context: .
    push: true
    tags: ghcr.io/my-org/my-app:${{ github.sha }}
    # no cache-from/cache-to needed: the local daemon cache is shared across runners
```

Plain `docker build -t myapp .` also benefits.

Tips for good cache hit rates:
- Order your Dockerfile from least to most frequently changing (deps manifest → install → source).
- Use BuildKit cache mounts for package managers. These persist on the host too:
  ```dockerfile
  RUN --mount=type=cache,target=/root/.npm npm ci
  RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements.txt
  ```
- Avoid `--no-cache` and `--pull` on every build. Use `--pull` on a schedule instead.

## Things to know

- **Shared daemon**: image tags are global on the host. Two jobs tagging `myapp:latest` at the
  same time will race. Tag with `${{ github.sha }}` or `${{ github.run_id }}`.
- **Container cleanup**: containers your job starts with `docker run -d` keep running after the job.
  Stop them in an `if: always()` step. Service containers (`services:`) are cleaned up automatically.
- **Workspace (persistent mode)**: `actions/checkout` cleans by default, but untracked files outside
  the repo dir and in `$RUNNER_TEMP` subfolders may remain. Don't rely on a clean `$HOME`.
- **Secrets**: use GitHub secrets / OIDC. Never write credentials to the host filesystem or `~/.docker/config.json`
  without cleaning them up. Use `docker/login-action` with `logout: true` (default).
- **Public repos**: not allowed (runner group restriction). See [security.md](security.md).

## Smoke test

```yaml
name: gha-host smoke test
on: workflow_dispatch
jobs:
  smoke:
    runs-on: [self-hosted, gha-host]
    steps:
      - run: docker version && aws --version && az version && python3 -m pip --version && jq --version
      - run: |
          mkdir -p /tmp/smoke && cd /tmp/smoke
          printf 'FROM alpine:3.20\nRUN sleep 5 && echo built > /x\n' > Dockerfile
          time docker build -t smoke:${{ github.run_id }} .
          time docker build -t smoke:${{ github.run_id }} . 2>&1 | tee out.txt
          grep -q CACHED out.txt && echo "cache OK"
          docker rmi smoke:${{ github.run_id }}
```
