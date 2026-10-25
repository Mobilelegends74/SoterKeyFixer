#!/system/bin/sh
# Never remove live lock inodes or touch SOTER/keystore data.
if [ -d /data/adb/soterfix ] && [ ! -L /data/adb/soterfix ]; then
    umask 077
    if cat /proc/sys/kernel/random/boot_id > /data/adb/soterfix/stop.tmp.$$; then
        mv -f /data/adb/soterfix/stop.tmp.$$ /data/adb/soterfix/stop
    fi
fi
# The worker observes removal within its 120s poll interval. Root-only
# diagnostics remain available; reboot before manually removing this directory.
