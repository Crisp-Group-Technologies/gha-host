#!/bin/bash
# EC2 user data for a gha-host runner host (Ubuntu 22.04/24.04).
# Prerequisites: SSM parameters under /gha-host/$NAME/ and an instance profile with
# provisioning/ec2/iam-policy.json. See docs/install.md.
set -euo pipefail

NAME="gha-aws-01"             # also the SSM path suffix and the runner name prefix
REPO="OWNER/gha-host"         # GitHub repo that hosts this project
REF="v0.1.0"                  # pin a release tag
# For a private repo, put a read-only token in SSM at /gha-host/$NAME/repo-token and
# uncomment the next line (needs the aws CLI, installed by install.sh on a second run):
# export GITHUB_TOKEN="$(aws ssm get-parameter --name /gha-host/$NAME/repo-token --with-decryption --query Parameter.Value --output text)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq curl ca-certificates
curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
  -o /root/install.sh "https://raw.githubusercontent.com/$REPO/$REF/install.sh"
bash /root/install.sh --repo "$REPO" --ref "$REF" \
  --platform ec2 --name "$NAME" --ssm-path "/gha-host/$NAME" \
  --data-disk auto --build-image --yes
