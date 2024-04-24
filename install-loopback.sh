#!/bin/bash

set -e
set -u

# You may want to use apt-cacher-ng proxy for debootstrap
#export http_proxy=http://127.0.0.1:3142
#export https_proxy=http://127.0.0.1:3142

if [ $# -ne 1 ]; then
        echo "Usage: $0 <board>"
        echo "Board can be one of:"
        ls -1 boards | grep -v '^common$' | sed -e 's/^/ /'
        exit 1
fi

BOARD=$1
LOOPBACK_FILE="${BOARD}.img"
LOOPBACK_SIZE=4G

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

truncate -s 0 "${LOOPBACK_FILE}"
fallocate -l "${LOOPBACK_SIZE}" "${LOOPBACK_FILE}"

DEVICE=$(losetup --show -f "${LOOPBACK_FILE}")
CLEANUP+=("losetup -d ${DEVICE}")

./install.sh "$1" "${DEVICE}"
