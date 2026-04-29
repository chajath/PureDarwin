#!/bin/bash
#
# boot-qemu.sh — Boot PureDarwin in QEMU (x86_64 emulation on ARM64 host)
#
# Uses QEMU's -kernel flag for direct kernel boot (no bootloader needed).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERLAND_DIR="$(dirname "$SCRIPT_DIR")"
PUREDARWIN_DIR="$(dirname "$USERLAND_DIR")"
BUILD_DIR="${PUREDARWIN_DIR}/build"
BOOT_DIR="${USERLAND_DIR}/boot"

IMAGE_FILE="${BOOT_DIR}/puredarwin.raw"
KERNEL="${BUILD_DIR}/src/Kernel/xnu/xnu_sym/kernel"

# Use the unstripped kernel for direct boot (has symbols for debugging)
KERNEL_UNSTRIPPED="${BUILD_DIR}/src/Kernel/xnu/xnu_build/src/xnu-build/RELEASE_X86_64/kernel.unstripped"
if [ -f "${KERNEL_UNSTRIPPED}" ]; then
    BOOT_KERNEL="${KERNEL_UNSTRIPPED}"
else
    BOOT_KERNEL="${KERNEL}"
fi

MEMORY="1024"
CPUS="2"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "${BOOT_KERNEL}" ] || error "Kernel not found: ${BOOT_KERNEL}"
[ -f "${IMAGE_FILE}" ]  || error "Disk image not found: ${IMAGE_FILE}. Run create-boot-image-raw.sh first."

info "Booting PureDarwin in QEMU"
info "  Kernel: ${BOOT_KERNEL}"
info "  Image:  ${IMAGE_FILE}"
info "  Memory: ${MEMORY}MB, CPUs: ${CPUS}"
info ""
info "NOTE: Running x86_64 emulation on ARM64 (TCG) — expect slow performance."
info "Press Ctrl+A then X to exit QEMU."
info ""

exec qemu-system-x86_64 \
    -m "${MEMORY}" \
    -smp "${CPUS}" \
    -cpu Penryn \
    -machine q35 \
    -kernel "${BOOT_KERNEL}" \
    -append "debug=0x144 -v rd=disk0s2 serial=1" \
    -drive file="${IMAGE_FILE}",format=raw,media=disk \
    -serial mon:stdio \
    -nographic \
    -usb \
    -device usb-kbd \
    -netdev user,id=net0 \
    -device e1000,netdev=net0
