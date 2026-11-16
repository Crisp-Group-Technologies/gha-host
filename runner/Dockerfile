# syntax=docker/dockerfile:1
# gha-host runner image. Build from the repo root:
#   docker build -f runner/Dockerfile -t gha-host-runner:local .
ARG RUNNER_VERSION=2.338.2
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

ARG INSTALL_AWS_CLI=true
ARG INSTALL_AZURE_CLI=true
ARG INSTALL_NODEJS=true
# Node.js LTS line to install (latest release of that major, from nodejs.org)
ARG NODE_MAJOR=24
# PostgreSQL client tools (pg_dump, psql) from the PGDG repo, e.g. "17". Empty = not installed.
ARG POSTGRES_CLIENT_VERSION=
# Playwright version whose Chromium system libraries to install, e.g. "1.63.0". Empty = skip.
# Needs Node. Only the libraries are baked in; workflows install the browser itself.
ARG PLAYWRIGHT_DEPS_VERSION=
# only used if the distro packages for buildx/compose are unavailable
ARG BUILDX_VERSION=v0.19.3
ARG COMPOSE_VERSION=v2.32.4

USER root
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Core tooling. docker.io provides the Docker CLI; the daemon in this package is
# never started, jobs use the host daemon through the mounted socket.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq openssl sudo unzip xz-utils lsb-release \
      gettext-base build-essential gh \
      python3 python3-pip python3-venv \
      docker.io \
 && (apt-get install -y --no-install-recommends docker-buildx docker-compose-v2 || true) \
 && rm -rf /var/lib/apt/lists/*

# Fallbacks if the distro has no buildx / compose plugin packages
RUN set -eux; \
    dpkgarch="$(dpkg --print-architecture)"; \
    unamearch="$(uname -m)"; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    if ! docker buildx version >/dev/null 2>&1; then \
      curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-buildx \
        "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${dpkgarch}"; \
      chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx; \
    fi; \
    if ! docker compose version >/dev/null 2>&1; then \
      curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${unamearch}"; \
      chmod +x /usr/local/lib/docker/cli-plugins/docker-compose; \
    fi; \
    docker buildx version; docker compose version

# Node.js + npm (official tarball, checksum-verified, arch-aware)
RUN if [ "${INSTALL_NODEJS}" = "true" ]; then \
      set -eux; \
      case "$(dpkg --print-architecture)" in amd64) a=x64 ;; arm64) a=arm64 ;; *) exit 1 ;; esac; \
      base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"; \
      curl -fsSLo /tmp/SHASUMS256.txt "$base/SHASUMS256.txt"; \
      file="$(grep -E " node-v[0-9.]+-linux-${a}\.tar\.xz\$" /tmp/SHASUMS256.txt | awk '{print $2}')"; \
      test -n "$file"; \
      curl -fsSLo "/tmp/$file" "$base/$file"; \
      (cd /tmp && grep " ${file}\$" SHASUMS256.txt | sha256sum -c -); \
      tar -xJf "/tmp/$file" -C /usr/local --strip-components=1 --no-same-owner \
        --exclude='*.md' --exclude=LICENSE; \
      rm -f /tmp/SHASUMS256.txt "/tmp/$file"; \
      node --version; npm --version; \
    fi

# Playwright: Chromium's system libraries only (needs Node, so it comes after the Node layer)
RUN if [ -n "${PLAYWRIGHT_DEPS_VERSION}" ]; then \
      set -eux; \
      command -v npx >/dev/null || { echo "PLAYWRIGHT_DEPS_VERSION needs INSTALL_NODEJS=true" >&2; exit 1; }; \
      apt-get update; \
      npx --yes "playwright@${PLAYWRIGHT_DEPS_VERSION}" install-deps chromium; \
      rm -rf /var/lib/apt/lists/* /root/.npm; \
    fi

# PostgreSQL client tools from the official PGDG apt repository
RUN if [ -n "${POSTGRES_CLIENT_VERSION}" ]; then \
      set -eux; \
      apt-get update; \
      apt-get install -y --no-install-recommends postgresql-common; \
      /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y; \
      apt-get install -y --no-install-recommends "postgresql-client-${POSTGRES_CLIENT_VERSION}"; \
      rm -rf /var/lib/apt/lists/*; \
      pg_dump --version; \
    fi

# AWS CLI v2 (official installer, arch-aware)
RUN if [ "${INSTALL_AWS_CLI}" = "true" ]; then \
      set -eux; \
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip; \
      unzip -q /tmp/awscliv2.zip -d /tmp; \
      /tmp/aws/install; \
      rm -rf /tmp/aws /tmp/awscliv2.zip; \
      aws --version; \
    fi

# Azure CLI (Microsoft's official apt installer, supports amd64 and arm64)
RUN if [ "${INSTALL_AZURE_CLI}" = "true" ]; then \
      set -eux; \
      curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash; \
      rm -rf /var/lib/apt/lists/*; \
      az version >/dev/null; \
    fi

# Org-specific tools: runner/tools.d/*.sh run in lexical order as root
COPY runner/tools.d/ /tmp/tools.d/
RUN set -e; \
    for s in /tmp/tools.d/*.sh; do \
      [ -e "$s" ] || continue; \
      echo ">>> tools.d: $s"; \
      TARGETARCH="$(dpkg --print-architecture)" bash "$s"; \
    done; \
    rm -rf /tmp/tools.d

COPY scripts/get-token.sh /usr/local/bin/gha-get-token
COPY runner/entrypoint.sh /usr/local/bin/gha-entrypoint
RUN chmod 0755 /usr/local/bin/gha-get-token /usr/local/bin/gha-entrypoint

USER runner
WORKDIR /home/runner
ENTRYPOINT ["/usr/local/bin/gha-entrypoint"]
