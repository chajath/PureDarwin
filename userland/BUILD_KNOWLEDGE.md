# PureDarwin Userland Upgrade — Build Knowledge Base

## Cross-Compilation Toolchain for Darwin 17

### Required Compiler Flags
All userland binaries targeting PureDarwin 17.4 (Darwin 17 / macOS 10.13) must use:

```bash
CC="clang -target x86_64-apple-darwin17 -mmacosx-version-min=10.13"
LDFLAGS="-Wl,-no_fixup_chains"
CFLAGS="-Os -D_FORTIFY_SOURCE=0"
```

**Why each flag matters:**
- `-target x86_64-apple-darwin17`: Cross-compile for x86_64 Darwin 17
- `-mmacosx-version-min=10.13`: Set minimum deployment target
- `-Wl,-no_fixup_chains`: **CRITICAL** — Apple Clang 21+ emits `LC_DYLD_CHAINED_FIXUPS` (load command `0x80000034`) by default, even when targeting darwin17. Darwin 17's dyld predates this feature and will crash with `dyld: cannot load 'mksh' (load command 0x80000034 is unknown)`. This flag forces old-style relocations.
- `-D_FORTIFY_SOURCE=0`: PureDarwin's `/usr/include/secure/_common.h` defines `_USE_FORTIFY_LEVEL 2`, which causes `__builtin___strlcpy_chk` conflicts when building pkgsrc components (bmake, etc.). Disabling at compile time is insufficient — the header must also be patched on the image.

### Header Patching on PureDarwin Image
Patch `/usr/include/secure/_common.h` to set all `_USE_FORTIFY_LEVEL` to 0:
```bash
sed -i '' 's/define _USE_FORTIFY_LEVEL 2/define _USE_FORTIFY_LEVEL 0/g' "$MNT/usr/include/secure/_common.h"
sed -i '' 's/define _USE_FORTIFY_LEVEL 1/define _USE_FORTIFY_LEVEL 0/g' "$MNT/usr/include/secure/_common.h"
```

## Building PureDarwin from Source (macOS Tahoe / Xcode 26)

Three patches required for the PureDarwin build system:

1. **`tools/cctools/ld64/src/ld/code-sign-blobs/blob.h`**: Add missing `BlobCore::clone()` method — removed from newer SDKs.

2. **`src/Kernel/xnu/cmake/MakeInc.def.in`**: Remove `-enable-trivial-auto-var-init-zero-knowing-it-will-be-removed-from-clang` — this flag was literally removed from clang as its name promised.

3. **`src/Kernel/Extensions/IOPCIFamily/include/IOKit/apiodma/ApplePIODMADefinitions.h`**: Fix `APIODMABitRange32(32, 63)` — shifting a uint32_t by 32 is undefined behavior; newer clang rejects it in constant expressions.

## Kext Cross-Compilation (THE HARD PROBLEM)

### The Vtable ABI Problem
**IOKit kexts CANNOT be trivially cross-compiled.** The XNU kernel's kxld linker validates vtable layouts at kext load time by comparing:
- The child kext's vtable entry count and pad slot positions
- Against the parent class vtable in the already-loaded kext (e.g., IONetworkingFamily)

The error `The super class vtable '__ZTV20IOEthernetController' for vtable '__ZTV15RTL8139Ethernet' is out of date` means vtable slot mismatch.

### What Causes Vtable Mismatches

1. **Public vs Private Headers**: Apple's IONetworkingFamily.kext is built with PRIVATE headers containing additional reserved virtual method slots (`OSMetaClassDeclareReservedUnused`). The public macOS SDK headers have FEWER reserved slots. PureDarwin 17.4's IONetworkingFamily has 82 IOEthernetController-related symbols; the public SDK only produces 49.

2. **Compiler Version**: Different compilers generate different vtable padding. However, this is secondary — even Apple's own clang-902 produces the same pad format. The slot COUNT from headers is the primary issue.

3. **Open-Source vs Closed Headers**: The `IONetworkingFamily` source at `apple-oss-distributions/IONetworkingFamily` (version 3.4) includes the full reserved slot declarations in its headers. This matches PureDarwin's binary because PureDarwin's IONetworkingFamily was built from this same source.

### Solution: Build Against IONetworkingFamily Source Headers
The CORRECT approach:
1. Clone `apple-oss-distributions/IONetworkingFamily` (tag: IONetworkingFamily-188, version 3.4)
2. Use its headers (which include ALL reserved virtual method slots) as include path
3. Build BOTH `IONetworkingFamily.kext` AND the driver kext with the same compiler + headers
4. Replace PureDarwin's `IONetworkingFamily.kext` with the freshly built one

### Required Compiler for Kexts
- **Apple Clang (clang-902)** from "Command Line Tools (macOS 10.13) for Xcode 9.4.1"
  - Download from: https://developer.apple.com/download/all/
  - Extract with: `pkgutil --expand-full <pkg> <output_dir>`
  - Run via Rosetta: `arch -x86_64 <path>/usr/bin/clang++`
  - Version string: `Apple LLVM version 9.1.0 (clang-902.0.39.2)`
- **macOS 10.13 SDK** included in the same CLT package at:
  `CLTools_SDK_macOS1013.pkg/Payload/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`

### Kext Compile Flags
```bash
arch -x86_64 "$CLT/usr/bin/clang++" \
    -target x86_64-apple-darwin17 -mmacosx-version-min=10.13 \
    -mkernel -nostdlib -Wl,-kext \
    -isysroot "$SDK10" \
    -I"$IONF_SRC"  # IONetworkingFamily source headers \
    -I"$SDK10/System/Library/Frameworks/Kernel.framework/Headers" \
    -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
    -fno-builtin -fno-rtti -fno-exceptions -fno-common -fapple-kext -Os
```

## PureDarwin 17.4 QEMU Boot

### QEMU Command
```bash
qemu-system-x86_64 -m 2048 -cpu Penryn -smp 2 \
    -accel tcg,thread=multi \
    -netdev user,id=network0 -device rtl8139,netdev=network0 \
    -serial stdio \
    -drive format=vmdk,file=$HOME/PureDarwin/userland/boot/pd_17_4_modded.vmdk
```

### Key Facts
- PureDarwin 17.4 uses **Chameleon bootloader + SeaBIOS** (not UEFI/OpenCore)
- Boot is extremely slow under TCG on ARM64 (~5-10 min to shell)
- Shell appears on **VGA console only** — no serial port driver in kernel
- `-accel tcg,thread=multi` provides ~1.5x speedup
- Rosetta 2 CANNOT accelerate x86_64 VM guests (only userspace Mach-O)
- xhyve/Hypervisor.framework on Apple Silicon only supports ARM64 guests

### Network NIC Matching
| QEMU Device | PCI ID | PureDarwin Kext | Match? |
|-------------|--------|-----------------|--------|
| rtl8139 | 10EC:8139 | RealtekRTL8100 (10EC:8136) | No |
| e1000 | 8086:100E | None | No |
| virtio-net | 1AF4:1000 | None | No |

**No QEMU NIC matches any existing PureDarwin kext.** A custom RTL8139 IOKit driver is needed.

### Image Modification Workflow
```bash
# Mount
hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage pd_17_4_modded.raw
diskutil mount disk4s1
MNT=$(diskutil info disk4s1 | grep "Mount Point" | sed 's/.*: *//')

# ... modify files on $MNT ...

# Unmount (force needed due to Microsoft Defender)
diskutil unmount force disk4s1
hdiutil detach /dev/disk4 -force

# Rebuild VMDK
rm -f pd_17_4_modded.vmdk
qemu-img convert -f raw pd_17_4_modded.raw -O vmdk pd_17_4_modded.vmdk
```

### PureDarwin Quirks
- `/etc` → `/private/etc` (symlink, breaks naive heredocs)
- `/tmp` → `/private/tmp` (pkgsrc rejects symlinks in --workdir)
- `/root` directory doesn't exist by default (use `/var/root`)
- No `sw_vers` command — must create a stub
- BSD tools at `/usr/bin`, `/usr/sbin` — don't shadow with GNU tools
- On-image clang is Apple LLVM 8.0.0 (clang-800, universal i386+x86_64)
- GNU coreutils must use `g`-prefix to avoid shadowing BSD tools

## pkgsrc on PureDarwin

### Bootstrap Issues
Native pkgsrc bootstrap inside PureDarwin fails due to:
- `_FORTIFY_SOURCE` conflicts with bmake's strlcpy
- Missing `sw_vers` command
- BSD grep/sed don't pass pkgsrc's "handles long lines" tests
- GNU tools shadow BSD tools causing flag incompatibilities (e.g., `chown -g`)
- `configure` test programs crash → all feature checks return "no"
- No networking for downloading sources
- TCG emulation makes compilation take hours

### Cross-Compiling pkg_install
pkg_install requires these dependencies built as static libraries:
1. **libnbcompat** — `pkgsrc/pkgtools/libnbcompat/files/`
   - Needs `-I.` for include path
   - Uses bmake Makefile syntax
2. **libfetch** — `pkgsrc/net/libfetch/files/`
   - Generate error headers: `sh errlist.sh ftp ftp_errlist ftp.errors > ftperr.h`
   - Fix array names: `sed 's/^static struct fetcherr ftp\[\]/static struct fetcherr ftp_errlist[]/'`
3. **libarchive** — standard autotools, `--without-xml2 --without-expat --without-openssl`
4. **libnetpgpverify** — stub library (empty, no GPG verification needed)

pkg_install Makefiles use BSD make syntax — need `bmake` (install from Homebrew: `brew install bmake`).

bmake's `boot-strap` script CANNOT cross-compile (runs test programs on host).
