#!/bin/sh
# pkgsrc bootstrap wrapper for PureDarwin
# Handles all the Darwin-specific quirks

export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
export SHELL=/bin/sh
export USER=root
export HOME=/var/root
export LOGNAME=root
export TERM=vt100

cd /usr/pkgsrc/bootstrap

echo "=== PureDarwin pkgsrc bootstrap ==="
echo "PATH: $PATH"
echo "sw_vers: $(sw_vers -productVersion)"
echo ""

exec ./bootstrap \
    --unprivileged \
    --prefix=/usr/pkg \
    --workdir=/private/tmp/pkgsrc-bootstrap \
    --compiler=clang \
    --make-jobs=1
