#!/bin/bash
#
# build-userland.sh — Master build script for PureDarwin userland upgrade
#
# Builds a modern Unix-like userland targeting Darwin 17 / x86_64.
# Run on macOS host. Products go into ./rootfs/ as a filesystem image.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERLAND_DIR="$(dirname "$SCRIPT_DIR")"
ROOTFS="${USERLAND_DIR}/rootfs"
DOWNLOAD="${USERLAND_DIR}/.download"
BUILD="${USERLAND_DIR}/.build"
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Cross-compilation settings
TARGET=x86_64-apple-darwin17
CC="clang -target ${TARGET} -mmacosx-version-min=10.13"
CXX="clang++ -target ${TARGET} -mmacosx-version-min=10.13"
LDFLAGS="-Wl,-no_fixup_chains"
export CC CXX LDFLAGS

# Versions
MKSH_VERSION="R59c"
COREUTILS_VERSION="9.5"
LIBRESSL_VERSION="3.9.2"
CURL_VERSION="8.7.1"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

download() {
    local url="$1" dest="$2"
    if [ -f "$dest" ]; then
        info "Already downloaded: $(basename "$dest")"
        return 0
    fi
    info "Downloading: $url"
    mkdir -p "$(dirname "$dest")"
    curl -fSL "$url" -o "$dest"
}

#
# Phase 0: Create rootfs skeleton
#
phase0_skeleton() {
    info "Phase 0: Creating rootfs skeleton"
    mkdir -p "${ROOTFS}"/{bin,sbin,usr/{bin,sbin,lib,libexec,include,share/man},etc,var/{log,run,tmp},tmp,dev,root,private}
    chmod 1777 "${ROOTFS}/tmp" "${ROOTFS}/var/tmp"

    # Install rc script
    install -m 755 "${USERLAND_DIR}/init/rc" "${ROOTFS}/etc/rc"
    
    # Basic /etc files
    cat > "${ROOTFS}/etc/hosts" <<'EOF'
127.0.0.1   localhost
::1         localhost
EOF
    cat > "${ROOTFS}/etc/resolv.conf" <<'EOF'
# PureDarwin DNS configuration
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    cat > "${ROOTFS}/etc/passwd" <<'EOF'
root:*:0:0:System Administrator:/root:/bin/sh
nobody:*:-2:-2:Unprivileged User:/var/empty:/usr/bin/false
daemon:*:1:1:System Services:/var/root:/usr/bin/false
EOF
    cat > "${ROOTFS}/etc/group" <<'EOF'
wheel:*:0:root
daemon:*:1:
nobody:*:-2:
staff:*:20:root
EOF
    cat > "${ROOTFS}/etc/shells" <<'EOF'
/bin/sh
/bin/mksh
EOF

    info "Rootfs skeleton created at ${ROOTFS}"
}

#
# Phase 1: Build pd_init
#
phase1_init() {
    info "Phase 1: Building pd_init"
    mkdir -p "${BUILD}/init"
    ${CC} -Wall -Wextra -Os \
        -o "${BUILD}/init/pd_init" \
        "${USERLAND_DIR}/init/pd_init.c"
    install -m 755 "${BUILD}/init/pd_init" "${ROOTFS}/sbin/init"
    info "pd_init installed to ${ROOTFS}/sbin/init"
}

#
# Phase 2: Build shell (mksh)
#
phase2_shell() {
    info "Phase 2: Building mksh"
    local tarball="${DOWNLOAD}/mksh-${MKSH_VERSION}.tgz"
    download "https://github.com/MirBSD/mksh/archive/refs/tags/mksh-${MKSH_VERSION}.tar.gz" "$tarball"
    
    mkdir -p "${BUILD}/mksh"
    tar xzf "$tarball" -C "${BUILD}/mksh" --strip-components=1
    
    (
        cd "${BUILD}/mksh"
        # mksh's Build.sh respects CC
        env CC="${CC}" sh Build.sh -r
    )
    
    install -m 755 "${BUILD}/mksh/mksh" "${ROOTFS}/bin/mksh"
    ln -sf mksh "${ROOTFS}/bin/sh"
    info "mksh installed to ${ROOTFS}/bin/mksh"
}

#
# Phase 3: Build GNU coreutils
#
phase3_coreutils() {
    info "Phase 3: Building GNU coreutils"
    local tarball="${DOWNLOAD}/coreutils-${COREUTILS_VERSION}.tar.xz"
    download "https://ftp.gnu.org/gnu/coreutils/coreutils-${COREUTILS_VERSION}.tar.xz" "$tarball"
    
    mkdir -p "${BUILD}/coreutils"
    tar xJf "$tarball" -C "${BUILD}/coreutils" --strip-components=1
    
    (
        cd "${BUILD}/coreutils"
        ./configure \
            --host=x86_64-apple-darwin17 \
            --prefix=/usr \
            --without-gmp \
            --without-openssl \
            CFLAGS="-Os"
        make -j${JOBS}
        make DESTDIR="${ROOTFS}" install
    )
    info "GNU coreutils installed"
}

#
# Phase 4: Build LibreSSL (TLS without Apple frameworks)
#
phase4_libressl() {
    info "Phase 4: Building LibreSSL"
    local tarball="${DOWNLOAD}/libressl-${LIBRESSL_VERSION}.tar.gz"
    download "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VERSION}.tar.gz" "$tarball"
    
    mkdir -p "${BUILD}/libressl"
    tar xzf "$tarball" -C "${BUILD}/libressl" --strip-components=1
    
    (
        cd "${BUILD}/libressl"
        ./configure \
            --host=x86_64-apple-darwin17 \
            --prefix=/usr \
            CFLAGS="-Os"
        make -j${JOBS}
        make DESTDIR="${ROOTFS}" install
    )
    info "LibreSSL installed"
}

#
# Phase 5: Build curl (with LibreSSL backend)
#
phase5_curl() {
    info "Phase 5: Building curl"
    local tarball="${DOWNLOAD}/curl-${CURL_VERSION}.tar.xz"
    download "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" "$tarball"
    
    mkdir -p "${BUILD}/curl"
    tar xJf "$tarball" -C "${BUILD}/curl" --strip-components=1
    
    (
        cd "${BUILD}/curl"
        ./configure \
            --host=x86_64-apple-darwin17 \
            --prefix=/usr \
            --with-openssl="${ROOTFS}/usr" \
            --without-brotli \
            --without-zstd \
            --without-nghttp2 \
            CFLAGS="-Os" \
            LDFLAGS="-L${ROOTFS}/usr/lib" \
            CPPFLAGS="-I${ROOTFS}/usr/include"
        make -j${JOBS}
        make DESTDIR="${ROOTFS}" install
    )
    info "curl installed"
}

#
# Main
#
usage() {
    echo "Usage: $0 [phase0|phase1|phase2|phase3|phase4|phase5|all]"
    echo ""
    echo "Phases:"
    echo "  phase0  - Create rootfs skeleton (/etc, directory tree)"
    echo "  phase1  - Build pd_init (PID 1 init replacement)"
    echo "  phase2  - Build mksh (shell)"
    echo "  phase3  - Build GNU coreutils"
    echo "  phase4  - Build LibreSSL"
    echo "  phase5  - Build curl"
    echo "  all     - Run all phases"
    exit 1
}

case "${1:-all}" in
    phase0) phase0_skeleton ;;
    phase1) phase1_init ;;
    phase2) phase2_shell ;;
    phase3) phase3_coreutils ;;
    phase4) phase4_libressl ;;
    phase5) phase5_curl ;;
    all)
        phase0_skeleton
        phase1_init
        phase2_shell
        phase3_coreutils
        phase4_libressl
        phase5_curl
        info "All phases complete. Rootfs at: ${ROOTFS}"
        ;;
    *) usage ;;
esac
