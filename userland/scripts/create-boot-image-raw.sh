#!/bin/bash
#
# create-boot-image.sh — Create a bootable raw disk image for PureDarwin/QEMU
#
# Creates a raw disk image with HFS+ filesystem containing kernel + kexts + userland.
# Uses hdiutil to format as HFS+, then converts to raw for QEMU.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERLAND_DIR="$(dirname "$SCRIPT_DIR")"
PUREDARWIN_DIR="$(dirname "$USERLAND_DIR")"
BUILD_DIR="${PUREDARWIN_DIR}/build"

BOOT_DIR="${USERLAND_DIR}/boot"
RAW_IMAGE="${BOOT_DIR}/puredarwin.raw"
IMAGE_SIZE_MB=512
MOUNT_POINT="${BOOT_DIR}/mnt"

KERNEL="${BUILD_DIR}/src/Kernel/xnu/xnu/System/Library/Kernels/kernel"
KERNEL_SYM="${BUILD_DIR}/src/Kernel/xnu/xnu_sym/kernel"
KEXT_BUILD="${BUILD_DIR}/src/Kernel/Extensions"
ROOTFS="${USERLAND_DIR}/rootfs"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    if mount | grep -q "${MOUNT_POINT}" 2>/dev/null; then
        hdiutil detach "${MOUNT_POINT}" -force 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Verify prerequisites
[ -f "${KERNEL}" ] || error "Kernel not found at ${KERNEL}. Build PureDarwin first."
[ -d "${ROOTFS}/sbin" ] || error "Rootfs not found at ${ROOTFS}. Run build-userland.sh first."

mkdir -p "${BOOT_DIR}" "${MOUNT_POINT}"

#
# Step 1: Create a raw sparse image and attach it
#
info "Creating ${IMAGE_SIZE_MB}MB raw disk image"
rm -f "${RAW_IMAGE}"

# Create a sparse raw image file
dd if=/dev/zero of="${RAW_IMAGE}" bs=1m count=0 seek=${IMAGE_SIZE_MB} 2>/dev/null

# Attach as a disk device
info "Attaching disk image"
DEVICE=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "${RAW_IMAGE}" | awk 'NR==1{print $1}')
info "Attached as ${DEVICE}"

#
# Step 2: Partition with GPT and format as HFS+
#
info "Partitioning and formatting as HFS+"
diskutil partitionDisk "${DEVICE}" 1 GPT HFS+ PureDarwin 0b

# Find the partition
PARTITION=$(diskutil list "${DEVICE}" | grep "PureDarwin" | awk '{print $NF}')
if [ -z "${PARTITION}" ]; then
    # Fallback: use the first partition that's not EFI
    PARTITION=$(diskutil list "${DEVICE}" | grep "Apple_HFS" | awk '{print $NF}')
fi
info "HFS+ partition: ${PARTITION}"

#
# Step 3: Mount the partition
#
info "Mounting partition"
# Mount at our specific mount point
diskutil mount -mountPoint "${MOUNT_POINT}" "${PARTITION}" || {
    # Fallback: it may auto-mount at /Volumes/PureDarwin
    MOUNT_POINT="/Volumes/PureDarwin"
    info "Using auto-mount point: ${MOUNT_POINT}"
}

#
# Step 4: Create directory structure
#
info "Creating Darwin filesystem layout"
mkdir -p "${MOUNT_POINT}/System/Library/Kernels"
mkdir -p "${MOUNT_POINT}/System/Library/Extensions"
mkdir -p "${MOUNT_POINT}/System/Library/LaunchDaemons"
mkdir -p "${MOUNT_POINT}/usr/lib"
mkdir -p "${MOUNT_POINT}/usr/libexec"
mkdir -p "${MOUNT_POINT}/usr/bin"
mkdir -p "${MOUNT_POINT}/usr/sbin"
mkdir -p "${MOUNT_POINT}/usr/share/man"
mkdir -p "${MOUNT_POINT}/usr/include"
mkdir -p "${MOUNT_POINT}/usr/local/bin"
mkdir -p "${MOUNT_POINT}/bin"
mkdir -p "${MOUNT_POINT}/sbin"
mkdir -p "${MOUNT_POINT}/etc"
mkdir -p "${MOUNT_POINT}/var/log"
mkdir -p "${MOUNT_POINT}/var/run"
mkdir -p "${MOUNT_POINT}/var/tmp"
mkdir -p "${MOUNT_POINT}/var/db"
mkdir -p "${MOUNT_POINT}/var/empty"
mkdir -p "${MOUNT_POINT}/dev"
mkdir -p "${MOUNT_POINT}/tmp"
mkdir -p "${MOUNT_POINT}/root"
mkdir -p "${MOUNT_POINT}/private/var"
chmod 1777 "${MOUNT_POINT}/tmp" "${MOUNT_POINT}/var/tmp"

#
# Step 5: Install kernel
#
info "Installing kernel"
cp "${KERNEL}" "${MOUNT_POINT}/System/Library/Kernels/kernel"
cp "${KERNEL}" "${MOUNT_POINT}/mach_kernel"

#
# Step 6: Install kexts
#
info "Installing kernel extensions"
for kext_dir in "${KEXT_BUILD}"/*/*.kext "${KEXT_BUILD}"/*/*/*.kext; do
    if [ -d "$kext_dir" ]; then
        kext_name=$(basename "$kext_dir")
        info "  ${kext_name}"
        cp -R "$kext_dir" "${MOUNT_POINT}/System/Library/Extensions/${kext_name}"
    fi
done

# System.kext from XNU
if [ -d "${BUILD_DIR}/src/Kernel/xnu/xnu/System/Library/Extensions/System.kext" ]; then
    cp -R "${BUILD_DIR}/src/Kernel/xnu/xnu/System/Library/Extensions/System.kext" \
        "${MOUNT_POINT}/System/Library/Extensions/System.kext"
fi

#
# Step 7: Install userland
#
info "Installing userland"
cp -R "${ROOTFS}/"* "${MOUNT_POINT}/"

#
# Step 8: Create config files
#
cat > "${MOUNT_POINT}/etc/fstab" <<'EOF'
/dev/disk0s2  /  hfs  rw  1  1
EOF

#
# Step 9: Unmount and detach
#
info "Unmounting and detaching"
diskutil unmount "${PARTITION}" || diskutil unmount force "${PARTITION}"
hdiutil detach "${DEVICE}" -force

info ""
info "Boot image ready: ${RAW_IMAGE}"
info "Size: $(ls -lh "${RAW_IMAGE}" | awk '{print $5}')"
info ""
info "To boot: bash ${SCRIPT_DIR}/boot-qemu.sh"
