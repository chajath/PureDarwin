#!/bin/bash
#
# setup-opencore-boot.sh — Create a UEFI-bootable PureDarwin disk for QEMU
#
# Creates a raw disk image with:
#   - 200MB EFI System Partition (FAT32) containing OpenCore
#   - ~300MB HFS+ partition containing kernel + kexts + userland
#
# Then boots it with QEMU using OVMF (EDK2) UEFI firmware.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERLAND_DIR="$(dirname "$SCRIPT_DIR")"
PUREDARWIN_DIR="$(dirname "$USERLAND_DIR")"
BUILD_DIR="${PUREDARWIN_DIR}/build"
BOOT_DIR="${USERLAND_DIR}/boot"

KERNEL="${BUILD_DIR}/src/Kernel/xnu/xnu/System/Library/Kernels/kernel"
KEXT_BUILD="${BUILD_DIR}/src/Kernel/Extensions"
ROOTFS="${USERLAND_DIR}/rootfs"
OC_DIR="${BOOT_DIR}/OpenCore/X64"

OVMF_CODE="/opt/homebrew/Cellar/qemu/11.0.0/share/qemu/edk2-x86_64-code.fd"
OVMF_VARS_TEMPLATE="/opt/homebrew/Cellar/qemu/11.0.0/share/qemu/edk2-i386-vars.fd"
OVMF_VARS="${BOOT_DIR}/ovmf-vars.fd"

RAW_IMAGE="${BOOT_DIR}/puredarwin-uefi.raw"
IMAGE_SIZE_MB=512

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -n "${DEVICE:-}" ]; then
        diskutil unmountDisk "${DEVICE}" 2>/dev/null || true
        hdiutil detach "${DEVICE}" -force 2>/dev/null || true
    fi
}
trap cleanup EXIT

[ -f "${KERNEL}" ]       || error "Kernel not found. Build PureDarwin first."
[ -d "${OC_DIR}" ]       || error "OpenCore not found. Download it first."
[ -f "${OVMF_CODE}" ]    || error "OVMF firmware not found at ${OVMF_CODE}"
[ -d "${ROOTFS}/sbin" ]  || error "Rootfs not found. Run build-userland.sh first."

mkdir -p "${BOOT_DIR}"

# ─────────────────────────────────────────────────────────────
# Step 1: Create raw disk image
# ─────────────────────────────────────────────────────────────
info "Creating ${IMAGE_SIZE_MB}MB raw disk image"
rm -f "${RAW_IMAGE}"
dd if=/dev/zero of="${RAW_IMAGE}" bs=1m count=0 seek=${IMAGE_SIZE_MB} 2>/dev/null

info "Attaching disk image"
DEVICE=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "${RAW_IMAGE}" | awk 'NR==1{print $1}')
info "Attached as ${DEVICE}"

# ─────────────────────────────────────────────────────────────
# Step 2: Partition: 200MB EFI (FAT32) + rest HFS+
# ─────────────────────────────────────────────────────────────
info "Creating GPT partition table (EFI + HFS+)"
diskutil partitionDisk "${DEVICE}" 2 GPT \
    FAT32 EFI 200m \
    HFS+ PureDarwin 0b

# Find partitions
EFI_PART=$(diskutil list "${DEVICE}" | grep "EFI" | grep -v "EFI$" | awk '{print $NF}' | head -1)
HFS_PART=$(diskutil list "${DEVICE}" | grep "Apple_HFS" | awk '{print $NF}' | head -1)

# If the FAT32 partition shows as "Microsoft Basic Data" or similar
if [ -z "$EFI_PART" ]; then
    EFI_PART=$(diskutil list "${DEVICE}" | grep -i "fat\|Microsoft" | awk '{print $NF}' | head -1)
fi

info "EFI partition: ${EFI_PART}"
info "HFS+ partition: ${HFS_PART}"

# ─────────────────────────────────────────────────────────────
# Step 3: Mount EFI and install OpenCore
# ─────────────────────────────────────────────────────────────
EFI_MNT="${BOOT_DIR}/mnt_efi"
HFS_MNT="${BOOT_DIR}/mnt_hfs"
mkdir -p "${EFI_MNT}" "${HFS_MNT}"

info "Mounting EFI partition"
# diskutil may ignore -mountPoint for FAT32, so detect actual mount
diskutil mount "${EFI_PART}" 2>/dev/null || true
EFI_MNT=$(diskutil info "${EFI_PART}" | grep "Mount Point" | sed 's/.*: *//')
if [ -z "${EFI_MNT}" ]; then
    error "Failed to mount EFI partition"
fi
info "EFI mounted at: ${EFI_MNT}"

info "Installing OpenCore to EFI partition"
mkdir -p "${EFI_MNT}/EFI/BOOT"
mkdir -p "${EFI_MNT}/EFI/OC/Drivers"
mkdir -p "${EFI_MNT}/EFI/OC/Kexts"
mkdir -p "${EFI_MNT}/EFI/OC/ACPI"
mkdir -p "${EFI_MNT}/EFI/OC/Tools"
mkdir -p "${EFI_MNT}/EFI/OC/Resources"

# Copy bootloader
cp "${OC_DIR}/EFI/BOOT/BOOTx64.efi" "${EFI_MNT}/EFI/BOOT/BOOTx64.efi"
cp "${OC_DIR}/EFI/OC/OpenCore.efi"  "${EFI_MNT}/EFI/OC/OpenCore.efi"

# Copy essential drivers
cp "${OC_DIR}/EFI/OC/Drivers/OpenRuntime.efi"  "${EFI_MNT}/EFI/OC/Drivers/"
cp "${OC_DIR}/EFI/OC/Drivers/OpenHfsPlus.efi"  "${EFI_MNT}/EFI/OC/Drivers/"

# Create minimal OpenCore config.plist for PureDarwin
info "Creating OpenCore config.plist"
cat > "${EFI_MNT}/EFI/OC/config.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- ACPI -->
    <key>ACPI</key>
    <dict>
        <key>Add</key>
        <array/>
        <key>Delete</key>
        <array/>
        <key>Patch</key>
        <array/>
        <key>Quirks</key>
        <dict>
            <key>FadtEnableReset</key>
            <false/>
            <key>NormalizeHeaders</key>
            <false/>
            <key>RebaseRegions</key>
            <false/>
            <key>ResetHwSig</key>
            <false/>
            <key>ResetLogoStatus</key>
            <false/>
            <key>SyncTableIds</key>
            <false/>
        </dict>
    </dict>

    <!-- Booter -->
    <key>Booter</key>
    <dict>
        <key>MmioWhitelist</key>
        <array/>
        <key>Patch</key>
        <array/>
        <key>Quirks</key>
        <dict>
            <key>AllowRelocationBlock</key>
            <false/>
            <key>AvoidRuntimeDefrag</key>
            <true/>
            <key>DevirtualiseMmio</key>
            <false/>
            <key>DisableSingleUser</key>
            <false/>
            <key>DisableVariableWrite</key>
            <false/>
            <key>DiscardHibernateMap</key>
            <false/>
            <key>EnableSafeModeSlide</key>
            <false/>
            <key>EnableWriteUnprotector</key>
            <true/>
            <key>ForceBooterSignature</key>
            <false/>
            <key>ForceExitBootServices</key>
            <false/>
            <key>ProtectMemoryRegions</key>
            <false/>
            <key>ProtectSecureBoot</key>
            <false/>
            <key>ProtectUefiServices</key>
            <false/>
            <key>ProvideCustomSlide</key>
            <false/>
            <key>ProvideMaxSlide</key>
            <integer>0</integer>
            <key>RebuildAppleMemoryMap</key>
            <false/>
            <key>ResizeAppleGpuBars</key>
            <integer>-1</integer>
            <key>SetupVirtualMap</key>
            <true/>
            <key>SignalAppleOS</key>
            <false/>
            <key>SyncRuntimePermissions</key>
            <false/>
        </dict>
    </dict>

    <!-- DeviceProperties -->
    <key>DeviceProperties</key>
    <dict>
        <key>Add</key>
        <dict/>
        <key>Delete</key>
        <dict/>
    </dict>

    <!-- Kernel -->
    <key>Kernel</key>
    <dict>
        <key>Add</key>
        <array/>
        <key>Block</key>
        <array/>
        <key>Emulate</key>
        <dict>
            <key>Cpuid1Data</key>
            <data/>
            <key>Cpuid1Mask</key>
            <data/>
            <key>DummyPowerManagement</key>
            <true/>
            <key>MaxKernel</key>
            <string/>
            <key>MinKernel</key>
            <string/>
        </dict>
        <key>Force</key>
        <array/>
        <key>Patch</key>
        <array/>
        <key>Quirks</key>
        <dict>
            <key>AppleCpuPmCfgLock</key>
            <false/>
            <key>AppleXcpmCfgLock</key>
            <false/>
            <key>AppleXcpmExtraMsrs</key>
            <false/>
            <key>AppleXcpmForceBoost</key>
            <false/>
            <key>CustomSMBIOSGuid</key>
            <false/>
            <key>DisableIoMapper</key>
            <false/>
            <key>DisableLinkeditJettison</key>
            <false/>
            <key>DisableRtcChecksum</key>
            <false/>
            <key>ExtendBTFeatureFlags</key>
            <false/>
            <key>ExternalDiskIcons</key>
            <false/>
            <key>ForceAquantiaEthernet</key>
            <false/>
            <key>ForceSecureBootScheme</key>
            <false/>
            <key>IncreasePciBarSize</key>
            <false/>
            <key>LapicKernelPanic</key>
            <false/>
            <key>LegacyCommpage</key>
            <false/>
            <key>PanicNoKextDump</key>
            <true/>
            <key>PowerTimeoutKernelPanic</key>
            <true/>
            <key>ProvideCurrentCpuInfo</key>
            <true/>
            <key>SetApfsTrimTimeout</key>
            <integer>-1</integer>
            <key>ThirdPartyDrives</key>
            <false/>
            <key>XhciPortLimit</key>
            <false/>
        </dict>
        <key>Scheme</key>
        <dict>
            <key>CustomKernel</key>
            <false/>
            <key>FuzzyMatch</key>
            <true/>
            <key>KernelArch</key>
            <string>x86_64</string>
            <key>KernelCache</key>
            <string>Auto</string>
        </dict>
    </dict>

    <!-- Misc -->
    <key>Misc</key>
    <dict>
        <key>BlessOverride</key>
        <array>
            <string>\System\Library\CoreServices\boot.efi</string>
        </array>
        <key>Boot</key>
        <dict>
            <key>ConsoleAttributes</key>
            <integer>0</integer>
            <key>HibernateMode</key>
            <string>None</string>
            <key>HibernateSkipsPicker</key>
            <false/>
            <key>HideAuxiliary</key>
            <false/>
            <key>LauncherOption</key>
            <string>Disabled</string>
            <key>LauncherPath</key>
            <string>Default</string>
            <key>PickerAttributes</key>
            <integer>0</integer>
            <key>PickerAudioAssist</key>
            <false/>
            <key>PickerMode</key>
            <string>Builtin</string>
            <key>PickerVariant</key>
            <string>Auto</string>
            <key>PollAppleHotKeys</key>
            <false/>
            <key>ShowPicker</key>
            <true/>
            <key>TakeoffDelay</key>
            <integer>0</integer>
            <key>Timeout</key>
            <integer>3</integer>
        </dict>
        <key>Debug</key>
        <dict>
            <key>AppleDebug</key>
            <true/>
            <key>ApplePanic</key>
            <true/>
            <key>DisableWatchDog</key>
            <true/>
            <key>DisplayDelay</key>
            <integer>0</integer>
            <key>DisplayLevel</key>
            <integer>2147483714</integer>
            <key>LogModules</key>
            <string>*</string>
            <key>SysReport</key>
            <false/>
            <key>Target</key>
            <integer>67</integer>
        </dict>
        <key>Entries</key>
        <array/>
        <key>Security</key>
        <dict>
            <key>AllowSetDefault</key>
            <true/>
            <key>ApECID</key>
            <integer>0</integer>
            <key>AuthRestart</key>
            <false/>
            <key>BlacklistAppleUpdate</key>
            <false/>
            <key>DmgLoading</key>
            <string>Signed</string>
            <key>EnablePassword</key>
            <false/>
            <key>ExposeSensitiveData</key>
            <integer>6</integer>
            <key>HaltLevel</key>
            <integer>2147483648</integer>
            <key>PasswordHash</key>
            <data/>
            <key>PasswordSalt</key>
            <data/>
            <key>ScanPolicy</key>
            <integer>0</integer>
            <key>SecureBootModel</key>
            <string>Disabled</string>
            <key>Vault</key>
            <string>Optional</string>
        </dict>
        <key>Tools</key>
        <array/>
    </dict>

    <!-- NVRAM -->
    <key>NVRAM</key>
    <dict>
        <key>Add</key>
        <dict>
            <key>4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14</key>
            <dict>
                <key>DefaultBackgroundColor</key>
                <data>AAAAAA==</data>
                <key>UIScale</key>
                <data>AQ==</data>
            </dict>
            <key>7C436110-AB2A-4BBB-A880-FE41995C9F82</key>
            <dict>
                <key>boot-args</key>
                <string>-v debug=0x144 keepsyms=1 serial=1</string>
                <key>csr-active-config</key>
                <data>/w8AAA==</data>
                <key>prev-lang:kbd</key>
                <data>ZW4tVVM6MA==</data>
                <key>run-efi-updater</key>
                <string>No</string>
            </dict>
        </dict>
        <key>Delete</key>
        <dict>
            <key>4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14</key>
            <array>
                <string>UIScale</string>
                <string>DefaultBackgroundColor</string>
            </array>
            <key>7C436110-AB2A-4BBB-A880-FE41995C9F82</key>
            <array>
                <string>boot-args</string>
            </array>
        </dict>
        <key>LegacySchema</key>
        <dict/>
        <key>WriteFlash</key>
        <false/>
    </dict>

    <!-- PlatformInfo - minimal for PureDarwin -->
    <key>PlatformInfo</key>
    <dict>
        <key>Automatic</key>
        <true/>
        <key>CustomMemory</key>
        <false/>
        <key>Generic</key>
        <dict>
            <key>AdviseFeatures</key>
            <false/>
            <key>MLB</key>
            <string>XXXXXXXXXXXXXXXXX</string>
            <key>MaxBIOSVersion</key>
            <false/>
            <key>ProcessorType</key>
            <integer>0</integer>
            <key>ROM</key>
            <data>ERERERERERE=</data>
            <key>SpoofVendor</key>
            <false/>
            <key>SystemMemoryStatus</key>
            <string>Auto</string>
            <key>SystemProductName</key>
            <string>iMac19,1</string>
            <key>SystemSerialNumber</key>
            <string>XXXXXXXXXXXX</string>
            <key>SystemUUID</key>
            <string>00000000-0000-0000-0000-000000000000</string>
        </dict>
        <key>UpdateDataHub</key>
        <true/>
        <key>UpdateNVRAM</key>
        <true/>
        <key>UpdateSMBIOS</key>
        <true/>
        <key>UpdateSMBIOSMode</key>
        <string>Create</string>
        <key>UseRawUuidEncoding</key>
        <false/>
    </dict>

    <!-- UEFI -->
    <key>UEFI</key>
    <dict>
        <key>APFS</key>
        <dict>
            <key>EnableJumpstart</key>
            <false/>
            <key>GlobalConnect</key>
            <false/>
            <key>HideVerbose</key>
            <false/>
            <key>JumpstartHotPlug</key>
            <false/>
            <key>MinDate</key>
            <integer>-1</integer>
            <key>MinVersion</key>
            <integer>-1</integer>
        </dict>
        <key>Audio</key>
        <dict>
            <key>AudioCodec</key>
            <integer>0</integer>
            <key>AudioDevice</key>
            <string/>
            <key>AudioOutMask</key>
            <integer>-1</integer>
            <key>AudioSupport</key>
            <false/>
            <key>DisconnectHda</key>
            <false/>
            <key>MaximumGain</key>
            <integer>-15</integer>
            <key>MinimumAssistGain</key>
            <integer>-30</integer>
            <key>MinimumAudibleGain</key>
            <integer>-55</integer>
            <key>PlayChime</key>
            <string>Disabled</string>
            <key>ResetTrafficClass</key>
            <false/>
            <key>SetupDelay</key>
            <integer>0</integer>
        </dict>
        <key>ConnectDrivers</key>
        <true/>
        <key>Drivers</key>
        <array>
            <dict>
                <key>Arguments</key>
                <string/>
                <key>Comment</key>
                <string/>
                <key>Enabled</key>
                <true/>
                <key>LoadEarly</key>
                <false/>
                <key>Path</key>
                <string>OpenRuntime.efi</string>
            </dict>
            <dict>
                <key>Arguments</key>
                <string/>
                <key>Comment</key>
                <string/>
                <key>Enabled</key>
                <true/>
                <key>LoadEarly</key>
                <false/>
                <key>Path</key>
                <string>OpenHfsPlus.efi</string>
            </dict>
        </array>
        <key>Input</key>
        <dict>
            <key>KeyFiltering</key>
            <false/>
            <key>KeyForgetThreshold</key>
            <integer>5</integer>
            <key>KeySupport</key>
            <true/>
            <key>KeySupportMode</key>
            <string>Auto</string>
            <key>KeySwap</key>
            <false/>
            <key>PointerSupport</key>
            <false/>
            <key>PointerSupportMode</key>
            <string/>
            <key>TimerResolution</key>
            <integer>50000</integer>
        </dict>
        <key>Output</key>
        <dict>
            <key>ClearScreenOnModeSwitch</key>
            <false/>
            <key>ConsoleMode</key>
            <string/>
            <key>DirectGopRendering</key>
            <false/>
            <key>ForceResolution</key>
            <false/>
            <key>GopPassThrough</key>
            <string>Disabled</string>
            <key>IgnoreTextInGraphics</key>
            <false/>
            <key>InitialMode</key>
            <string>Auto</string>
            <key>ProvideConsoleGop</key>
            <true/>
            <key>ReconnectGraphicsOnConnect</key>
            <false/>
            <key>ReconnectOnResChange</key>
            <false/>
            <key>ReplaceTabWithSpace</key>
            <false/>
            <key>Resolution</key>
            <string>Max</string>
            <key>SanitiseClearScreen</key>
            <false/>
            <key>TextRenderer</key>
            <string>BuiltinGraphics</string>
            <key>UIScale</key>
            <integer>-1</integer>
            <key>UgaPassThrough</key>
            <false/>
        </dict>
        <key>ProtocolOverrides</key>
        <dict>
            <key>AppleAudio</key>
            <false/>
            <key>AppleBootPolicy</key>
            <false/>
            <key>AppleDebugLog</key>
            <false/>
            <key>AppleEg2Info</key>
            <false/>
            <key>AppleFramebufferInfo</key>
            <false/>
            <key>AppleImageConversion</key>
            <false/>
            <key>AppleImg4Verification</key>
            <false/>
            <key>AppleKeyMap</key>
            <false/>
            <key>AppleRtcRam</key>
            <false/>
            <key>AppleSecureBoot</key>
            <false/>
            <key>AppleSmcIo</key>
            <false/>
            <key>AppleUserInterfaceTheme</key>
            <false/>
            <key>DataHub</key>
            <false/>
            <key>DeviceProperties</key>
            <false/>
            <key>FirmwareVolume</key>
            <false/>
            <key>HashServices</key>
            <false/>
            <key>OSInfo</key>
            <false/>
            <key>PciIo</key>
            <false/>
            <key>UnicodeCollation</key>
            <false/>
        </dict>
        <key>Quirks</key>
        <dict>
            <key>ActivateHpetSupport</key>
            <false/>
            <key>DisableSecurityPolicy</key>
            <false/>
            <key>EnableVectorAcceleration</key>
            <false/>
            <key>EnableVmx</key>
            <false/>
            <key>ExitBootServicesDelay</key>
            <integer>0</integer>
            <key>ForceOcWriteFlash</key>
            <false/>
            <key>ForgeUefiSupport</key>
            <false/>
            <key>IgnoreInvalidFlexRatio</key>
            <false/>
            <key>ReleaseUsbOwnership</key>
            <false/>
            <key>ReloadOptionRoms</key>
            <false/>
            <key>RequestBootVarRouting</key>
            <true/>
            <key>ResizeGpuBars</key>
            <integer>-1</integer>
            <key>ResizeUsePciRbIo</key>
            <false/>
            <key>ShimRetainProtocol</key>
            <false/>
            <key>TscSyncTimeout</key>
            <integer>0</integer>
            <key>UnblockFsConnect</key>
            <false/>
        </dict>
        <key>ReservedMemory</key>
        <array/>
    </dict>
</dict>
</plist>
PLIST

# ─────────────────────────────────────────────────────────────
# Step 4: Mount HFS+ and install kernel + userland
# ─────────────────────────────────────────────────────────────
info "Mounting HFS+ partition"
diskutil mount "${HFS_PART}" 2>/dev/null || true
HFS_MNT=$(diskutil info "${HFS_PART}" | grep "Mount Point" | sed 's/.*: *//')
if [ -z "${HFS_MNT}" ]; then
    error "Failed to mount HFS+ partition"
fi
info "HFS+ mounted at: ${HFS_MNT}"

info "Creating Darwin filesystem layout"
mkdir -p "${HFS_MNT}/System/Library/Kernels"
mkdir -p "${HFS_MNT}/System/Library/Extensions"
mkdir -p "${HFS_MNT}/System/Library/LaunchDaemons"
mkdir -p "${HFS_MNT}/usr/lib"
mkdir -p "${HFS_MNT}/usr/libexec"
mkdir -p "${HFS_MNT}/usr/bin"
mkdir -p "${HFS_MNT}/usr/sbin"
mkdir -p "${HFS_MNT}/usr/share/man"
mkdir -p "${HFS_MNT}/usr/include"
mkdir -p "${HFS_MNT}/usr/local/bin"
mkdir -p "${HFS_MNT}/bin"
mkdir -p "${HFS_MNT}/sbin"
mkdir -p "${HFS_MNT}/etc"
mkdir -p "${HFS_MNT}/var/log"
mkdir -p "${HFS_MNT}/var/run"
mkdir -p "${HFS_MNT}/var/tmp"
mkdir -p "${HFS_MNT}/var/db"
mkdir -p "${HFS_MNT}/var/empty"
mkdir -p "${HFS_MNT}/dev"
mkdir -p "${HFS_MNT}/tmp"
mkdir -p "${HFS_MNT}/root"
mkdir -p "${HFS_MNT}/private/var"
chmod 1777 "${HFS_MNT}/tmp" "${HFS_MNT}/var/tmp"

info "Installing kernel"
cp "${KERNEL}" "${HFS_MNT}/System/Library/Kernels/kernel"
cp "${KERNEL}" "${HFS_MNT}/mach_kernel"

# Create CoreServices markers so OpenCore detects this as a macOS/Darwin volume
info "Creating CoreServices boot markers"
mkdir -p "${HFS_MNT}/System/Library/CoreServices"
cat > "${HFS_MNT}/System/Library/CoreServices/SystemVersion.plist" << 'SVPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ProductBuildVersion</key>
    <string>17G14033</string>
    <key>ProductCopyright</key>
    <string>PureDarwin Project</string>
    <key>ProductName</key>
    <string>PureDarwin</string>
    <key>ProductUserVisibleVersion</key>
    <string>10.13.6</string>
    <key>ProductVersion</key>
    <string>10.13.6</string>
</dict>
</plist>
SVPLIST

cat > "${HFS_MNT}/System/Library/CoreServices/PlatformSupport.plist" << 'PSPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>SupportedBoardIds</key>
    <array>
        <string>Mac-AA95B1DDAB278B95</string>
    </array>
    <key>SupportedModelProperties</key>
    <array>
        <string>iMac19,1</string>
    </array>
</dict>
</plist>
PSPLIST

# Copy real boot.efi from host system (x86_64 EFI application that loads XNU)
if [ -f /usr/standalone/i386/boot.efi ]; then
    cp /usr/standalone/i386/boot.efi "${HFS_MNT}/System/Library/CoreServices/boot.efi"
    info "Installed boot.efi from /usr/standalone/i386/boot.efi"
elif [ -f /System/Library/CoreServices/boot.efi ]; then
    cp /System/Library/CoreServices/boot.efi "${HFS_MNT}/System/Library/CoreServices/boot.efi"
    info "Installed boot.efi from /System/Library/CoreServices/boot.efi"
else
    error "No boot.efi found on host system"
fi

info "Installing kernel extensions"
for kext_dir in "${KEXT_BUILD}"/*/*.kext "${KEXT_BUILD}"/*/*/*.kext; do
    [ -d "$kext_dir" ] || continue
    kext_name=$(basename "$kext_dir")
    info "  ${kext_name}"
    cp -R "$kext_dir" "${HFS_MNT}/System/Library/Extensions/${kext_name}"
done

if [ -d "${BUILD_DIR}/src/Kernel/xnu/xnu/System/Library/Extensions/System.kext" ]; then
    cp -R "${BUILD_DIR}/src/Kernel/xnu/xnu/System/Library/Extensions/System.kext" \
        "${HFS_MNT}/System/Library/Extensions/System.kext"
fi

info "Installing userland"
cp -R "${ROOTFS}/"* "${HFS_MNT}/"

cat > "${HFS_MNT}/etc/fstab" <<'EOF'
/dev/disk0s2  /  hfs  rw  1  1
EOF

# ─────────────────────────────────────────────────────────────
# Step 5: Unmount and prepare NVRAM vars
# ─────────────────────────────────────────────────────────────
info "Unmounting partitions"
diskutil unmount "${EFI_PART}" 2>/dev/null || true
diskutil unmount "${HFS_PART}" 2>/dev/null || true
hdiutil detach "${DEVICE}" -force
DEVICE=""  # prevent cleanup double-detach

# Copy OVMF vars template
cp "${OVMF_VARS_TEMPLATE}" "${OVMF_VARS}"

info ""
info "Setup complete!"
info ""
info "  Disk image:  ${RAW_IMAGE}"
info "  OVMF code:   ${OVMF_CODE}"
info "  OVMF vars:   ${OVMF_VARS}"
info ""
info "To boot, run:"
info ""
info "  qemu-system-x86_64 \\"
info "    -m 2048 \\"
info "    -smp 2 \\"
info "    -cpu Penryn \\"
info "    -machine q35 \\"
info "    -drive if=pflash,format=raw,readonly=on,file=${OVMF_CODE} \\"
info "    -drive if=pflash,format=raw,file=${OVMF_VARS} \\"
info "    -drive file=${RAW_IMAGE},format=raw \\"
info "    -serial mon:stdio \\"
info "    -nographic \\"
info "    -usb -device usb-kbd \\"
info "    -netdev user,id=net0 -device e1000,netdev=net0"
