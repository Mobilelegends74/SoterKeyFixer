#!/system/bin/sh
# GPL-2.0. Availability supervision only; never a hardware-key attestation probe.
SF_STATE=/data/adb/soterfix
SF_RC_DIRS='/vendor/etc/init /odm/etc/init /system/etc/init /system_ext/etc/init /product/etc/init'
SF_PROC=/proc
SF_BB=
SF_FLOCK_BB=no
SF_TIMEOUT_BB=no
SF_AWK_BB=no
SF_PROFILE=uninspected
SF_MAX_ATTEMPTS=3
SF_POLL=120
SF_GRACE=0
SF_BOOT_DELAY=0
SF_BOOT_SETTLE=0
SF_BOOT_PENDING=no
SF_BOOT_READY_SINCE=0
SF_BOOT_DUE=0
SF_BOOT_LAST_REASON=
SF_NEXT_SLEEP=120

sf_tools() {
    for sf_candidate in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox; do
        if [ -x "$sf_candidate" ]; then SF_BB=$sf_candidate; break; fi
    done
    SF_FLOCK_BB=no; SF_TIMEOUT_BB=no; SF_AWK_BB=no
    if [ -n "$SF_BB" ] && "$SF_BB" flock --help >/dev/null 2>&1; then
        SF_FLOCK_BB=yes
    else command -v flock >/dev/null 2>&1 || return 1; fi
    if [ -n "$SF_BB" ] && "$SF_BB" timeout --help >/dev/null 2>&1; then
        SF_TIMEOUT_BB=yes
    else command -v timeout >/dev/null 2>&1 || return 1; fi
    if [ -n "$SF_BB" ] && "$SF_BB" awk --help >/dev/null 2>&1; then
        SF_AWK_BB=yes
    else command -v awk >/dev/null 2>&1 || return 1; fi
}

sf_awk() {
    if [ "$SF_AWK_BB" = yes ]; then "$SF_BB" awk "$@"; else awk "$@"; fi
}

sf_flock() {
    # mksh marks shell-opened FDs close-on-exec. Explicitly pass just the
    # selected descriptor to the external flock applet; never eval an FD.
    if [ "$SF_FLOCK_BB" = yes ]; then
        case "$1" in
            6) "$SF_BB" flock -n 6 6>&6 ;;
            7) "$SF_BB" flock -n 7 7>&7 ;;
            8) "$SF_BB" flock -n 8 8>&8 ;;
            9) "$SF_BB" flock -n 9 9>&9 ;;
            *) return 2 ;;
        esac
    else
        case "$1" in
            6) flock -n 6 6>&6 ;;
            7) flock -n 7 7>&7 ;;
            8) flock -n 8 8>&8 ;;
            9) flock -n 9 9>&9 ;;
            *) return 2 ;;
        esac
    fi
}

sf_timed() (
    # BusyBox timeout may leave a timer child briefly alive after its command.
    # It must never inherit the parent's advisory locks (or keep a dead worker
    # "busy" after exit). The parent remains the sole lock owner.
    exec 6>&- 7>&- 8>&- 9>&-
    sf_timeout=$1; shift
    if [ "$SF_TIMEOUT_BB" = yes ]; then
        exec "$SF_BB" timeout -k 2 "$sf_timeout" "$@"
    else
        exec timeout -k 2 "$sf_timeout" "$@"
    fi
)

sf_prop() { sf_timed 5 getprop "$1" 2>/dev/null; }
sf_version() { sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1; }
sf_sleep() ( exec 6>&- 7>&- 8>&- 9>&-; exec sleep "$1"; )
sf_now() {
    IFS=' ' read -r sf_up _ < "$SF_PROC/uptime" || return 1
    sf_up=${sf_up%%.*}
    sf_uint "$sf_up" || return 1
    printf '%s\n' "$sf_up"
}
sf_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 10 ]; }
sf_boot_id() { cat "$SF_PROC/sys/kernel/random/boot_id"; }

sf_init() {
    [ "$(id -u)" = 0 ] || { echo 'Root is required.' >&2; return 1; }
    sf_tools || { echo 'flock/timeout unavailable; no recovery will run.' >&2; return 1; }
    [ ! -L "$SF_STATE" ] || return 1
    umask 077
    mkdir -p "$SF_STATE" || return 1
    chmod 0700 "$SF_STATE" || return 1
    for sf_file in budget grace status.json events.log events.log.1 launcher.log launcher.log.1 log.lock repair.lock watch.lock diag.lock pause stop no-boot-recovery; do
        [ ! -L "$SF_STATE/$sf_file" ] || return 1
    done
    SF_BOOT=$(sf_boot_id) || return 1
    case "$SF_BOOT" in ''|*[!a-f0-9-]*) return 1 ;; esac
    [ "${#SF_BOOT}" = 36 ] || return 1
}

sf_stop_allows_boot() {
    [ -e "$SF_STATE/stop" ] || return 0
    IFS= read -r sf_stop_boot < "$SF_STATE/stop" || return 1
    case "$sf_stop_boot" in ''|*[!a-f0-9-]*) return 1 ;; esac
    [ "${#sf_stop_boot}" = 36 ] && [ "$sf_stop_boot" != "$SF_BOOT" ]
}

sf_active() {
    [ -d "$MODDIR" ] && [ ! -e "$MODDIR/disable" ] &&
    [ ! -e "$MODDIR/remove" ] && [ ! -e "$MODDIR/update" ] &&
    sf_stop_allows_boot && [ ! -e "$SF_STATE/pause" ] &&
    [ "$(sf_boot_id)" = "$SF_BOOT" ]
}

sf_log() (
    exec 6>"$SF_STATE/log.lock" || exit 1
    sf_flock 6 || exit 0
    if [ -f "$SF_STATE/events.log" ] && [ "$(wc -c < "$SF_STATE/events.log")" -ge 131072 ]; then
        mv -f "$SF_STATE/events.log" "$SF_STATE/events.log.1" || exit 1
    fi
    printf '%s uptime=%s pid=%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "$(sf_now)" "$$" "$*" >> "$SF_STATE/events.log"
)

sf_state() {
    sf_value=$(sf_prop init.svc.vendor.soter) || { echo unavailable; return; }
    case "$sf_value" in running|stopped|restarting) echo "$sf_value" ;; *) echo unavailable ;; esac
}

sf_pid() {
    sf_value=$(sf_prop init.svc_debug_pid.vendor.soter) || return 1
    sf_uint "$sf_value" && [ "$sf_value" -gt 1 ] || return 1
    printf '%s\n' "$sf_value"
}

sf_profile_unknown() {
    SF_PROFILE=unknown
    printf 'profile=unknown\nreason=%s\n' "$1" > "$SF_STATE/profile.tmp.$$" &&
        mv -f "$SF_STATE/profile.tmp.$$" "$SF_STATE/profile.txt"
}

sf_profile() {
    set --
    # Recurse through standard init roots; imported vendor subdirectories can
    # otherwise hide another definition or a property-triggered side effect.
    for sf_dir in $SF_RC_DIRS; do
        [ -d "$sf_dir" ] && set -- "$@" "$sf_dir"
    done
    if [ "$#" = 0 ]; then sf_profile_unknown INIT_ROOTS_UNAVAILABLE; return; fi
    sf_timed 8 find -H "$@" -type f -name '*.rc' > "$SF_STATE/rc-list.tmp.$$" || {
        rm -f "$SF_STATE/rc-list.tmp.$$"; sf_profile_unknown INIT_SCAN_FAILED; return;
    }
    set --
    while IFS= read -r sf_file; do set -- "$@" "$sf_file"; done < "$SF_STATE/rc-list.tmp.$$"
    rm -f "$SF_STATE/rc-list.tmp.$$"
    if [ "$#" = 0 ]; then sf_profile_unknown INIT_FILES_UNAVAILABLE; return; fi
    # The applet is explicit: stock Android need not have an awk executable.
    if [ "$SF_AWK_BB" = yes ]; then
        set -- "$SF_BB" awk -f "$MODDIR/lib/profile.awk" "$@"
    else
        set -- awk -f "$MODDIR/lib/profile.awk" "$@"
    fi
    sf_timed 8 "$@" > "$SF_STATE/profile.tmp.$$" || {
        rm -f "$SF_STATE/profile.tmp.$$"; sf_profile_unknown INIT_PARSE_FAILED; return;
    }
    mv -f "$SF_STATE/profile.tmp.$$" "$SF_STATE/profile.txt" || return 1
    SF_PROFILE=$(sed -n 's/^profile=//p' "$SF_STATE/profile.txt")
    case "$SF_PROFILE" in persistent|lazy|unsafe|unknown) ;; *) SF_PROFILE=unknown ;; esac
}

sf_set_grace() {
    sf_time=$(sf_now) || return 1
    if [ -f "$SF_STATE/grace" ]; then
        IFS=' ' read -r sf_oldboot sf_deadline sf_extra < "$SF_STATE/grace" || return 1
        if [ "$sf_oldboot" = "$SF_BOOT" ] && sf_uint "$sf_deadline" &&
            [ -z "$sf_extra" ] && [ "$sf_deadline" -le "$((sf_time + SF_GRACE))" ]; then return 0; fi
    fi
    printf '%s %s\n' "$SF_BOOT" "$((sf_time + SF_GRACE))" > "$SF_STATE/grace.tmp.$$" &&
        mv -f "$SF_STATE/grace.tmp.$$" "$SF_STATE/grace"
}

sf_ready() {
    sf_active || { SF_REASON=PAUSED_OR_DISABLED; return 1; }
    [ "$(sf_prop sys.boot_completed)" = 1 ] || { SF_REASON=BOOT_PENDING; return 1; }
    sf_power=$(sf_prop sys.powerctl) || { SF_REASON=PROPERTY_QUERY_FAILED; return 1; }
    [ -z "$sf_power" ] || { SF_REASON=SHUTDOWN_PENDING; return 1; }
    SF_REASON=READY
}

sf_budget() {
    SF_COUNT=0; SF_LAST=0
    [ -f "$SF_STATE/budget" ] || return 0
    IFS=' ' read -r sf_ver sf_oldboot sf_count sf_last sf_extra < "$SF_STATE/budget" || return 1
    [ "$sf_ver" = v1 ] && [ -z "$sf_extra" ] && sf_uint "$sf_last" || return 1
    case "$sf_count" in 0|1|2|3) ;; *) return 1 ;; esac
    case "$sf_oldboot" in ''|*[!a-f0-9-]*) return 1 ;; esac
    [ "${#sf_oldboot}" = 36 ] || return 1
    [ "$sf_oldboot" = "$SF_BOOT" ] || return 0
    SF_COUNT=$sf_count; SF_LAST=$sf_last
    sf_time=$(sf_now) || return 1
    [ "$SF_LAST" -le "$sf_time" ]
}

sf_report() {
    sf_result=$1
    sf_available=$(sf_state)
    case "${sf_mode:-none}" in auto|manual|boot) sf_request_mode=$sf_mode ;; *) sf_request_mode=none ;; esac
    printf '{"scope":"last_recovery_observation","boot_id":"%s","uptime_s":"%s","request_mode":"%s","result":"%s","profile":"%s","service":"vendor.soter","availability":"%s","key_health":"UNKNOWN_UNVERIFIED","functional_probe":"unavailable"}\n' \
        "$SF_BOOT" "$(sf_now)" "$sf_request_mode" "$sf_result" "$SF_PROFILE" "$sf_available" > "$SF_STATE/status.tmp.$$" &&
        mv -f "$SF_STATE/status.tmp.$$" "$SF_STATE/status.json"
    sf_log "result=$sf_result availability=$sf_available key_health=UNKNOWN_UNVERIFIED"
    printf '%s; service=%s; key health is NOT verified.\n' "$sf_result" "$sf_available"
}

sf_start_soter() { sf_timed 5 setprop ctl.start vendor.soter; }

sf_control() (
    # One complete stop/pause/start cycle, as opposed to a rapid ctl.restart.
    # Never clear APK data or touch other security services.
    case "$1" in
        auto) sf_start_soter ;;
        manual|boot)
            sf_restore=yes
            trap 'if [ "$sf_restore" = yes ]; then sf_start_soter; fi' 0
            trap 'exit 1' 1 2 15
            sf_timed 5 setprop ctl.stop vendor.soter || exit 1
            sf_stop_checks=0
            while [ "$(sf_state)" != stopped ] && [ "$sf_stop_checks" -lt 10 ]; do
                sf_sleep 1
                sf_stop_checks=$((sf_stop_checks + 1))
            done
            [ "$(sf_state)" = stopped ] || exit 1
            sf_log 'cycle=stopped; allowing 3 seconds before start'
            sf_sleep 3 || exit 1
            sf_start_soter || exit 1
            sf_restore=no ;;
        *) return 1 ;;
    esac
)

sf_repair() (
    sf_mode=$1
    case "$sf_mode" in auto|manual|boot) ;; *) exit 2 ;; esac
    exec 8>"$SF_STATE/repair.lock" || exit 1
    sf_flock 8 || { echo 'Another recovery is active.'; exit 12; }
    sf_ready "$sf_mode" || { sf_report "$SF_REASON"; exit 10; }
    sf_profile || SF_PROFILE=unknown
    if [ "$sf_mode" = boot ] && ! sf_boot_gate; then
        sf_report BOOT_WORKAROUND_NOT_READY; exit 10
    fi
    sf_before=$(sf_state)
    case "$sf_before:$sf_mode" in
        stopped:auto)
            sf_i=0
            while [ "$sf_i" -lt 2 ]; do
                sf_sleep 5
                sf_active && [ "$(sf_state)" = stopped ] || { sf_report TRANSIENT_STOP_NO_ACTION; exit 10; }
                sf_i=$((sf_i + 1))
            done ;;
        running:manual|stopped:manual|running:boot|stopped:boot) ;;
        *) sf_report NO_CONFIRMED_RECOVERABLE_FAILURE; exit 10 ;;
    esac
    sf_budget || { sf_report INVALID_BUDGET_NO_ACTION; exit 13; }
    if [ "$sf_mode" = boot ] && [ "$SF_COUNT" -gt 0 ]; then
        sf_log 'boot_workaround=skipped_prior_request; no second startup request'
        exit 14
    fi
    [ "$SF_COUNT" -lt "$SF_MAX_ATTEMPTS" ] || { sf_report CIRCUIT_OPEN_UNTIL_REBOOT; exit 13; }
    sf_time=$(sf_now) || exit 1
    case "$SF_COUNT" in 0) sf_wait=0 ;; 1) sf_wait=300 ;; *) sf_wait=900 ;; esac
    # An early startup attempt must not prevent the user from requesting a
    # real manual recovery. Keep serialization and the total per-boot cap.
    [ "$sf_mode" != manual ] || sf_wait=15
    if [ "$SF_COUNT" -gt 0 ] && [ "$((sf_time - SF_LAST))" -lt "$sf_wait" ]; then
        sf_report COOLDOWN_NO_ACTION; exit 10
    fi
    # Recheck readiness immediately before the only mutating command.
    sf_ready "$sf_mode" || { sf_report "$SF_REASON"; exit 10; }
    sf_capture before || sf_log 'Evidence capture unavailable; availability recovery is still bounded.'
    sf_ready "$sf_mode" || { sf_report "$SF_REASON"; exit 10; }
    sf_latest=$(sf_state)
    case "$sf_mode:$sf_latest" in
        auto:stopped|manual:running|manual:stopped|boot:running|boot:stopped) sf_before=$sf_latest ;;
        *) sf_report TRANSIENT_STOP_NO_ACTION; exit 10 ;;
    esac
    if [ "$sf_mode" = boot ] && ! sf_boot_gate; then
        sf_report BOOT_WORKAROUND_NOT_READY; exit 10
    fi
    sf_previous_pid=$(sf_pid) || sf_previous_pid=
    SF_COUNT=$((SF_COUNT + 1))
    printf 'v1 %s %s %s\n' "$SF_BOOT" "$SF_COUNT" "$(sf_now)" > "$SF_STATE/budget.tmp.$$" &&
        mv -f "$SF_STATE/budget.tmp.$$" "$SF_STATE/budget" || exit 1
    sf_log "request=$sf_mode before=$sf_before attempt=$SF_COUNT/3 profile=$SF_PROFILE"
    if [ "$sf_mode" = boot ]; then
        sf_log 'cause=scheduled_boot_workaround; this is NOT a detected key failure or a key test'
    fi
    sf_active || { sf_report DISABLED_BEFORE_REQUEST; exit 10; }
    if [ "$sf_mode" = boot ] && ! sf_boot_gate; then
        sf_report BOOT_WORKAROUND_CANCELLED; exit 10
    fi
    if ! sf_control "$sf_mode"; then sf_report CONTROL_DENIED_OR_TIMEOUT; exit 1; fi
    sf_transition=no; sf_i=0
    sf_verify_now=$(sf_now) || exit 1
    sf_verify_until=$((sf_verify_now + 20))
    while [ "$sf_i" -lt 20 ]; do
        sf_verify_now=$(sf_now) || break
        [ "$sf_verify_now" -lt "$sf_verify_until" ] || break
        sf_active || { sf_report DISABLED_DURING_RECOVERY; exit 10; }
        sf_after=$(sf_state)
        case "$sf_after" in stopped|restarting) sf_transition=yes ;; esac
        sf_after_pid=$(sf_pid) || sf_after_pid=
        if [ "$sf_after" = running ]; then
            if [ "$sf_before" = stopped ] || [ "$sf_transition" = yes ] ||
                { [ -n "$sf_previous_pid" ] && [ -n "$sf_after_pid" ] && [ "$sf_previous_pid" != "$sf_after_pid" ]; }; then
                sf_log "lifecycle mode=$sf_mode before_pid=${sf_previous_pid:-unknown} after_pid=${sf_after_pid:-unknown}"
                sf_report SERVICE_AVAILABLE_KEY_UNVERIFIED; exit 0
            fi
        fi
        sf_sleep 1
        sf_i=$((sf_i + 1))
    done
    sf_report REQUEST_UNCONFIRMED_KEY_UNVERIFIED
    exit 1
)

sf_capture() (
    case "$1" in before|current) sf_kind=$1 ;; *) exit 2 ;; esac
    exec 7>"$SF_STATE/diag.lock" || exit 1
    sf_flock 7 || exit 12
    sf_temp="$SF_STATE/evidence.tmp.$$"
    {
        date -u '+%Y-%m-%dT%H:%M:%SZ'
        echo "uptime_s=$(sf_now) boot_id=$SF_BOOT"
        echo "module_version=$(sf_version) worker=$(sf_worker_status)"
        for sf_flag in pause stop no-boot-recovery; do
            if [ -e "$SF_STATE/$sf_flag" ]; then echo "flag_$sf_flag=present"; else echo "flag_$sf_flag=absent"; fi
        done
        echo 'key_health=UNKNOWN_UNVERIFIED; no cryptographic validation performed'
        for sf_name in ro.product.manufacturer ro.product.model ro.product.device ro.build.version.sdk \
            ro.build.version.release sys.boot_completed sys.user.0.ce_available init.svc.vendor.soter \
            init.svc_debug_pid.vendor.soter init.svc.keystore2 init.svc.vendor.qseecomd sys.powerctl; do
            printf '%s=' "$sf_name"
            sf_prop "$sf_name" || echo '[query failed]'
        done
        echo '--- Optional Tencent SDK APK (diagnostic only, not a native HAL prerequisite) ---'
        sf_timed 5 cmd package path --user 0 com.tencent.soter.soterserver 2>&1 || echo '[optional package query failed]'
        sf_timed 5 cmd package list packages -d --user 0 com.tencent.soter.soterserver 2>&1 || echo '[optional disabled-state query failed]'
        echo '--- SELinux mode (read only) ---'
        sf_timed 3 getenforce 2>/dev/null || echo '[getenforce unavailable]'
        echo '--- recent SOTER log messages (best effort, not a health probe) ---'
    } > "$sf_temp"
    if sf_timed 8 logcat -d -b main -b system -b crash -t 1000 -v threadtime > "$SF_STATE/logcat.tmp.$$" 2>/dev/null; then
        sf_awk 'tolower($0) ~ /soter/ {
            if (tolower($0) ~ /pub_key|private.key|certificate|begin .*key|device.?id|signature.*[:=]|challenge.*[:=]|token.*[:=]/)
                print "[SOTER key/certificate/identifier payload redacted]";
            else print
        }' "$SF_STATE/logcat.tmp.$$" | tail -c 65536 >> "$sf_temp"
    else echo '[logcat unavailable or timed out; no conclusion about key validity]' >> "$sf_temp"; fi
    rm -f "$SF_STATE/logcat.tmp.$$"
    mv -f "$sf_temp" "$SF_STATE/evidence-$sf_kind.txt"
)

sf_diagnose() (
    sf_capture current || {
        sf_log 'diagnostics=failed_current_capture; previous archive is not a new export'
        echo 'Diagnostic export failed; any existing archive may be OLD.' >&2
        exit 1
    }
    exec 7>"$SF_STATE/diag.lock" || exit 1
    sf_flock 7 || { echo 'Another diagnostic export is active.'; exit 12; }
    if [ -f "$MODDIR/build-info.json" ]; then
        cp "$MODDIR/build-info.json" "$SF_STATE/build-info.tmp.$$" &&
            mv -f "$SF_STATE/build-info.tmp.$$" "$SF_STATE/build-info.json" || exit 1
    fi
    # No application data, keys, Keybox, keystore files, or full logcat are copied.
    set --
    for sf_name in build-info.json status.json profile.txt budget grace events.log events.log.1 launcher.log launcher.log.1 evidence-before.txt evidence-current.txt; do
        [ -f "$SF_STATE/$sf_name" ] && set -- "$@" "$sf_name"
    done
    [ "$#" -gt 0 ] || exit 1
    sf_timed 15 tar -czf "$SF_STATE/diagnostics.tmp.$$.tar.gz" -C "$SF_STATE" "$@" || {
        rm -f "$SF_STATE/diagnostics.tmp.$$.tar.gz"; exit 1;
    }
    mv -f "$SF_STATE/diagnostics.tmp.$$.tar.gz" "$SF_STATE/soterfix-diagnostics.tar.gz" || exit 1
    echo "Diagnostics: $SF_STATE/soterfix-diagnostics.tar.gz (version=$(sf_version), boot_id=$SF_BOOT; root access; review before sharing)."
)

# One startup cycle for the installed vendor.soter service, without device,
# Android-version or SDK-APK filters. This is not a functional key probe.
# The same persisted budget deduplicates manual/boot requests under repair.lock.
sf_boot_target() {
    [ ! -e "$SF_STATE/no-boot-recovery" ]
}

sf_boot_deadline() {
    IFS=' ' read -r sf_bd_boot sf_bd_grace sf_bd_extra < "$SF_STATE/grace" || return 1
    [ "$sf_bd_boot" = "$SF_BOOT" ] && [ -z "$sf_bd_extra" ] &&
        sf_uint "$sf_bd_grace" && [ "$sf_bd_grace" -ge "$SF_GRACE" ] || return 1
    printf '%s\n' "$((sf_bd_grace - SF_GRACE + SF_BOOT_DELAY))"
}

sf_boot_prepare() {
    SF_BOOT_PENDING=no; SF_BOOT_READY_SINCE=0; SF_BOOT_LAST_REASON=
    sf_boot_target || { sf_log 'boot_cycle=disabled_by_user'; return 0; }
    SF_BOOT_DUE=$(sf_boot_deadline) || { sf_log 'boot_workaround=invalid_schedule; no startup request'; return 0; }
    SF_BOOT_PENDING=yes
    sf_log "boot_workaround=scheduled earliest_uptime=$SF_BOOT_DUE stable_ready_seconds=$SF_BOOT_SETTLE key_health=UNKNOWN_UNVERIFIED"
}

sf_boot_gate() {
    sf_boot_target || return 1
    sf_bg_due=$(sf_boot_deadline) || return 1
    sf_bg_now=$(sf_now) || return 1
    sf_uint "$SF_BOOT_READY_SINCE" && [ "$SF_BOOT_READY_SINCE" -gt 0 ] &&
        [ "$sf_bg_now" -ge "$sf_bg_due" ] &&
        [ "$((sf_bg_now - SF_BOOT_READY_SINCE))" -ge "$SF_BOOT_SETTLE" ]
}

sf_boot_defer() {
    if [ "$SF_BOOT_LAST_REASON" != "$1" ]; then
        sf_log "boot_workaround=deferred reason=$1"
        SF_BOOT_LAST_REASON=$1
    fi
}

sf_boot_tick() {
    SF_NEXT_SLEEP=$SF_POLL
    [ "$SF_BOOT_PENDING" = yes ] || return 0
    SF_NEXT_SLEEP=5
    sf_boot_target || { SF_BOOT_PENDING=no; sf_log 'boot_workaround=disabled'; return 0; }
    sf_budget || { SF_BOOT_PENDING=no; sf_log 'boot_workaround=invalid_budget'; return 0; }
    if [ "$SF_COUNT" -gt 0 ]; then
        SF_BOOT_PENDING=no
        sf_log 'boot_workaround=skipped_prior_request; budget already used this boot'
        return 0
    fi
    sf_bt_now=$(sf_now) || { SF_BOOT_PENDING=no; return 1; }
    if [ "$sf_bt_now" -lt "$SF_BOOT_DUE" ]; then
        sf_bt_left=$((SF_BOOT_DUE - sf_bt_now))
        [ "$sf_bt_left" -ge "$SF_POLL" ] || SF_NEXT_SLEEP=$sf_bt_left
        return 0
    fi
    if ! sf_ready boot; then
        SF_BOOT_READY_SINCE=0
        sf_boot_defer "$SF_REASON"
        return 0
    fi
    sf_bt_state=$(sf_state)
    case "$sf_bt_state" in
        running|stopped) ;;
        *) SF_BOOT_READY_SINCE=0; sf_boot_defer INIT_TRANSITION_OR_UNKNOWN; return 0 ;;
    esac
    if [ "$SF_BOOT_READY_SINCE" = 0 ]; then
        SF_BOOT_READY_SINCE=$sf_bt_now
        sf_boot_defer BOOT_COMPLETED_READY
    fi
    sf_bt_stable=$((sf_bt_now - SF_BOOT_READY_SINCE))
    if [ "$sf_bt_stable" -lt "$SF_BOOT_SETTLE" ]; then
        SF_NEXT_SLEEP=$((SF_BOOT_SETTLE - sf_bt_stable))
        return 0
    fi
    sf_repair boot
    sf_bt_rc=$?
    case "$sf_bt_rc" in 0|1|11|13|14) SF_BOOT_PENDING=no ;; esac
    if sf_budget && [ "$SF_COUNT" -gt 0 ]; then SF_BOOT_PENDING=no; fi
    if [ "$SF_BOOT_PENDING" = yes ]; then SF_NEXT_SLEEP=5; else SF_NEXT_SLEEP=$SF_POLL; fi
}

sf_worker_status() (
    [ -f "$SF_STATE/watch.lock" ] || { echo not_started; exit; }
    exec 9>"$SF_STATE/watch.lock" || { echo unknown; exit; }
    if sf_flock 9; then echo not_running; else echo lock_held; fi
)

sf_launch() {
    # Keep startup errors instead of sending them to /dev/null. Detach from
    # the launcher session; the worker owns watch.lock and remains deduplicated.
    if [ -f "$SF_STATE/launcher.log" ] && [ "$(wc -c < "$SF_STATE/launcher.log")" -ge 131072 ]; then
        mv -f "$SF_STATE/launcher.log" "$SF_STATE/launcher.log.1" || return 1
    fi
    sf_log "launcher=requested version=$(sf_version) worker=$(sf_worker_status)"
    if [ -n "$SF_BB" ] && "$SF_BB" setsid --help >/dev/null 2>&1; then
        "$SF_BB" setsid /system/bin/sh "$MODDIR/soterctl.sh" watch </dev/null >>"$SF_STATE/launcher.log" 2>&1 &
    elif command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh "$MODDIR/soterctl.sh" watch </dev/null >>"$SF_STATE/launcher.log" 2>&1 &
    else
        sf_log 'launcher=setsid_unavailable; using background worker'
        /system/bin/sh "$MODDIR/soterctl.sh" watch </dev/null >>"$SF_STATE/launcher.log" 2>&1 &
    fi
}

sf_watch() (
    exec 9>"$SF_STATE/watch.lock" || exit 1
    sf_flock 9 || exit 0
    trap 'sf_log "monitor=exit rc=$?"' 0
    sf_log "monitor=starting version=$(sf_version) functional_probe=unavailable"
    sf_i=0
    sf_wait_now=$(sf_now) || exit 1
    sf_boot_until=$((sf_wait_now + 600))
    while [ "$(sf_prop sys.boot_completed)" != 1 ]; do
        sf_active || exit 0
        sf_wait_now=$(sf_now) || exit 1
        if [ "$sf_i" -ge 120 ] || [ "$sf_wait_now" -ge "$sf_boot_until" ]; then
            sf_log 'BOOT_WAIT_TIMEOUT; boot-completed hook may retry.'; exit 1
        fi
        sf_sleep 5
        sf_i=$((sf_i + 1))
    done
    sf_set_grace || { sf_log 'GRACE_STATE_ERROR; no automatic recovery.'; exit 1; }
    sf_profile || SF_PROFILE=unknown
    sf_boot_prepare
    sf_last_state=
    while sf_active; do
        sf_boot_tick
        sf_current=$(sf_state)
        if [ "$sf_current" != "$sf_last_state" ]; then
            sf_log "availability=$sf_current profile=$SF_PROFILE key_health=UNKNOWN_UNVERIFIED"
            sf_last_state=$sf_current
        fi
        case "$sf_current" in
            stopped)
                sf_repair auto
                sf_rc=$?
                [ "$sf_rc" != 13 ] || { sf_log 'monitor=circuit_open; no more automatic requests this boot.'; exit 0; }
                sf_sleep 30 ;;
            running|restarting) sf_sleep "$SF_NEXT_SLEEP" ;;
            *) sf_log 'SERVICE_UNAVAILABLE; no automatic recovery.'; exit 0 ;;
        esac
    done
    sf_log 'monitor=stopped module disabled/paused/removed/updated or boot changed'
)
