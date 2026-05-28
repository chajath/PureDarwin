#!/bin/sh
# Boot-time init for PureDarwin guest.
# Runs from org.puredarwin.pdinit.plist (launchd) at boot.
# pd_inetd is started separately by org.puredarwin.pdinetd.plist.
LOG=/var/log/pd_init.log
exec >> "$LOG" 2>&1
echo "===== pd_init at $(date) ====="

# Determine which disk is root vs data and mount the other one on /opt.
ROOT_DEV=$(/bin/df / | /usr/bin/awk 'NR==2 {print $1}')
case "$ROOT_DEV" in
  *disk0s1) DATA_DEV=/dev/disk1s1 ;;
  *disk1s1) DATA_DEV=/dev/disk0s1 ;;
  *)        DATA_DEV=/dev/disk1s1 ;;
esac
echo "root=$ROOT_DEV, data=$DATA_DEV"

if ! /sbin/mount | /usr/bin/grep -q ' on /opt '; then
    /bin/mkdir -p /opt
    /sbin/mount -t hfs "$DATA_DEV" /opt 2>&1
fi

# Bring up Ethernet via configd stand-in and static SLIRP address.
if [ -x /usr/local/sbin/pd_net_attach ]; then
    /usr/local/sbin/pd_net_attach 2>&1
    /sbin/ifconfig en0 inet 10.0.2.15 netmask 255.255.255.0 up 2>&1
    /sbin/route -n add default 10.0.2.2 2>&1
fi

# User-supplied additional init lives on the data disk.
[ -x /opt/etc/pd_local_init.sh ] && /opt/etc/pd_local_init.sh 2>&1

echo "===== pd_init done ====="
