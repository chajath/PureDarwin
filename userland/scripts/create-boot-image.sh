#!/bin/bash
#
# create-boot-image.sh — Create a bootable HFS+ disk image for PureDarwin
#
# Assembles kernel + kexts + userland rootfs into a QEMU-bootable image.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERLAND_DIR="$(dirname "$SCRIPT_DIR")"
PUREDARWIN_DIR="$(dirname "$USERLAND_DIR")"
BUILD_DIR="${PUREDARWIN_DIR}/build"

BOOT_DIR="${USERLAND_DIR}/boot"
IMAGE_FILE="${BOOT_DIR}/puredarwin.img"
IMAGE_SIZE="512m"
MOUNT_POINT="${BOOT_DIR}/mnt"

KERNEL="${BUILD_DIR}/src/Kernel/xnu/xnu/System/Library/Kernels/kernel"
KERNEL_SYM="${BUILD_DIR}/src/Kernel/xnu/xnu_sym/kernel"
KEXT_BUILD="${BUILD_DIR}/src/Kernel/Extensions"
ROOTFS="${USERLAND_DIR}/rootfs"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    if mount | grep -q "${MOUNT_POINT}"; then
        hdiutil detach "${MOUNT_POINT}" -force 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Verify prerequisites
[ -f "${KERNEL}" ] || error "Kernel not found at ${KERNEL}. Build PureDarwin first."
[ -d "${ROOTFS}/sbin" ] || error "Rootfs not found at ${ROOTFS}. Run build-userland.sh first."

mkdir -p "${BOOT_DIR}" "${MOUNT_POINT}"

#
# Step 1: Create HFS+ disk image
#
info "Creating ${IMAGE_SIZE} HFS+ disk image"
if [ -f "${IMAGE_FILE}" ]; then
    rm -f "${IMAGE_FILE}"
fi

hdiutil create -size "${IMAGE_SIZE}" -fs HFS+ -volname PureDarwin \
    -type UDIF "${BOOT_DIR}/puredarwin" -layout GPTSPUD

# hdiutil appends .dmg
IMAGE_FILE="${BOOT_DIR}/puredarwin.dmg"

#
# Step 2: Mount the image
#
info "Mounting disk image"
ATTACH_OUTPUT=$(hdiutil attach "${IMAGE_FILE}" -mountpoint "${MOUNT_POINT}" -nobrowse)
DEVICE=$(echo "${ATTACH_OUTPUT}" | grep -o '/dev/disk[0-9]*' | head -1)
info "Mounted on ${DEVICE} at ${MOUNT_POINT}"

#
# Step 3: Create directory structure
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
# Step 4: Install kernel
#
info "Installing kernel"
cp "${KERNEL}" "${MOUNT_POINT}/System/Library/Kernels/kernel"
# Also install as mach_kernel for legacy boot compat
cp "${KERNEL}" "${MOUNT_POINT}/mach_kernel"

#
# Step 5: Install kexts
#
info "Installing kernel extensions"
for kext_dir in "${KEXT_BUILD}"/*/*.kext "${KEXT_BUILD}"/*/*/*.kext; do
    if [ -d "$kext_dir" ]; then
        kext_name=$(basename "$kext_dir")
        info "  Installing ${kext_name}"
        cp -R "$kext_dir" "${MOUNT_POINT}/System/Library/Extensions/${kext_name}"
    fi
done

# Also install System.kext from XNU build
if [ -d "${BUILD_DIR}/src/Kernel/xnu/xnu/System/Library/Extensions/System.kext" ]; then
    cp -R "${BUILD_DIR}/src/Kernel/xnu/xnu/System/Library/Extensions/System.kext" \
        "${MOUNT_POINT}/System/Library/Extensions/System.kext"
fi

#
# Step 6: Install userland
#
info "Installing userland from rootfs"
# Copy everything from our rootfs
cp -R "${ROOTFS}/"* "${MOUNT_POINT}/"

#
# Step 7: Create essential device nodes and symlinks
#
info "Setting up filesystem links"
# /etc -> /private/etc is not needed for minimal boot, we use /etc directly
# But create the /private structure macOS expects
ln -sf /var "${MOUNT_POINT}/private/var" 2>/dev/null || true

#
# Step 8: Create boot configuration
#
cat > "${MOUNT_POINT}/etc/fstab" <<'EOF'
# PureDarwin fstab
# <device>    <mount>    <type>    <options>    <dump>    <pass>
/dev/disk0s1  /          hfs       rw           1         1
EOF

#
# Step 9: Unmount
#
info "Unmounting disk image"
hdiutil detach "${MOUNT_POINT}" -force

info "Boot image created: ${IMAGE_FILE}"
info ""
info "Image contents:"
info "  Kernel:     /System/Library/Kernels/kernel"
info "  Kexts:      /System/Library/Extensions/*.kext"
info "  Init:       /sbin/init (pd_init)"
info "  Shell:      /bin/mksh -> /bin/sh"
info ""
info "To boot with QEMU, run:"
info "  bash ${SCRIPT_DIR}/boot-qemu.sh"
