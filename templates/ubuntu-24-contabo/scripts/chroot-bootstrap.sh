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
echo vmi2929903 > /etc/hostname
sed -i '/vmi2929903/d' /etc/hosts
sed -i '1i127.0.1.1 vmi2929903 vmi2929903' /etc/hosts

# Disable cloud-init network + datasource (we bake static netplan below)
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'NETEOF'
network: {config: disabled}
NETEOF
cat > /etc/cloud/cloud.cfg.d/90-datasources.cfg <<'DSEOF'
datasource_list: [ None ]
DSEOF

cat > /etc/netplan/01-contabo.yaml <<'NPEOF'
network:
  version: 2
  ethernets:
    nic0:
      match:
        name: "e*"
      set-name: nic0
      addresses:
        - 164.68.106.228/24
        - 2a02:c207:2292:9903::1/64
      routes:
        - to: default
          via: 164.68.106.1
        - to: default
          via: fe80::1
          scope: link
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
NPEOF
chmod 600 /etc/netplan/01-contabo.yaml

# ZFS ARC limit (48G RAM host)
cat > /etc/modprobe.d/zfs.conf <<'ZFSEOF'
options zfs zfs_arc_max=12884901888
ZFSEOF

# SSH: key-only root login
install -d -m 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'PUBEOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJt9f8RyvEMGx2ZmzFrNs80a1FJ/Wx3QEod2D69A1n3P lan\acc16@acc16
PUBEOF
chmod 600 /root/.ssh/authorized_keys
cat > /etc/ssh/sshd_config.d/99-contabo.conf <<'SSHEOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
SSHEOF

# First-boot: expand rpool to the whole Contabo disk (/dev/sda, 400G)
apt-get install -y cloud-guest-utils
cat > /usr/local/sbin/expand-rpool.sh <<'EXPEOF'
#!/bin/bash
set -eu
MARK=/var/lib/.rpool-expanded
[ -e "$MARK" ] && exit 0
zpool set autoexpand=on rpool || true
growpart /dev/sda 1 || true
partprobe /dev/sda || true
zpool online -e rpool /dev/sda1 || true
zpool set autoexpand=on rpool
touch "$MARK"
systemctl disable zpool-expand.service >/dev/null 2>&1 || true
EXPEOF
chmod +x /usr/local/sbin/expand-rpool.sh
cat > /etc/systemd/system/zpool-expand.service <<'UNITEOF'
[Unit]
Description=Expand rpool to fill the whole Contabo disk
ConditionPathExists=!/var/lib/.rpool-expanded
After=zfs-mount.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/expand-rpool.sh
[Install]
WantedBy=multi-user.target
UNITEOF
systemctl enable zpool-expand.service
# --- END Contabo customization ---

update-initramfs -c -k all
update-grub
grub-install /dev/vdb

# Cleanup
# Shell history
history -c

# Cloud-init clean
sudo cloud-init clean --log --seed

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
