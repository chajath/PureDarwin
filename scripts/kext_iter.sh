#!/usr/bin/env bash
# kext_iter.sh — one-cycle kext build+install+probe loop
#
# Usage:
#   kext_iter.sh BUNDLE_ID CLASSNAME SOURCE_DIR [TIMEOUT] [WAIT_PATTERN]
#
# Builds a single .cpp + companion .h kext bundle against the bundled
# 10.13 SDK (via Rosetta), installs it into the modded raw image,
# rebuilds the VMDK, runs pd_run.sh probe, and reports.
#
# Expected layout under SOURCE_DIR:
#   *.cpp                   one or more sources
#   Info.plist              full bundle plist (we won't generate one here)
set -euo pipefail

BUNDLE_ID="${1:?bundle id}"
CLASSNAME="${2:?class name}"
SRC_DIR="${3:?source dir}"
TIMEOUT="${4:-180}"
WAIT_PATTERN="${5:-${CLASSNAME}}"

PROJ="$HOME/PureDarwin"
SDK="$PROJ/userland/.build/apple-clt-10.13/full-extract/CLTools_SDK_macOS1013.pkg/Payload/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
CLT="$PROJ/userland/.build/apple-clt-10.13/full-extract/CLTools_Executables.pkg/Payload/Library/Developer/CommandLineTools/usr/bin/clang++"
PD_KH="$PROJ/userland/.build/pd-kernel-headers"
COMPAT="$PROJ/userland/kexts/pd_ionf_compat.h"
RAW="$PROJ/userland/boot/pd_17_4_modded.raw"
RUN="$PROJ/scripts/pd_run.sh"

BUILD_DIR="/tmp/kext_iter/$CLASSNAME"
KEXT_BUNDLE="/tmp/kext_iter/${CLASSNAME}.kext"
MACHO_OUT="$BUILD_DIR/${CLASSNAME}"

rm -rf "$BUILD_DIR" "$KEXT_BUNDLE"
mkdir -p "$BUILD_DIR" "$KEXT_BUNDLE/Contents/MacOS"

#-- build --
INCLUDES=(
  -isysroot "$SDK"
  -I"$SDK/System/Library/Frameworks/Kernel.framework/Headers"
  -I"$SRC_DIR"
)
# If pd-kernel-headers exists, layer it after the SDK so it overlays only
# what we explicitly include; if it interferes we can drop -I.
if [ -d "$PD_KH" ]; then
  INCLUDES=(-isysroot "$SDK" -I"$PD_KH" -I"$SDK/System/Library/Frameworks/Kernel.framework/Headers" -I"$SRC_DIR")
fi

CFLAGS=(
  -target x86_64-apple-darwin17 -mmacosx-version-min=10.13
  -mkernel -nostdlib -Wl,-kext
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT
  -fno-builtin -fno-rtti -fno-exceptions -fno-common -fapple-kext -Os
  -Wno-inconsistent-missing-override
  -Wno-extern-initializer
)
if [ -f "$COMPAT" ]; then
  CFLAGS+=( -include "$COMPAT" )
fi

SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$SRC_DIR" -maxdepth 1 -name '*.cpp' -type f)
echo "==> building (${#SRCS[@]} src files)"
arch -x86_64 "$CLT" "${INCLUDES[@]}" "${CFLAGS[@]}" \
  -o "$MACHO_OUT" "${SRCS[@]}" -lkmod -lcc_kext 2>&1 | tee "$BUILD_DIR/build.log" | head -30
test -s "$MACHO_OUT" || { echo "BUILD FAILED"; exit 10; }

# Show the RESERVED slot pattern (a useful summary for kxld debugging).
echo "==> RESERVED slots referenced:"
nm "$MACHO_OUT" | awk '/_RESERVED/{print $NF}' \
  | sed -E 's/.*_RESERVED([A-Za-z]+)([0-9]+).*/\1\t\2/' \
  | sort -u | awk '{print $1, $2}' | sort -k1,1 -k2,2n \
  | awk 'BEGIN{cls=""} {if($1!=cls){if(cls)print "  "cls": "first"-"last; cls=$1; first=$2}; last=$2} END{if(cls)print "  "cls": "first"-"last}'

#-- bundle --
cp "$MACHO_OUT" "$KEXT_BUNDLE/Contents/MacOS/${CLASSNAME}"
cp "$SRC_DIR/Info.plist" "$KEXT_BUNDLE/Contents/Info.plist"
# Force CFBundleExecutable to match
plutil -replace CFBundleExecutable -string "$CLASSNAME" "$KEXT_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$KEXT_BUNDLE/Contents/Info.plist"

#-- install --
echo "==> installing into image"
"$RUN" kill >/dev/null 2>&1 || true
hdiutil attach -imagekey diskimage-class=CRawDiskImage "$RAW" -nomount >/dev/null 2>&1
sleep 1
diskutil mount /dev/disk4s1 >/dev/null
MNT=/Volumes/PureDarwin_17.4
# Remove every prior copy we may have installed
rm -rf "$MNT/System/Library/Extensions/${CLASSNAME}.kext"
cp -R "$KEXT_BUNDLE" "$MNT/System/Library/Extensions/"
chmod -R 755 "$MNT/System/Library/Extensions/${CLASSNAME}.kext"
touch "$MNT/System/Library/Extensions"
diskutil unmount force "$MNT" >/dev/null
hdiutil detach /dev/disk4 -force >/dev/null
# Force VMDK rebuild
rm -f "$PROJ/userland/boot/pd_17_4_modded.vmdk"
qemu-img convert -f raw "$RAW" -O vmdk "$PROJ/userland/boot/pd_17_4_modded.vmdk" >/dev/null

#-- probe --
echo "==> probe (up to ${TIMEOUT}s, looking for: $WAIT_PATTERN)"
set +e
"$RUN" probe "$TIMEOUT" "$WAIT_PATTERN"
rc=$?
set -e

echo "==> grep $CLASSNAME serial:"
grep -nE "RTL|panic|kxld|${CLASSNAME}|${BUNDLE_ID}" /tmp/pd_serial.log | head -50

exit $rc
