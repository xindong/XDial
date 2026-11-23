#!/bin/sh
# Turns a stock Ubuntu/Debian image into a stand-in cloud server: real systemd,
# sshd and apt, plus test accounts. Passwords are set by the test at run time.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends systemd systemd-sysv dbus openssh-server sudo iproute2 ca-certificates netcat-openbsd
rm -rf /var/lib/apt/lists/*
systemctl enable ssh || systemctl enable sshd
systemctl mask getty.target console-getty.service systemd-firstboot.service
useradd -m -s /bin/bash deploy && usermod -aG sudo deploy
useradd -m -s /bin/bash nopass && echo 'nopass ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/nopass
useradd -m -s /bin/bash plain
mkdir -p /root/.ssh && chmod 700 /root/.ssh
printf 'PasswordAuthentication yes\nPermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/xdial-test.conf
