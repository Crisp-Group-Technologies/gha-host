#!/usr/bin/env bash
# Run on a Proxmox VE node. Clones an Ubuntu cloud-image template into a runner VM
# with a separate Docker data disk. Then SSH in and run install.sh (docs/install.md).
#
# One-time template creation is in docs/install.md (Option C).
# Usage: VMID=210 NAME=gha-host-01 ./create-vm.sh
set -euo pipefail

VMID="${VMID:?set VMID}"
NAME="${NAME:?set NAME}"
TEMPLATE="${TEMPLATE:-9000}"
STORAGE="${STORAGE:-local-lvm}"
CORES="${CORES:-8}"
MEMORY_MB="${MEMORY_MB:-32768}"
ROOT_GB="${ROOT_GB:-32}"
DATA_GB="${DATA_GB:-200}"
SSHKEYS="${SSHKEYS:-$HOME/.ssh/authorized_keys}"
BRIDGE="${BRIDGE:-vmbr0}"
CIUSER="${CIUSER:-ubuntu}"

qm clone "$TEMPLATE" "$VMID" --name "$NAME" --full
qm set "$VMID" --cores "$CORES" --memory "$MEMORY_MB" --net0 "virtio,bridge=$BRIDGE"
qm resize "$VMID" scsi0 "${ROOT_GB}G"
qm set "$VMID" --scsi1 "$STORAGE:$DATA_GB,discard=on,iothread=1,ssd=1"
qm set "$VMID" --ipconfig0 ip=dhcp --ciuser "$CIUSER" --sshkeys "$SSHKEYS"
[[ -n ${CICUSTOM:-} ]] && qm set "$VMID" --cicustom "user=$CICUSTOM"
qm start "$VMID"
echo "VM $VMID ($NAME) started. The data disk is /dev/sdb inside the VM."
echo "Next: ssh $CIUSER@<vm-ip> and run install.sh with --data-disk /dev/sdb (see docs/install.md)."
