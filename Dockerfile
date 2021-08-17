FROM ubuntu:20.04 as builder
ARG DEBIAN_FRONTEND=noninteractive

############################## Make ROOTFS ##############################

# Runtime Environment
RUN apt-get update && \
    apt-get install -y \
    ca-certificates bash curl wget time \
    tar xz-utils gzip squashfs-tools dosfstools \
    xorriso \
    isolinux \
    syslinux-efi \
    mtools bash

COPY [ "alpine-chroot-install", "/opt/alpine-chroot-install" ]

ARG TARGET_ARCH=x86_64

RUN PACKAGES="bash ca-certificates curl gawk blkid util-linux mkinitfs efibootmgr dosfstools ethtool iproute2 dhcpcd sed wget tar xz gzip openssh-client openssh-server openssh-sftp-server linux-lts linux-firmware-none grub grub-bios grub-efi" && \
    mkdir -p /work/rootfs && \
    chmod +x /opt/alpine-chroot-install && \
    /opt/alpine-chroot-install \
    -a "${TARGET_ARCH}" \
    -b v3.13 \
    -p "${PACKAGES}" \
    -d /work/rootfs && \
    mkdir -p /work/rootfs/tmp/pkg/${TARGET_ARCH}

COPY [ "target-install.sh", "/work/rootfs/tmp/target-install.sh" ]

RUN chmod +x /work/rootfs/tmp/target-install.sh && \
    /work/rootfs/enter-chroot /tmp/target-install.sh && \
    rm -rf /work/rootfs/tmp/*

RUN time mksquashfs /work/rootfs /work/rootfs.sqfs -comp gzip -b 131072

############################## Make ISO for development ##############################

ARG ISO_WORKDIR=/work/iso
RUN mkdir -p \
    $ISO_WORKDIR/staging \
    $ISO_WORKDIR/staging/isolinux \
    $ISO_WORKDIR/staging/live \
    $ISO_WORKDIR/staging/target \
    $ISO_WORKDIR/staging/boot && \
    cp /work/rootfs.sqfs $ISO_WORKDIR/staging/rootfs.sqfs

COPY [ "initramfs-ramroot.sh", "/work/rootfs/tmp/initramfs-ramroot.sh" ]
RUN chmod +x /work/rootfs/tmp/initramfs-ramroot.sh && \
    /work/rootfs/enter-chroot mkinitfs \
    -C gzip \
    -F "ata base cdrom ext4 keymap scsi squashfs" \
    -i "/tmp/initramfs-ramroot.sh" \
    -b / \
    $(ls /work/rootfs/lib/modules/ | head -n 1) && \
    cp /work/rootfs/boot/vmlinuz-* $ISO_WORKDIR/staging/live/vmlinuz && \    
    cp /work/rootfs/boot/initramfs-* $ISO_WORKDIR/staging/live/initrd

COPY [ "isolinux.cfg", "/tmp/" ]
RUN cp /usr/lib/ISOLINUX/isolinux.bin $ISO_WORKDIR/staging/isolinux/ && \
    cp /usr/lib/syslinux/modules/bios/* $ISO_WORKDIR/staging/isolinux/ && \
    cp /tmp/isolinux.cfg $ISO_WORKDIR/staging/isolinux/

RUN xorriso \
    -as mkisofs \
    -iso-level 3 \
    -o "/work/pe.iso" \
    -full-iso9660-filenames \
    -volid "alpine-live" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-boot \
        isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog isolinux/isolinux.cat \
    "$ISO_WORKDIR/staging"

FROM scratch
COPY --from=builder [ "/work/pe.iso", "/" ]

