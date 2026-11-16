# Installation

> Describes the **planned** installer interface. Flags may change during implementation.

## Prerequisites (all platforms)

1. **A Linux VM**: Ubuntu 24.04 LTS (recommended) or 22.04, x86_64 or arm64. Debian 12 is best effort.
2. **A second disk for Docker** (recommended): 100–400 GB, SSD-backed.
3. **GitHub credentials for token minting** (runners are always org-level), one of:
   - **Fine-grained PAT** (quickest): resource owner = your org, permission
     *Organization → Self-hosted runners: Read & write*.
   - **GitHub App** (recommended for long-lived hosts): install it on the org with the same
     permission. You need the App ID, the Installation ID and the private key (`.pem`).

   The installer picks whichever you provide. See [configuration.md](configuration.md#pat-vs-github-app).
4. **A runner image source**, one of: an image already pushed to a registry (GHCR, ECR, Docker Hub,
   Harbor, …), or nothing, in which case pass `--build-image` and the host builds it.
5. **A runner group** in the org (Settings → Actions → Runner groups) limited to the
   private repos that may use these runners. Do not allow public repositories.
6. Outbound HTTPS to GitHub and your image registry (see [architecture.md](architecture.md#network)).

## Option A: Existing VM (any platform)

```bash
# Pin to a release tag, not main
VER=v0.1.0
curl -fsSLo install.sh "https://raw.githubusercontent.com/<org>/gha-host/${VER}/install.sh"
less install.sh                       # review it: you are about to run it as root

sudo install -d -m 0700 /etc/gha-host
```

**Quick start with a PAT, building the image on the host:**

```bash
sudo install -m 0600 /dev/stdin /etc/gha-host/pat <<< 'github_pat_xxx'   # or copy a file in

sudo bash install.sh \
  --org my-org \
  --runners 5 \
  --runner-group build-runners \
  --labels gha-host,build \
  --build-image \
  --data-disk /dev/sdb
```

**With a GitHub App, pulling from a registry:**

```bash
sudo install -m 0600 /path/to/app.pem /etc/gha-host/github-app.pem
sudo install -m 0600 /path/to/ghcr-token /etc/gha-host/registry-password   # read:packages

sudo bash install.sh \
  --org my-org \
  --app-id 123456 --installation-id 7890123 --app-key /etc/gha-host/github-app.pem \
  --image ghcr.io/my-org/gha-host-runner:latest --registry-user ci-bot \
  --runners 5 --runner-group build-runners --labels gha-host,build,deploy \
  --data-disk /dev/sdb
```

The installer will:

1. Run preflight checks (OS, arch, root, connectivity, resources).
2. Detect the platform (EC2 via IMDSv2, otherwise a generic VM). Install `qemu-guest-agent` on KVM.
3. Format and mount `--data-disk` at `--data-dir` (default `/data`), **only if the disk is blank**
   (or already carries a gha-host `GHADATA` filesystem). Docker data goes to `/data/docker`, runner
   workspaces to `/data/work`.
4. Install Docker Engine + compose plugin and write `/etc/docker/daemon.json`.
5. Copy the code to `/opt/gha-host` and write `/etc/gha-host/gha-host.env`.
6. Log in to the registry if needed (ECR / basic), then pull the runner image, or build it with `--build-image`. Render the compose file.
7. Enable `gha-host.service` and `gha-prune.timer`, plus `gha-update.timer` if you pass
   `--auto-update` (or set `AUTO_UPDATE=true` in the env file or SSM `config`).
8. Wait for all runners to show **Idle** in GitHub and print a summary.

Re-run the same command to change settings or upgrade. It is idempotent.

## Option B: AWS EC2

### One-time AWS setup

1. **SSM parameters** (SecureString, default KMS key or a CMK), under `/gha-host/<host-name>/`:

   | Parameter | Value |
   |---|---|
   | `/gha-host/<name>/org` | `my-org` |
   | `/gha-host/<name>/pat` | PAT, **or** the three App parameters below |
   | `/gha-host/<name>/app-id` | App ID |
   | `/gha-host/<name>/installation-id` | Installation ID |
   | `/gha-host/<name>/app-key` | PEM contents (SecureString, advanced tier if > 4 KB) |
   | `/gha-host/<name>/registry-password` | Optional: for `basic` registry auth (not needed for ECR) |
   | `/gha-host/<name>/config` | Optional: extra env lines (`RUNNER_COUNT=5`, `RUNNER_LABELS=…`, `RUNNER_IMAGE=…`) |

2. **IAM instance profile** with `provisioning/ec2/iam-policy.json`:
   `ssm:GetParameter(s)` + `ssm:GetParametersByPath` on `arn:aws:ssm:*:*:parameter/gha-host/<name>/*`,
   `kms:Decrypt` on the key, plus `AmazonSSMManagedInstanceCore` for Session Manager access.
   Add ECR pull permissions if the image is in ECR.
3. **Security group**: no inbound rules. Egress 443 (and 80 for apt).
4. **Subnet**: private subnet with a NAT gateway, or a public subnet with a public IP. The
   runners need to reach whatever they deploy to.

### Launch

- AMI: Ubuntu 24.04 LTS (Canonical).
- Instance type: see [sizing](architecture.md#sizing-guidance-starting-point-validate-with-benchmarks).
- Root volume: 30 GB gp3. **Second volume**: 200 GB gp3 (e.g. 6000 IOPS / 500 MB/s).
- IMDSv2: required (hop limit 1. Containers shouldn't reach IMDS unless you want them to;
  see [security.md](security.md)).
- Tag `Name=<host-name>` (used for runner naming and the SSM path).
- **User data**: `provisioning/ec2/user-data.sh`:

```bash
#!/bin/bash
set -euo pipefail
NAME="gha-aws-01"          # runner name prefix AND the SSM path suffix
REPO="OWNER/gha-host"; REF="v0.1.0"
apt-get update -qq && apt-get install -y -qq curl ca-certificates
curl -fsSLo /root/install.sh "https://raw.githubusercontent.com/$REPO/$REF/install.sh"
bash /root/install.sh --repo "$REPO" --ref "$REF" --platform ec2 --name "$NAME" \
  --ssm-path "/gha-host/$NAME" --data-disk auto --build-image --yes
```

(Full version, including private-repo notes, in `provisioning/ec2/user-data.sh`.) The SSM `config`
parameter can carry `RUNNER_COUNT`, `RUNNER_LABELS`, `RUNNER_IMAGE`, and so on.

`--data-disk auto` picks the first unformatted, unmounted non-root NVMe/EBS volume.

Install logs: `/var/log/gha-host-install.log` and `journalctl -u cloud-final`.

### Self-healing (optional, phase 6)

No Terraform is provided. In the console or with the AWS CLI, save the settings above as a launch
template and put it in an Auto Scaling Group with min=max=1. If the instance dies, the ASG
replaces it, user-data re-installs, and runners re-register with `--replace` under the same
names. Only the warm cache is lost.

## Option C: Proxmox VE

### One-time: create an Ubuntu cloud-image template

```bash
# On the Proxmox host
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qm create 9000 --name ubuntu-2404-tpl --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single --agent enabled=1 --cpu host
qm importdisk 9000 noble-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsi0 local-lvm:vm-9000-disk-0,discard=on,iothread=1,ssd=1 \
  --ide2 local-lvm:cloudinit --boot order=scsi0 --serial0 socket --vga serial0
qm template 9000
```

### Create a runner VM

`provisioning/proxmox/create-vm.sh` will wrap this:

```bash
VMID=210; NAME=gha-host-01
qm clone 9000 $VMID --name $NAME --full
qm set $VMID --cores 8 --memory 32768
qm resize $VMID scsi0 32G
qm set $VMID --scsi1 local-lvm:200,discard=on,iothread=1,ssd=1      # Docker data disk
qm set $VMID --ipconfig0 ip=dhcp --sshkeys ~/.ssh/authorized_keys --ciuser ubuntu
qm set $VMID --cicustom "user=local:snippets/gha-host-user.yaml"     # optional, see below
qm start $VMID
```

### Install

Either SSH in and follow **Option A** (with `--data-disk /dev/sdb`), or let cloud-init run it
with `provisioning/proxmox/cloud-init.yaml` placed in `/var/lib/vz/snippets/`:

```yaml
#cloud-config
package_update: true
packages: [qemu-guest-agent, curl]
write_files:
  - path: /etc/gha-host/github-app.pem
    permissions: '0600'
    content: |
      -----BEGIN RSA PRIVATE KEY-----
      ...
runcmd:
  - systemctl enable --now qemu-guest-agent
  - curl -fsSLo /root/install.sh https://raw.githubusercontent.com/<org>/gha-host/v0.1.0/install.sh
  - bash /root/install.sh --org my-org --auth app --app-id 123456 --installation-id 7890123
      --app-key /etc/gha-host/github-app.pem --runners 5 --labels gha-host,onprem,build
      --build-image --data-disk /dev/sdb
```

> Snippets on Proxmox storage are readable by Proxmox admins. If that's a concern, inject only an
> SSH key with cloud-init and copy the App key over SSH afterwards.

## Verify

```bash
sudo systemctl status gha-host
sudo /opt/gha-host/scripts/healthcheck.sh
docker ps --filter label=gha-host.runner
```

In GitHub: **Org → Settings → Actions → Runners**. You should see `<host>-1 … <host>-N`, Idle.

Then run the smoke-test workflow (`.github/workflows/smoke-test.yml`), or see
[workflow-usage.md](workflow-usage.md).

## Uninstall

```bash
sudo /opt/gha-host/uninstall.sh            # deregister runners, stop and remove services
sudo /opt/gha-host/uninstall.sh --purge    # also wipe Docker data, /data/work and /etc/gha-host
sudo /opt/gha-host/uninstall.sh --deregister-only --name old-host   # remove a dead host's runners from GitHub
```
