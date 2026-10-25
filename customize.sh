#!/system/bin/sh
ui_print 'Soter Key Fixer 1.4 TEST 5 - manual recovery guard correction'
ui_print 'Target: OnePlus 13R / OxygenOS 15 / KernelSU Next'
ui_print 'Key health is not inferred from service state.'
ui_print 'Reboot required. Old 1.3 loops may remain active until reboot.'
set_perm_recursive "$MODPATH" 0 0 0755 0644
for sf_script in action.sh service.sh boot-completed.sh soterctl.sh uninstall.sh; do
    set_perm "$MODPATH/$sf_script" 0 0 0755
done
