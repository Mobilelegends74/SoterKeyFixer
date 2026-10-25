#!/system/bin/sh
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
MODDIR=$(cd "$MODDIR" && pwd) || exit 1
. "$MODDIR/lib/soter.sh"
sf_init || exit 1

case "${1:-status}" in
    launch) sf_launch ;;
    watch) sf_watch ;;
    repair) sf_repair manual ;;
    status)
        echo "Soter Key Fixer $(sf_version)"
        echo "Service availability: $(sf_state)"
        echo 'Hardware key health: UNKNOWN_UNVERIFIED (no validated functional probe implemented)'
        if sf_boot_target; then
            echo 'Startup workaround: once after boot completion, unlock and 5-second dependency readiness check; no fixed boot delay.'
        else echo 'Startup workaround: disabled or untested device profile.'; fi
        echo "Background worker: $(sf_worker_status)"
        if sf_budget; then echo "Requests this boot: $SF_COUNT/3"; else echo 'Recovery budget invalid; automatic recovery is blocked.'; fi
        if [ -f "$SF_STATE/status.json" ]; then
            echo 'Last recovery observation (not a live key test):'
            cat "$SF_STATE/status.json"
        fi
        ;;
    diagnose)
        sf_profile
        sf_diagnose ;;
    pause)
        : > "$SF_STATE/pause"
        sf_log 'pause=requested; automatic and manual recovery blocked'
        echo 'Recovery paused. The monitor exits within 120 seconds.' ;;
    resume)
        sf_stop_allows_boot || { echo 'Module uninstall stop is set for this boot; reboot after reinstalling.'; exit 1; }
        rm -f "$SF_STATE/pause"
        sf_launch
        echo 'Recovery resumed; budgets and cooldowns are preserved.' ;;
    boot-off)
        : > "$SF_STATE/no-boot-recovery"
        sf_log 'boot_workaround=disabled_by_user'
        echo 'Startup workaround disabled; manual repair remains available.' ;;
    boot-on)
        rm -f "$SF_STATE/no-boot-recovery"
        echo 'Startup workaround enabled for the next reboot; budgets are not reset.' ;;
    *) echo 'Usage: soterctl.sh status|repair|diagnose|pause|resume|watch|launch|boot-off|boot-on'; exit 2 ;;
esac
