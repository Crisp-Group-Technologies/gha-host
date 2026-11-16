# syntax=docker/dockerfile:1
# gha-host runner image. Build from the repo root:
#   docker build -f runner/Dockerfile -t gha-host-runner:local .
ARG RUNNER_VERSION=2.338.2
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

ARG INSTALL_AWS_CLI=true
ARG INSTALL_AZURE_CLI=true
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
      ca-certificates curl git gnupg jq openssl sudo unzip lsb-release \
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
