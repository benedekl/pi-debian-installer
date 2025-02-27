#!/bin/bash

set -e
set -u

TARGET_ARCH=armhf
: ${TARGET_DIST=buster}
: ${DEB_MIRROR=http://deb.debian.org/debian/}
: ${PACKAGES=e2fsprogs,vim,u-boot-tools,cpufrequtils,initramfs-tools,xfsprogs,ssh}
: ${USE_LVM=yes}
: ${USE_SWAP=yes}
: ${ROOT_SIZE=2048M}
: ${SWAP_SIZE=1024M}
: ${ROOTFS_TYPE=ext4}
: ${DISKLABEL_TYPE=dos}
: ${DISKLABEL_FIRST_LBA=2048}

DTB=

case "$ROOTFS_TYPE" in
	ext4)
		mkrootfs="mkfs.ext4 -F"
		;;
	xfs)
		mkrootfs="mkfs.xfs -f"
		;;
	*)
		echo "Root filesystem type '$ROOTFS_TYPE' not supported"
		exit 1
		;;
esac

CLEANUP=( )
cleanup() {
  set +e
  if [ ${#CLEANUP[*]} -gt 0 ]; then
    LAST_ELEMENT=$((${#CLEANUP[*]}-1))
    REVERSE_INDEXES=$(seq ${LAST_ELEMENT} -1 0)
    for i in $REVERSE_INDEXES; do
      ${CLEANUP[$i]}
    done
  fi
}
trap cleanup EXIT

get_uuid()
{
	blkid -o value -s UUID $1
}

set -e

if [ $# -ne 2 ]; then
	echo "Usage: $0 <board> <device>"
	echo "Board can be one of:"
	ls -1 boards | grep -v '^common$' | sed -e 's/^/ /'
	exit 1
fi

board="$1"
dev="$2"

. boards/common/install.sh

hook pre_partitioning

(
echo "label: $DISKLABEL_TYPE"
echo "first-lba: $DISKLABEL_FIRST_LBA"
if [ "$USE_LVM" = yes ]; then
	cat <<-EOF
	,256M,linux,*
	,,lvm,-
	EOF
else
	echo ",256M,linux,*"
	if [ "$USE_SWAP" = yes ]; then
		echo ",$SWAP_SIZE,swap,-"
	fi
	echo ",$ROOT_SIZE"
fi
) | flock $dev sfdisk -f -u S $dev

hook post_partitioning

sleep 1

_devices=($(lsblk -n -o name -p -r $dev))

bootdev=${_devices[1]}
swapdev=
if [ "$USE_LVM" = yes ]; then
	physdev=${_devices[2]}
	vgname="$board-$RANDOM"
	vgcreate -f "$vgname" "$physdev"
	CLEANUP+=("vgchange -a n $vgname")

	if [ "$USE_SWAP" = yes ]; then
		lvcreate --yes -W y -n swap -L $SWAP_SIZE $vgname
		swapdev="/dev/$vgname/swap"
	fi
	lvcreate --yes -W y -n root -L $ROOT_SIZE $vgname
	rootdev="/dev/$vgname/root"
	PACKAGES="$PACKAGES,lvm2"
else
	if [ "$USE_SWAP" = yes ]; then
		swapdev=${_devices[2]}
		rootdev=${_devices[3]}
	else
		rootdev=${_devices[2]}
	fi
fi

mkfs.ext3 -F $bootdev
tune2fs -o discard $bootdev
swapuuid=
if [ -n "$swapdev" ]; then
	mkswap -f $swapdev
	swapuuid=$(get_uuid $swapdev)
fi
$mkrootfs $rootdev

bootuuid=$(get_uuid $bootdev)
rootuuid=$(get_uuid $rootdev)

rootdir=$(mktemp -d)
CLEANUP+=("rmdir $rootdir")

mount $rootdev $rootdir
CLEANUP+=("umount $rootdir")
mkdir $rootdir/boot
mount -o nobarrier $bootdev $rootdir/boot
CLEANUP+=("umount $rootdir/boot")

export LC_ALL=C LANGUAGE=C LANG=C
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

tar cf - --owner=root:0 --group=root:0 -C boards/common/root . | tar xf - --no-same-permissions -C "$rootdir"
if [ -d "$BOARD_DIR/root" ]; then
	tar cf - --owner=root:0 --group=root:0 -C "$BOARD_DIR/root" . | tar xf - --no-same-permissions -C "$rootdir"
fi

# generate bootEnv.txt
echo "root=UUID=$rootuuid" > "$rootdir/boot/bootEnv.txt"

hook pre_debootstrap

debootstrap --components=main,contrib,non-free --arch $TARGET_ARCH $TARGET_DIST $rootdir $DEB_MIRROR

chroot $rootdir apt-get install -f -y ${PACKAGES//,/ }

# generate boot.scr
chroot $rootdir mkimage -T script -A arm -d /boot/boot.cmd /boot/boot.scr

hook post_debootstrap

hook install_kernel

# prepare dtb
mkdir -p $rootdir/boot/dtb
if [ -n "$DTB" ]; then
	cp $rootdir$DTB $rootdir/boot/dtb/
fi

echo "$board" > $rootdir/etc/hostname

cat <<EOF > $rootdir/etc/fstab
UUID=$bootuuid	/boot		ext3	rw		0	2
UUID=$rootuuid	/		$ROOTFS_TYPE	rw		0	1
EOF
if [ -n "$swapuuid" ]; then
	echo "UUID=$swapuuid	none		swap	sw			0	0" >> $rootdir/etc/fstab
fi

echo 'GOVERNOR="conservative"' > $rootdir/etc/default/cpufrequtils

echo "root:pi" | chroot $rootdir chpasswd

chroot $rootdir systemctl enable systemd-timesyncd

U_BOOT="$BOARD_DIR/u-boot-sunxi-with-spl.bin"
if [ -f "$U_BOOT" ]; then
	dd if="$U_BOOT" of=$dev bs=1k seek=8
fi
