#!/bin/bash

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update del mdev sysinit || true
rc-update add udev sysinit
rc-update add udev-trigger sysinit
rc-update add hwdrivers sysinit

rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot

rc-update add local boot

rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown

rc-update add networking sysinit
rc-update add sshd sysinit

sed -i -E 's/#?PubkeyAuthentication .*$/PubkeyAuthentication yes/g' /etc/ssh/sshd_config
sed -i -E 's/#?PermitEmptyPasswords .*$/PermitEmptyPasswords no/g' /etc/ssh/sshd_config
sed -i -E 's/#?PasswordAuthentication .*$/PasswordAuthentication yes/g' /etc/ssh/sshd_config
sed -i -E 's/^#?PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config
sed -i -E 's/^#ttyS0/ttyS0/g' /etc/inittab

cat <<EOF | tee /etc/network/interfaces
# The loopback network interface
auto lo                          
iface lo inet loopback

# The primary network interface
auto eth0
iface eth0 inet dhcp
EOF

