#!/system/bin/sh
MODDIR=${0%/*}
echo 'One targeted SOTER restart will be requested if safety checks permit.'
echo 'No application data or hardware keys are cleared.'
/system/bin/sh "$MODDIR/soterctl.sh" repair
sf_rc=$?
/system/bin/sh "$MODDIR/soterctl.sh" status
/system/bin/sh "$MODDIR/soterctl.sh" diagnose
echo 'Service availability does not prove that the SOTER key is valid.'
echo 'Check the vendor EngineerMode SOTER test and normal authentication separately.'
exit "$sf_rc"
