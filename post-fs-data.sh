#!/system/bin/sh
# KernelSU module installation script

MODDIR=${0%/*}

# Set permission
chmod 0755 $MODDIR/service.sh
chmod 0755 $MODDIR/action.sh
chmod 0755 $MODDIR/boot-completed.sh
