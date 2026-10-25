#!/system/bin/sh
MODDIR=${0%/*}
# Second entry for very slow boots / managers that support this stage.
/system/bin/sh "$MODDIR/soterctl.sh" launch
