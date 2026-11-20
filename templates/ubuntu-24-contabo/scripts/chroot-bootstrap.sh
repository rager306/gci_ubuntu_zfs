#!/usr/bin/env bash

# Copyright 2025 Genesis Corporation
#
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

set -eu
set -x
set -o pipefail

export DEBIAN_FRONTEND=noninteractive

mkdir -p /run/systemd/resolve/
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
apt update
apt install zfs-initramfs -y

# Populate mount list
mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/rpool
zed -F &
sleep 2
kill $(cat /run/zed.pid)
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*
sed -i '/LABEL=cloudimg-rootfs/d' /etc/fstab

sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&root=ZFS=rpool\/ROOT\/ubuntu init_on_alloc=0 init_on_free=0 /' /etc/default/grub
# --- BEGIN Contabo customization ---
# All values are rendered by Packer into /tmp/contabo.conf
# (see files/contabo.conf.tpl and contabo.auto.pkrvars.hcl).
. /tmp/contabo.conf
: "${CONTABO_IPV4:?}" "${CONTABO_IPV4_GW:?}" "${CONTABO_DNS:?}" \
  "${CONTABO_HOSTNAME:?}" "${CONTABO_SSH_KEY:?}" "${CONTABO_ARC_MAX:?}"
if [ -n "$CONTABO_IPV6" ]; then : "${CONTABO_IPV6_GW:?}"; fi

echo "$CONTABO_HOSTNAME" > /etc/hostname
sed -i "/$CONTABO_HOSTNAME/d" /etc/hosts
sed -i "1i127.0.1.1 $CONTABO_HOSTNAME $CONTABO_HOSTNAME" /etc/hosts

# cloud-init: never touch the network (static netplan is baked below),
# but keep NoCloud so the official Contabo flow works: user-data pasted in
# the panel on Reinstall (or API user_data / Terraform) is applied on
# first boot. None = fallback when no config drive is attached.
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'NETEOF'
network: {config: disabled}
NETEOF
cat > /etc/cloud/cloud.cfg.d/90-datasources.cfg <<'DSEOF'
datasource_list: [ NoCloud, None ]
DSEOF

# Static network. IPv6 parts are appended only when the address is set.
addr_block="        - ${CONTABO_IPV4}"
route_block="        - to: default
          via: ${CONTABO_IPV4_GW}"
if [ -n "$CONTABO_IPV6" ]; then
    addr_block="$addr_block
        - ${CONTABO_IPV6}"
    route_block="$route_block
        - to: default
          via: ${CONTABO_IPV6_GW}
          scope: link"
fi

cat > /etc/netplan/01-contabo.yaml <<NPEOF
network:
  version: 2
  ethernets:
    nic0:
      match:
        name: "e*"
      set-name: nic0
      addresses:
${addr_block}
      routes:
${route_block}
      nameservers:
        addresses: [${CONTABO_DNS}]
NPEOF
chmod 600 /etc/netplan/01-contabo.yaml
# Fail the build early if the generated netplan is invalid
netplan generate

# ZFS ARC limit
cat > /etc/modprobe.d/zfs.conf <<ZFSEOF
options zfs zfs_arc_max=${CONTABO_ARC_MAX}
ZFSEOF

# SSH: key-only auth. sshd uses the FIRST value obtained for a keyword
# and sshd_config.d drop-ins are read in lexical order, so ours must sort
# before cloud-init's 50-cloud-init.conf (PasswordAuthentication yes from
# the build); remove that file as well.
install -d -m 700 /root/.ssh
printf '%s\n' "$CONTABO_SSH_KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
cat > /etc/ssh/sshd_config.d/00-contabo.conf <<'SSHEOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHEOF

# First-boot: grow rpool to fill the whole system disk.
# Contabo exposes the disk via virtio_scsi (/dev/sda*), but the device
# is detected at runtime, so any naming works (sdX, vdX, nvme, mmcblk).
apt-get install -y cloud-guest-utils parted
cat > /usr/local/sbin/expand-rpool.sh <<'EXPEOF'
#!/bin/bash
set -eu
MARK=/var/lib/.rpool-expanded
[ -e "$MARK" ] && exit 0

zpool set autoexpand=on rpool

# Partition rpool lives on, straight from the pool itself
member=$(zpool status -LP rpool | awk '$1 ~ /^\/dev\// {print $1; exit}')
case "$member" in
    */nvme*n*p[0-9]*|*/mmcblk*p[0-9]*)
        disk="${member%p*}"; partnum="${member##*p}" ;;
    *)
        disk="${member%%[0-9]*}"; partnum="${member##*[!0-9]}" ;;
esac

growpart "$disk" "$partnum"
partprobe "$disk" 2>/dev/null || partx --update "$disk" || true
zpool online -e rpool "$member" || true

touch "$MARK"
systemctl disable zpool-expand.service >/dev/null 2>&1 || true
EXPEOF
chmod +x /usr/local/sbin/expand-rpool.sh
cat > /etc/systemd/system/zpool-expand.service <<'UNITEOF'
[Unit]
Description=Expand rpool to fill the whole system disk
ConditionPathExists=!/var/lib/.rpool-expanded
After=zfs-mount.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/expand-rpool.sh
[Install]
WantedBy=multi-user.target
UNITEOF
systemctl enable zpool-expand.service

# --- Maintenance & hardening (Ubuntu/KVM best practices) ---
# QEMU guest agent: lets the virtualization host manage the VM cleanly;
# unattended-upgrades: security updates (on by default in cloud images,
# kept explicit); zfs-auto-snapshot: honours the com.sun:auto-snapshot
# properties set by prepare-zfs-root.sh; ufw: host firewall.
apt-get install -y qemu-guest-agent unattended-upgrades zfs-auto-snapshot ufw

# Firewall: default-deny incoming, allow SSH. Only rule files are
# written here ("ufw allow" loads nothing into the kernel — "ufw enable"
# inside the build chroot would firewall the build VM itself and cut
# Packer's SSH); ENABLED=yes brings it up on the first boot. This
# complements the free network-level Contabo firewall (panel-managed).
ufw allow OpenSSH
sed -i 's/^ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf

# Monthly scrub (shipped disabled); zfs-auto-snapshot ships its own
# cron schedule: frequent 15min/4, hourly/24, daily/31, weekly/8,
# monthly/12, skipping datasets with auto-snapshot=false.
systemctl enable zfs-scrub-monthly@rpool.timer
# --- END Contabo customization ---

update-initramfs -c -k all
update-grub
grub-install /dev/vdb

# Cleanup
# Shell history
history -c

# Cloud-init clean
sudo cloud-init clean --log --seed

# Fresh machine-id per deployment (systemd regenerates it on boot)
rm -f /etc/machine-id
touch /etc/machine-id

# Cleanup apt cache
apt-get -y autoremove --purge
apt-get -y clean
apt-get -y autoclean

# Sync FS
sync

zpool sync
zpool trim -w rpool
echo '0' > /sys/module/zfs/parameters/zfs_initialize_value
zpool initialize -w rpool
