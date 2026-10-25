#!/system/bin/sh
MODDIR=${0%/*}
# Nonblocking late-start fallback; watch.lock prevents duplicate workers.
/system/bin/sh "$MODDIR/soterctl.sh" watch >/dev/null 2>&1 &
