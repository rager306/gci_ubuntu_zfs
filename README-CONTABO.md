# Contabo-специфичная сборка Ubuntu 24.04 root-on-ZFS

Форк infraguys/gci_ubuntu_zfs, адаптированный под Contabo VPS (SeaBIOS, статический IP, ключ root).

Изменения против исходного шаблона `ubuntu-24` (всё в `templates/ubuntu-24-contabo/scripts/chroot-bootstrap.sh`):
- статический netplan `01-contabo.yaml` (v4 164.68.106.228/24 gw 164.68.106.1, v6 2a02:c207:2292:9903::1/64 gw fe80::1, DNS 8.8.8.8/1.1.1.1), cloud-init сеть и datasource отключены;
- hostname `vmi2929903`, root-вход только по ssh-ключу (`PermitRootLogin prohibit-password`, `PasswordAuthentication no`), authorized_keys вшит;
- ARC 12G (`/etc/modprobe.d/zfs.conf`, до update-initramfs);
- systemd-юнит `zpool-expand.service`: при первой загрузке growpart /dev/sda 1 + `zpool online -e rpool` — пул растягивается на весь диск (400G), затем юнит самоотключается.

Сборка: push в форк запускает Actions; artifact `ubuntu-24-contabo-qcow2`. Тег (v1) публикует релиз с asset `ubuntu-24-contabo_zfs.qcow2` — ссылку на него можно отдать Contabo Custom Images по URL.
