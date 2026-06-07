#!/system/bin/sh
MODDIR=${0%/*}

# Run the action.sh script in the background
sh "$MODDIR/action.sh" &
