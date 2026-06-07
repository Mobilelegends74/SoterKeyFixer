#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/local/tmp/soterfix.log

echo "$(date): boot-completed.sh started" > $LOG
sleep 90
echo "$(date): sleep done, starting repair loop" >> $LOG

MAX_ATTEMPTS=25
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    stop vendor.soter
    sleep 2
    pm clear com.tencent.soter.soterserver
    start vendor.soter
    sleep 8
    ATTEMPT=$((ATTEMPT + 1))
done

echo "$(date): repair loop done" >> $LOG
