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
SF_GRACE=90

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
    for sf_file in budget grace status.json events.log events.log.1 log.lock repair.lock watch.lock diag.lock pause stop; do
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

sf_platform() {
    sf_maker=$(sf_prop ro.product.manufacturer | tr '[:upper:]' '[:lower:]')
    [ "$sf_maker" = oneplus ] && [ "$(sf_prop ro.build.version.sdk)" = 35 ]
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
    sf_platform || { SF_REASON=UNSUPPORTED_PLATFORM; return 1; }
    [ "$(sf_prop sys.boot_completed)" = 1 ] || { SF_REASON=BOOT_PENDING; return 1; }
    sf_power=$(sf_prop sys.powerctl) || { SF_REASON=PROPERTY_QUERY_FAILED; return 1; }
    [ -z "$sf_power" ] || { SF_REASON=SHUTDOWN_PENDING; return 1; }
    sf_time=$(sf_now) || { SF_REASON=CLOCK_UNAVAILABLE; return 1; }
    if ! IFS=' ' read -r sf_graceboot sf_deadline sf_extra < "$SF_STATE/grace" 2>/dev/null ||
        [ "$sf_graceboot" != "$SF_BOOT" ] || ! sf_uint "$sf_deadline" ||
        [ -n "$sf_extra" ] || [ "$sf_time" -lt "$sf_deadline" ]; then
        SF_REASON=BOOT_GRACE; return 1
    fi
    sf_unlocked=$(sf_prop sys.user.0.ce_available)
    if [ "$sf_unlocked" != true ]; then
        sf_user=$(sf_timed 5 cmd activity get-started-user-state 0 2>/dev/null) || sf_user=
        # Android 15 ActivityManager shell prints UserState's numeric value 3.
        case "$sf_user" in 3|RUNNING_UNLOCKED) ;; *) SF_REASON=USER_LOCKED_OR_UNKNOWN; return 1 ;; esac
    fi
    [ "$(sf_prop init.svc.keystore2)" = running ] || { SF_REASON=KEYSTORE_NOT_READY; return 1; }
    sf_qsee=$(sf_prop init.svc.vendor.qseecomd) || { SF_REASON=PROPERTY_QUERY_FAILED; return 1; }
    case "$sf_qsee" in ''|running) ;; *) SF_REASON=TEE_NOT_READY; return 1 ;; esac
    # The native HAL is independent of Tencent's optional Android SDK server.
    # APK absence/disable/query failure is diagnostic information, not a HAL
    # recovery prerequisite. Never enable, clear or otherwise change the APK.
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
    printf '{"scope":"last_recovery_observation","boot_id":"%s","uptime_s":"%s","result":"%s","profile":"%s","service":"vendor.soter","availability":"%s","key_health":"UNKNOWN_UNVERIFIED","functional_probe":"unavailable"}\n' \
        "$SF_BOOT" "$(sf_now)" "$sf_result" "$SF_PROFILE" "$sf_available" > "$SF_STATE/status.tmp.$$" &&
        mv -f "$SF_STATE/status.tmp.$$" "$SF_STATE/status.json"
    sf_log "result=$sf_result availability=$sf_available key_health=UNKNOWN_UNVERIFIED"
    printf '%s; service=%s; key health is NOT verified.\n' "$sf_result" "$sf_available"
}

sf_control() {
    # Deliberately literal: no configurable target and no generic service runner.
    case "$1" in
        auto) sf_timed 5 setprop ctl.start vendor.soter ;;
        manual) sf_timed 5 setprop ctl.restart vendor.soter ;;
        *) return 1 ;;
    esac
}

sf_repair() (
    sf_mode=$1
    case "$sf_mode" in auto|manual) ;; *) exit 2 ;; esac
    exec 8>"$SF_STATE/repair.lock" || exit 1
    sf_flock 8 || { echo 'Another recovery is active.'; exit 12; }
    sf_ready || { sf_report "$SF_REASON"; exit 10; }
    sf_profile || { sf_report PROFILE_READ_FAILED; exit 10; }
    case "$SF_PROFILE:$sf_mode" in
        persistent:*|lazy:manual) ;;
        *) sf_report PROFILE_NOT_SAFE_FOR_THIS_OPERATION; exit 11 ;;
    esac
    sf_before=$(sf_state)
    case "$sf_before:$sf_mode" in
        stopped:auto)
            sf_i=0
            while [ "$sf_i" -lt 2 ]; do
                sf_sleep 5
                sf_active && [ "$(sf_state)" = stopped ] || { sf_report TRANSIENT_STOP_NO_ACTION; exit 10; }
                sf_i=$((sf_i + 1))
            done ;;
        running:manual|stopped:manual) ;;
        *) sf_report NO_CONFIRMED_RECOVERABLE_FAILURE; exit 10 ;;
    esac
    sf_budget || { sf_report INVALID_BUDGET_NO_ACTION; exit 13; }
    [ "$SF_COUNT" -lt "$SF_MAX_ATTEMPTS" ] || { sf_report CIRCUIT_OPEN_UNTIL_REBOOT; exit 13; }
    sf_time=$(sf_now) || exit 1
    case "$SF_COUNT" in 0) sf_wait=0 ;; 1) sf_wait=300 ;; *) sf_wait=900 ;; esac
    if [ "$SF_COUNT" -gt 0 ] && [ "$((sf_time - SF_LAST))" -lt "$sf_wait" ]; then
        sf_report COOLDOWN_NO_ACTION; exit 10
    fi
    # Recheck readiness immediately before the only mutating command.
    sf_ready || { sf_report "$SF_REASON"; exit 10; }
    sf_capture before || sf_log 'Evidence capture unavailable; availability recovery is still bounded.'
    sf_ready || { sf_report "$SF_REASON"; exit 10; }
    sf_latest=$(sf_state)
    case "$sf_mode:$sf_latest" in
        auto:stopped|manual:running|manual:stopped) sf_before=$sf_latest ;;
        *) sf_report TRANSIENT_STOP_NO_ACTION; exit 10 ;;
    esac
    sf_previous_pid=$(sf_pid) || sf_previous_pid=
    SF_COUNT=$((SF_COUNT + 1))
    printf 'v1 %s %s %s\n' "$SF_BOOT" "$SF_COUNT" "$(sf_now)" > "$SF_STATE/budget.tmp.$$" &&
        mv -f "$SF_STATE/budget.tmp.$$" "$SF_STATE/budget" || exit 1
    sf_log "request=$sf_mode before=$sf_before attempt=$SF_COUNT/3 profile=$SF_PROFILE"
    sf_active || { sf_report DISABLED_BEFORE_REQUEST; exit 10; }
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
    sf_capture current || sf_log 'Current evidence capture skipped.'
    exec 7>"$SF_STATE/diag.lock" || exit 1
    sf_flock 7 || { echo 'Another diagnostic export is active.'; exit 12; }
    if [ -f "$MODDIR/build-info.json" ]; then
        cp "$MODDIR/build-info.json" "$SF_STATE/build-info.tmp.$$" &&
            mv -f "$SF_STATE/build-info.tmp.$$" "$SF_STATE/build-info.json" || exit 1
    fi
    # No application data, keys, Keybox, keystore files, or full logcat are copied.
    set --
    for sf_name in build-info.json status.json profile.txt budget grace events.log events.log.1 evidence-before.txt evidence-current.txt; do
        [ -f "$SF_STATE/$sf_name" ] && set -- "$@" "$sf_name"
    done
    [ "$#" -gt 0 ] || exit 1
    sf_timed 15 tar -czf "$SF_STATE/diagnostics.tmp.$$.tar.gz" -C "$SF_STATE" "$@" || {
        rm -f "$SF_STATE/diagnostics.tmp.$$.tar.gz"; exit 1;
    }
    mv -f "$SF_STATE/diagnostics.tmp.$$.tar.gz" "$SF_STATE/soterfix-diagnostics.tar.gz" || exit 1
    echo "Diagnostics: $SF_STATE/soterfix-diagnostics.tar.gz (root access; review before sharing)."
)

sf_watch() (
    exec 9>"$SF_STATE/watch.lock" || exit 1
    sf_flock 9 || exit 0
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
    sf_profile || exit 1
    sf_platform && [ "$SF_PROFILE" = persistent ] || {
        sf_report MONITOR_READ_ONLY_UNSUPPORTED_PROFILE
        exit 0
    }
    sf_last_state=
    while sf_active; do
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
            running|restarting) sf_sleep "$SF_POLL" ;;
            *) sf_log 'SERVICE_UNAVAILABLE; no automatic recovery.'; exit 0 ;;
        esac
    done
    sf_log 'monitor=stopped module disabled/paused/removed/updated or boot changed'
)
