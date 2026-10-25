#!/system/bin/sh
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
MODDIR=$(cd "$MODDIR" && pwd) || exit 1
. "$MODDIR/lib/soter.sh"
sf_init || exit 1

case "${1:-status}" in
    watch) sf_watch ;;
    repair) sf_repair manual ;;
    status)
        echo 'Soter Key Fixer 1.4-test'
        echo "Service availability: $(sf_state)"
        echo 'Hardware key health: UNKNOWN_UNVERIFIED (no validated functional probe implemented)'
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
        /system/bin/sh "$MODDIR/soterctl.sh" watch >/dev/null 2>&1 &
        echo 'Recovery resumed; budgets and cooldowns are preserved.' ;;
    *) echo 'Usage: soterctl.sh status|repair|diagnose|pause|resume|watch'; exit 2 ;;
esac
