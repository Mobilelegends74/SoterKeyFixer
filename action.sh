#!/system/bin/sh
echo "Starting to fix SOTER Key issue"
stop vendor.soter
sleep 3
pm clear com.tencent.soter.soterserver
start vendor.soter
sleep 5
getprop init.svc.vendor.soter
echo "Repair complete. After powering on, please dial *#899# and select manual test to check the SOTER Key. If it fails, please refresh a few more times."