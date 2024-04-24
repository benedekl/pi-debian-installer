# shell fragment

TARGET_ARCH=arm64
TARGET_DIST=bookworm
DISKLABEL_TYPE=gpt
DISKLABEL_FIRST_LBA=32768
PACKAGES="${PACKAGES},linux-image-${TARGET_ARCH}"
USE_SWAP=no

post_partitioning()
{
	dd if=idbloader.img of=$dev seek=64
	dd if=u-boot.itb of=$dev seek=16384
}

install_kernel()
{
	:
}
