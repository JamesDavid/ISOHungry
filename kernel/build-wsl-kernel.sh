#!/bin/bash
# Builds a WSL2 kernel with optical-drive support, inside a container.
# Runs against Microsoft's own WSL2 kernel source + their config-wsl, so the
# result is the stock WSL2 kernel plus exactly three extra symbols.
#
#   CONFIG_BLK_DEV_SR   -> /dev/sr* SCSI CD-ROM block devices  (selects CDROM)
#   CONFIG_USB_STORAGE  -> USB mass-storage bulk-only transport
#   CONFIG_USB_UAS      -> UAS transport, used by some USB enclosures
#
# Everything else the ripper needs (SCSI core, sg, ISO9660, UDF, usbip vhci)
# is already enabled in the stock config.
set -euo pipefail

KERNEL_TAG="${KERNEL_TAG:-linux-msft-wsl-5.15.133.1}"
OUT_DIR="${OUT_DIR:-/out}"

echo "==> Installing build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential flex bison libssl-dev libelf-dev bc dwarves \
    python3 cpio kmod git ca-certificates rsync xz-utils >/dev/null

echo "==> Cloning WSL2-Linux-Kernel @ ${KERNEL_TAG}"
git clone --depth 1 --branch "$KERNEL_TAG" \
    https://github.com/microsoft/WSL2-Linux-Kernel.git /usr/src/wsl-kernel
cd /usr/src/wsl-kernel

echo "==> Applying config"
cp Microsoft/config-wsl .config
./scripts/config \
    --enable CONFIG_BLK_DEV_SR \
    --enable CONFIG_USB_STORAGE \
    --enable CONFIG_USB_UAS
make olddefconfig

# Fail loudly now rather than after a 20-minute build.
echo "==> Verifying config took"
for sym in CONFIG_BLK_DEV_SR CONFIG_CDROM CONFIG_USB_STORAGE CONFIG_ISO9660_FS CONFIG_UDF_FS CONFIG_USBIP_VHCI_HCD; do
    if grep -q "^${sym}=y" .config; then
        echo "    ok  ${sym}=y"
    else
        echo "    FAIL ${sym} not enabled" >&2
        exit 1
    fi
done

echo "==> Building (nproc=$(nproc)); this takes a while"
make -j"$(nproc)" bzImage

echo "==> Exporting to ${OUT_DIR}"
mkdir -p "$OUT_DIR"
cp arch/x86/boot/bzImage "$OUT_DIR/bzImage"
cp .config "$OUT_DIR/kernel-config"
echo "$KERNEL_TAG" > "$OUT_DIR/kernel-version.txt"
ls -la "$OUT_DIR"
echo "==> Done"
