#!/bin/sh

# this is the init script version
VERSION=3.4.5-r3
SINGLEMODE=no
sysroot=/sysroot
repofile=/tmp/repositories

# some helpers
ebegin() {
	last_emsg="$*"
	[ "$KOPT_quiet" = yes ] && return 0
	echo -n " * $last_emsg: "
}
eend() {
	local msg
	if [ "$1" = 0 ] || [ $# -lt 1 ] ; then
		[ "$KOPT_quiet" = yes ] && return 0
		echo "ok."
	else
		shift
		if [ "$KOPT_quiet" = "yes" ]; then
			echo -n "$last_emsg "
		fi
		echo "failed. $*"
		echo "initramfs emergency recovery shell launched. Type 'exit' to continue boot"
		/bin/busybox sh
	fi
}

# find mount dir for given device in an fstab
# returns global MNTOPTS
find_mnt() {
	local search_dev="$1"
	local fstab="$2"
	case "$search_dev" in
	UUID*|LABEL*) search_dev=$(findfs "$search_dev");;
	esac
	MNTOPTS=
	[ -r "$fstab" ] || return 1
	local search_maj_min=$(stat -L -c '%t,%T' $search_dev)
	while read dev mnt fs MNTOPTS chk; do
		case "$dev" in
		UUID*|LABEL*) dev=$(findfs "$dev");;
		esac
		if [ -b "$dev" ]; then
			local maj_min=$(stat -L -c '%t,%T' $dev)
			if [ "$maj_min" = "$search_maj_min" ]; then
				echo "$mnt"
				return
			fi
		fi
	done < $fstab
	MNTOPTS=
}

#  add a boot service to $sysroot
rc_add() {
	mkdir -p $sysroot/etc/runlevels/$2
	ln -sf /etc/init.d/$1 $sysroot/etc/runlevels/$2/$1
}

# Recursively resolve tty aliases like console or tty0
list_console_devices() {
	if ! [ -e /sys/class/tty/$1/active ]; then
		echo $1
		return
	fi

	for dev in $(cat /sys/class/tty/$1/active); do
		list_console_devices $dev
	done
}

setup_inittab_console(){
	term=vt100
	# Inquire the kernel for list of console= devices
	for tty in $(list_console_devices console); do
		# do nothing if inittab already have the tty set up
		if ! grep -q "^$tty:" $sysroot/etc/inittab; then
			echo "# enable login on alternative console" \
				>> $sysroot/etc/inittab
			# Baudrate of 0 keeps settings from kernel
			echo "$tty::respawn:/sbin/getty -L 0 $tty $term" \
				>> $sysroot/etc/inittab
		fi
		if [ -e "$sysroot"/etc/securetty ] && ! grep -q -w "$tty" "$sysroot"/etc/securetty; then
			echo "$tty" >> "$sysroot"/etc/securetty
		fi
	done
}

# determine the default interface to use if ip=dhcp is set
# uses the first "eth" interface with operstate 'up'.
ip_choose_if() {
	if [ -n "$KOPT_BOOTIF" ]; then
		mac=$(printf "%s\n" "$KOPT_BOOTIF"|sed 's/^01-//;s/-/:/g')
		dev=$(grep -l $mac /sys/class/net/*/address|head -n 1)
		dev=${dev%/*}
		[ -n "$dev" ] && echo "${dev##*/}" && return
	fi
	for x in /sys/class/net/eth*; do
		if grep -iq up $x/operstate;then
			[ -e "$x" ] && echo ${x##*/} && return
		fi
	done
	[ -e "$x" ] && echo ${x##*/} && return
}

# find the dirs under ALPINE_MNT that are boot repositories
find_boot_repositories() {
	if [ -n "$ALPINE_REPO" ]; then
		echo "$ALPINE_REPO"
	else
		find /media/* -name .boot_repository -type f -maxdepth 3 \
			| sed 's:/.boot_repository$::'
	fi
}

setup_nbd() {
	modprobe -q nbd max_part=8 || return 1
	local IFS=, n=0
	set -- $KOPT_nbd
	unset IFS
	for ops; do
		local server="${ops%:*}"
		local port="${ops#*:}"
		local device="/dev/nbd${n}"
		[ -b "$device" ] || continue
		nbd-client "$server" "$port" "$device" && n=$((n+1))
	done
	[ "$n" != 0 ] || return 1
}

rtc_exists() {
	local rtc=
	for rtc in /dev/rtc /dev/rtc[0-9]*; do
		[ -e "$rtc" ] && break
	done
	[ -e "$rtc" ]
}

# This is used to predict if network access will be necessary
is_url() {
	case "$1" in
	http://*|https://*|ftp://*)
		return 0;;
	*)
		return 1;;
	esac
}

parse_video_opts()
{
		local OPTS="$1"
		local IFS=","

		# Must be a line like video=<fbdriver>:<opt1>,[opt2]...
		if [ "${OPTS}" = "${OPTS%%:*}" ]; then
				return
		fi
		OPTS="${OPTS#*:}"
		for opt in ${OPTS}; do
				# Already in the "<arg>=<value>" form
				if [ "${opt}" != "${opt#*=}" ]; then
						echo -n "$opt "
				# In the "<arg>:<value>" form
				elif [ "${opt}" != "${opt#*:}" ]; then
						echo -n "${opt%:*}=${opt#*:} "
				# Presumably a modevalue without the "mode=" prefix
				elif [ "${opt}" != "${opt#[0-9]*x[0-9]}" ]; then
						echo -n "mode=$opt "
				# Presumably a boolean
				else
						echo -n "${opt}=1 "
				fi
		done
}

init_video() {
	FB=""
	OPTS=""
	if [ -n "$KOPT_vga" ]; then
		FB="vesafb"
		OPTS=""
	fi
	if [ -n "$KOPT_video" ]; then
		FB=$KOPT_video
		FB="${FB%%:*}"
		OPTS="$(parse_video_opts "${KOPT_video}")"
	fi

	if [ -n "$FB" ]; then
		# Some framebuffer devices need character devices :-/
		udevadm settle
		modprobe ${FB} ${OPTS}
		udevadm settle
	else
		[ -d /sys/class/graphics/fbcon ] && \
		[ -d /sys/class/graphics/fb0   ] && \
		[ -d /sys/class/drm/card0	  ] || sleep 1

		if	! [ -d /sys/class/graphics/fbcon ] \
			|| ! [ -d /sys/class/graphics/fb0   ] \
			|| ! [ -d /sys/class/drm/card0	  ]
		then
			modprobe -q vesafb 2>/dev/null
			udevadm settle
		fi
	fi
}

start_udev() {
		local bins
		bins="/sbin/udevd /lib/systemd/systemd-udevd /usr/lib/systemd/systemd-udevd"
		for f in ${bins}; do
				if [ -x "$f" ] && [ ! -L "$f" ]; then
						command="$f"
				fi
		done
		if [ -z "$command" ]; then
				eerror "Unable to find udev executable."
				return 1
		fi
	
	$command --daemon

	if [ -e /proc/sys/kernel/hotplug ]; then
		echo "start hotplug"
		echo "" > /proc/sys/kernel/hotplug
		echo "end hotplug"
	fi
	if [ -w /sys/kernel/uevent_helper ]; then
		echo "start uevent_helper"
		echo > /sys/kernel/uevent_helper
		echo "stop uevent_helper"
	fi
	
	echo "udevadm trigger subsystems"
	udevadm trigger --type=subsystems --action=add
	echo "udevadm trigger devices"
	udevadm trigger --type=devices --action=add
	echo "udevadm settle"
	udevadm settle || true
	echo "ok"
	
	return 0
}


/bin/busybox mkdir -p /usr/bin /usr/sbin /proc /sys /dev $sysroot \
		/media/cdrom /media/usb /tmp /run/cryptsetup /run/plymouth

# Spread out busybox symlinks and make them available without full path
/bin/busybox --install -s
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Make sure /dev/null is a device node. If /dev/null does not exist yet, the command
# mounting the devtmpfs will create it implicitly as an file with the "2>" redirection.
# The -c check is required to deal with initramfs with pre-seeded device nodes without
# error message.
[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3

mount -t proc -o noexec,nosuid,nodev proc /proc
mount -t sysfs -o noexec,nosuid,nodev sysfs /sys
mount -t devtmpfs -o exec,nosuid,mode=0755,size=2M devtmpfs /dev 2>/dev/null \
	|| mount -t tmpfs -o exec,nosuid,mode=0755,size=2M tmpfs /dev

# pty device nodes (later system will need it)
[ -c /dev/ptmx ] || mknod -m 666 /dev/ptmx c 5 2
[ -d /dev/pts ] || mkdir -m 755 /dev/pts
mount -t devpts -o gid=5,mode=0620,noexec,nosuid devpts /dev/pts

# shared memory area (later system will need it)
[ -d /dev/shm ] || mkdir /dev/shm
mount -t tmpfs -o nodev,nosuid,noexec shm /dev/shm

mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

# read the kernel options. we need surve things like:
#  acpi_osi="!Windows 2006" xen-pciback.hide=(01:00.0)
set -- $(cat /proc/cmdline)

myopts="alpine_dev autodetect autoraid chart cryptroot cryptdm cryptheader cryptoffset
	cryptdiscards cryptkey debug_init dma init init_args keep_apk_new modules ovl_dev
	pkgs quiet root_size root usbdelay ip alpine_repo apkovl alpine_start splash
	blacklist overlaytmpfs rootfstype rootflags nbd resume s390x_net dasd ssh_key
	BOOTIF rootfsfile vga video"

for opt; do
	case "$opt" in
	s|single|1)
		SINGLEMODE=yes
		continue
		;;
	esac

	for i in $myopts; do
		case "$opt" in
		$i=*)	eval "KOPT_${i}"='${opt#*=}';;
		$i)	eval "KOPT_${i}=yes";;
		no$i)	eval "KOPT_${i}=no";;
		esac
	done
done

[ "$KOPT_quiet" = yes ] || echo "Alpine Init $VERSION"

# enable debugging if requested
[ -n "$KOPT_debug_init" ] && set -x

# set default values
: ${KOPT_init:=/sbin/init}
: ${KOPT_rootfsfile:=rootfs.sqfs}

echo "start udev"
start_udev

echo "start init_video"
init_video

# pick first keymap if found
for map in /etc/keymap/*; do
	if [ -f "$map" ]; then
		ebegin "Setting keymap ${map##*/}"
		zcat "$map" | loadkmap
		eend
		break
	fi
done

# start bootcharting if wanted
if [ "$KOPT_chart" = yes ]; then
	ebegin "Starting bootchart logging"
	/sbin/bootchartd start-initfs "$sysroot"
	eend 0
fi

# The following values are supported:
#   alpine_repo=auto         -- default, search for .boot_repository
#   alpine_repo=http://...   -- network repository
ALPINE_REPO=${KOPT_alpine_repo}
[ "$ALPINE_REPO" = "auto" ] && ALPINE_REPO=

# hide kernel messages
[ "$KOPT_quiet" = yes ] && dmesg -n 1

# optional blacklist
for i in ${KOPT_blacklist//,/ }; do
	echo "blacklist $i" >> /etc/modprobe.d/boot-opt-blacklist.conf
done

# determine if we are going to need networking
if [ -n "$KOPT_ip" ] || [ -n "$KOPT_nbd" ] || \
	is_url "$KOPT_apkovl" || is_url "$ALPINE_REPO"; then

	do_networking=true
else
	do_networking=false
fi

if [ -n "$KOPT_dasd" ]; then
	for mod in dasd_mod dasd_eckd_mod dasd_fba_mod; do
		modprobe $mod
	done
	for _dasd in $(echo "$KOPT_dasd" | tr ',' ' ' | tr [A-Z] [a-z]); do
		echo 1 > /sys/bus/ccw/devices/"${_dasd%%:*}"/online
	done
fi

if [ "${KOPT_s390x_net%%,*}" = "qeth_l2" ]; then
	for mod in qeth qeth_l2 qeth_l3; do
		modprobe $mod
	done
	_channel="$(echo ${KOPT_s390x_net#*,} | tr [A-Z] [a-z])"
	echo "$_channel" > /sys/bus/ccwgroup/drivers/qeth/group
	echo 1 > /sys/bus/ccwgroup/drivers/qeth/"${_channel%%,*}"/layer2
	echo 1 > /sys/bus/ccwgroup/drivers/qeth/"${_channel%%,*}"/online
fi

# make sure we load zfs module if root=ZFS=...
rootfstype=${KOPT_rootfstype}
if [ -z "$rootfstype" ]; then
	case "$KOPT_root" in
	ZFS=*) rootfstype=zfs ;;
	esac
fi

# load available drivers to get access to modloop media
ebegin "Loading boot drivers"

modprobe -a $(echo "$KOPT_modules $rootfstype" | tr ',' ' ' ) ahci sr_mod sd_mod loop squashfs cdrom isofs 2> /dev/kmsg
if [ -f /etc/modules ] ; then
	sed 's/\#.*//g' < /etc/modules |
	while read module args; do
		modprobe $module $args
	done
fi
eend 0

if [ -n "$KOPT_cryptroot" ]; then
	cryptopts="-c ${KOPT_cryptroot}"
	if [ "$KOPT_cryptdiscards" = "yes" ]; then
		cryptopts="$cryptopts -D"
	fi
	if [ -n "$KOPT_cryptdm" ]; then
		cryptopts="$cryptopts -m ${KOPT_cryptdm}"
	fi
	if [ -n "$KOPT_cryptheader" ]; then
		cryptopts="$cryptopts -H ${KOPT_cryptheader}"
	fi
	if [ -n "$KOPT_cryptoffset" ]; then
		cryptopts="$cryptopts -o ${KOPT_cryptoffset}"
	fi
	if [ "$KOPT_cryptkey" = "yes" ]; then
		cryptopts="$cryptopts -k /crypto_keyfile.bin"
	elif [ -n "$KOPT_cryptkey" ]; then
		cryptopts="$cryptopts -k ${KOPT_cryptkey}"
	fi
fi

# zpool reports /dev/zfs missing if it can't read /etc/mtab
ln -s /proc/mounts /etc/mtab

if [ "$SINGLEMODE" = "yes" ]; then
	echo "Entering single mode. Type 'exit' to continue booting."
	sh
fi

# find rootfs file

if [ -n "$KOPT_resume" ]; then
	echo "Resume from disk"
	if [ -e /sys/power/resume ]; then
		printf "%d:%d" $(stat -Lc "0x%t 0x%T" "$KOPT_resume") >/sys/power/resume
	else
		echo "resume: no hibernation support found"
	fi
fi

mkdir -p /media/cdrom /media/ramstore /media/root-ro /media/root-rw $sysroot/media/root-ro $sysroot/media/root-rw
mount -t tmpfs ramstore-tmpfs /media/ramstore

mount -o ro /dev/sr0 /media/cdrom
cp /media/cdrom/${KOPT_rootfsfile} /media/ramstore/rootfs.sqfs
umount /media/cdrom
mount -t squashfs -o loop,ro /media/ramstore/rootfs.sqfs /media/root-ro

mount -t tmpfs root-tmpfs /media/root-rw
mkdir -p /media/root-rw/work /media/root-rw/root
mount -t overlay -o lowerdir=/media/root-ro,upperdir=/media/root-rw/root,workdir=/media/root-rw/work overlayfs $sysroot

cat /proc/mounts | while read DEV DIR TYPE OPTS ; do
	if [ "$DIR" != "/" -a "$DIR" != "$sysroot" -a -d "$DIR" ]; then
		mkdir -p $sysroot/$DIR
		mount -o move $DIR $sysroot/$DIR
	fi
done

sync

exec /bin/busybox switch_root $sysroot $chart_init "$KOPT_init" $KOPT_init_args
[ -f /bin/plymouth ] && /bin/plymouth --ping && /bin/plymouth quit
echo "initramfs emergency recovery shell launched"
exec /bin/busybox sh

