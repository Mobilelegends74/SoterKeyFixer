"""Run production policy with fake Android commands and real flock/timeout.

Fixtures are injected only by this test harness after sourcing the library.
The installed module has no test mode, arbitrary probe runner or service override.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUSYBOX = os.environ.get('SOTER_TEST_BUSYBOX', '')
MKSH = os.environ.get('SOTER_TEST_MKSH', '')
SHELL = [MKSH] if MKSH else ([BUSYBOX, 'ash'] if BUSYBOX else ['dash'])
BOOT = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='soter-policy-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ('state', 'bin', 'rc', 'module/lib', 'proc/sys/kernel/random'):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        (self.root / 'module/lib/profile.awk').write_bytes((ROOT / 'lib/profile.awk').read_bytes())
        (self.root / 'module/module.prop').write_bytes((ROOT / 'module.prop').read_bytes())
        (self.root / 'proc/sys/kernel/random/boot_id').write_text(BOOT + '\n')
        self.write('clock', '1000\n')
        self.prop('init.svc.vendor.soter', 'running')
        self.prop('init.svc_debug_pid.vendor.soter', '1234')
        self.prop('ro.product.manufacturer', 'OnePlus')
        self.prop('ro.build.version.sdk', '35')
        self.prop('sys.boot_completed', '1')
        self.prop('sys.powerctl', '')
        self.prop('sys.user.0.ce_available', 'true')
        self.prop('init.svc.keystore2', 'running')
        self.prop('init.svc.vendor.qseecomd', 'running')
        self.write('state/grace', BOOT + ' 0\n')
        self.profile('    class hal\n    user system\n')
        self.stub('cmd', '''case "$*" in
activity*) echo RUNNING_UNLOCKED ;;
"package path"*) echo package:/system/app/Soter/Soter.apk ;;
"package list"*) if [ -f "$CASE_ROOT/pkg-disabled" ]; then echo package:com.tencent.soter.soterserver; fi ;;
*) exit 80 ;;
esac
''')
        self.stub('logcat', '''echo "Soter: provider failure status=4"
echo "Soter: pub_key=PRIVATE_FIXTURE_MUST_BE_REDACTED"
''')
        self.stub('setprop', '''echo "$*" >> "$CASE_ROOT/controls"
case "$*" in "ctl.start vendor.soter"|"ctl.restart vendor.soter") ;; *) exit 99 ;; esac
if [ -f "$CASE_ROOT/hold" ]; then sleep 0.3; fi
if [ -f "$CASE_ROOT/deny" ]; then exit 1; fi
if [ ! -f "$CASE_ROOT/ignore" ]; then
 echo running > "$CASE_ROOT/prop.init.svc.vendor.soter"
 echo 5678 > "$CASE_ROOT/prop.init.svc_debug_pid.vendor.soter"
fi
''')
        self.env = dict(os.environ, CASE_ROOT=str(self.root),
                        PATH=str(self.root / 'bin') + ':' + os.environ['PATH'])
        self.prelude = f'''. "{ROOT}/lib/soter.sh"
MODDIR="$CASE_ROOT/module"
SF_STATE="$CASE_ROOT/state"
SF_PROC="$CASE_ROOT/proc"
SF_RC_DIRS="$CASE_ROOT/rc"
SF_BB="{BUSYBOX}"
id() {{ echo 0; }}
sf_prop() {{
 if [ -f "$CASE_ROOT/deny.$1" ]; then return 1; fi
 if [ -f "$CASE_ROOT/prop.$1" ]; then cat "$CASE_ROOT/prop.$1"; fi
}}
sf_now() {{ cat "$CASE_ROOT/clock"; }}
sf_sleep() {{ n=$(sf_now); echo "$((n + $1))" > "$CASE_ROOT/clock"; }}
sf_init || exit 90
'''

    def write(self, name, value=''):
        (self.root / name).write_text(value)

    def prop(self, name, value):
        self.write('prop.' + name, value + '\n')

    def stub(self, name, body):
        p = self.root / 'bin' / name
        p.write_text('#!/bin/sh\n' + body)
        p.chmod(0o755)

    def profile(self, options='', binary='/vendor/bin/hw/vendor.qti.hardware.soter@1.0-service'):
        self.write('rc/soter.rc', f'service vendor.soter {binary}\n' + options)

    def run_shell(self, body, expected=0):
        result = subprocess.run(SHELL + ['-c', self.prelude + body], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def controls(self):
        p = self.root / 'controls'
        return p.read_text().splitlines() if p.exists() else []

    def test_running_is_not_key_failure_and_never_auto_restarted(self):
        self.run_shell('sf_repair auto', 10)
        self.assertEqual(self.controls(), [])

    def test_persistent_stop_confirmed_and_started_once_without_clear(self):
        self.prop('init.svc.vendor.soter', 'stopped')
        self.run_shell('sf_repair auto')
        self.assertEqual(self.controls(), ['ctl.start vendor.soter'])
        status = json.loads((self.root / 'state/status.json').read_text())
        self.assertEqual(status['key_health'], 'UNKNOWN_UNVERIFIED')
        self.assertEqual(status['availability'], 'running')

    def test_manual_restart_observed_by_pid_change(self):
        self.run_shell('sf_repair manual')
        self.assertEqual(self.controls(), ['ctl.restart vendor.soter'])

    def test_transient_stop_is_not_repaired(self):
        self.prop('init.svc.vendor.soter', 'stopped')
        self.run_shell('sf_sleep() { echo running > "$CASE_ROOT/prop.init.svc.vendor.soter"; }; sf_repair auto', 10)
        self.assertEqual(self.controls(), [])

    def test_lazy_service_is_not_auto_started_but_manual_remains(self):
        self.profile('    disabled\n    oneshot\n')
        self.run_shell('sf_repair auto', 11)
        self.assertEqual(self.controls(), [])
        self.run_shell('sf_repair manual')

    def test_critical_onrestart_shared_and_ambiguous_profiles_are_blocked(self):
        for options in ('    critical\n', '    reboot_on_failure reboot\n',
                        '    onrestart restart keystore2\n',
                        '    interface aidl android.hardware.security.keymint.IKeyMintDevice/default\n'):
            with self.subTest(options=options):
                self.profile(options)
                self.run_shell('sf_repair manual', 11)
        self.profile(binary='/vendor/bin/hw/keymint-service-soter')
        self.run_shell('sf_repair manual', 11)
        self.profile()
        self.write('rc/override.rc', (self.root / 'rc/soter.rc').read_text())
        self.run_shell('sf_repair manual', 11)
        self.assertEqual(self.controls(), [])

    def test_unknown_and_restarting_states_do_not_trigger_control(self):
        for value in ('', 'restarting', 'something-unexpected'):
            self.prop('init.svc.vendor.soter', value)
            self.run_shell('sf_repair auto', 10)
        self.assertEqual(self.controls(), [])

    def test_global_soter_property_restart_hooks_are_blocked(self):
        self.profile('    class hal\n')
        with (self.root / 'rc/soter.rc').open('a') as f:
            f.write('on property:init.svc.vendor.soter=stopped\n    restart keystore2\n')
        self.run_shell('sf_repair manual', 11)
        self.assertEqual(self.controls(), [])

    def test_boot_shutdown_grace_locked_tee_defer(self):
        for name, value in [('sys.boot_completed', '0'), ('sys.powerctl', 'reboot'),
                            ('init.svc.keystore2', 'stopped'), ('init.svc.vendor.qseecomd', 'restarting')]:
            original = (self.root / ('prop.' + name)).read_text()
            self.prop(name, value)
            self.run_shell('sf_repair manual', 10)
            self.write('prop.' + name, original)
        self.write('state/grace', BOOT + ' 2000\n')
        self.run_shell('sf_repair manual', 10)
        self.write('state/grace', BOOT + ' 0\n')
        self.prop('sys.user.0.ce_available', 'false')
        self.stub('cmd', 'echo RUNNING_LOCKED\n')
        self.run_shell('sf_repair manual', 10)
        self.prop('sys.user.0.ce_available', 'true')
        self.assertEqual(self.controls(), [])

    def test_failed_properties_do_not_trigger(self):
        self.write('deny.sys.powerctl')
        self.run_shell('sf_repair manual', 10)
        self.assertEqual(self.controls(), [])

    def test_optional_sdk_apk_does_not_gate_native_hal_recovery(self):
        self.write('pkg-disabled')
        self.run_shell('sf_repair manual')
        self.assertEqual(self.controls(), ['ctl.restart vendor.soter'])

    def test_oneplus13r_package_binder_failure_does_not_block_action(self):
        # Real device archive: late_start, unversioned dedicated service binary.
        self.profile('    class late_start\n    user system\n    group system drmrpc\n',
                     binary='/vendor/bin/hw/vendor.qti.hardware.soter-service')
        self.stub('cmd', '''echo 'cmd: Failure calling service package: Failed transaction (2147483646)' >&2
exit 1
''')
        self.run_shell('sf_repair manual')
        self.assertEqual(self.controls(), ['ctl.restart vendor.soter'])
        self.assertIn('Failed transaction (2147483646)', (self.root / 'state/evidence-before.txt').read_text())
        self.assertIn(' 1 1000', (self.root / 'state/budget').read_text())
        status = json.loads((self.root / 'state/status.json').read_text())
        self.assertEqual(status['result'], 'SERVICE_AVAILABLE_KEY_UNVERIFIED')

    def test_missing_sdk_apk_does_not_block_native_hal_auto_start(self):
        self.stub('cmd', 'exit 1\n')
        self.prop('init.svc.vendor.soter', 'stopped')
        self.run_shell('sf_repair auto')
        self.assertEqual(self.controls(), ['ctl.start vendor.soter'])

    def test_android15_numeric_user_unlocked_fallback(self):
        self.prop('sys.user.0.ce_available', '')
        self.stub('cmd', '''case "$*" in
activity*) echo 3 ;;
"package path"*) echo package:/system/app/Soter/Soter.apk ;;
"package list"*) exit 0 ;;
*) exit 80 ;;
esac
''')
        self.run_shell('sf_repair manual')

    def test_cooldown_and_budget_survive_new_processes(self):
        self.run_shell('sf_repair manual')
        self.run_shell('sf_repair manual', 10)
        self.write('clock', '1400\n')
        self.run_shell('sf_repair manual', 1)  # already-same PID; never invent confirmation
        self.write('clock', '2400\n')
        self.run_shell('sf_repair manual', 1)
        self.write('clock', '5000\n')
        self.run_shell('sf_repair manual', 13)
        self.assertEqual(len(self.controls()), 3)

    def test_reboot_resets_valid_old_budget(self):
        self.write('state/budget', 'v1 ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee 3 800\n')
        self.run_shell('sf_repair manual')
        self.assertIn(' 1 1000', (self.root / 'state/budget').read_text())

    def test_reinstall_after_reboot_does_not_inherit_uninstall_stop(self):
        self.write('state/stop', 'ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee\n')
        self.run_shell('sf_repair manual')

    def test_uninstall_stop_blocks_the_same_boot(self):
        self.write('state/stop', BOOT + '\n')
        self.run_shell('sf_repair manual', 10)
        self.assertEqual(self.controls(), [])

    def test_corrupt_and_future_budget_fail_closed(self):
        for content in ('corrupted', f'v1 {BOOT} 1000 10\n', f'v1 {BOOT} 1 9999\n'):
            self.write('state/budget', content)
            self.run_shell('sf_repair manual', 13)
            self.assertEqual((self.root / 'state/budget').read_text(), content)
        self.assertEqual(self.controls(), [])

    def test_denied_control_is_counted_and_not_retried_in_a_loop(self):
        self.write('deny')
        self.run_shell('sf_repair manual', 1)
        self.run_shell('sf_repair manual', 10)
        self.assertEqual(len(self.controls()), 1)

    def test_accepted_request_without_pid_or_state_change_is_unconfirmed(self):
        self.write('ignore')
        self.run_shell('sf_repair manual', 1)
        self.assertIn('REQUEST_UNCONFIRMED', (self.root / 'state/status.json').read_text())

    def test_failed_state_query_is_not_a_restart_transition(self):
        self.write('ignore')
        self.run_shell('''sf_state() {
            n=0
            if [ -f "$CASE_ROOT/state-read-count" ]; then n=$(cat "$CASE_ROOT/state-read-count"); fi
            n=$((n + 1)); echo "$n" > "$CASE_ROOT/state-read-count"
            if [ "$n" = 3 ]; then echo unavailable; else echo running; fi
        }; sf_repair manual''', 1)
        self.assertIn('REQUEST_UNCONFIRMED', (self.root / 'state/status.json').read_text())

    def test_pause_disable_remove_and_update_prevent_requests(self):
        for name in ('state/pause', 'state/stop', 'module/disable', 'module/remove', 'module/update'):
            self.write(name)
            self.run_shell('sf_repair manual', 10)
            (self.root / name).unlink()
        self.assertEqual(self.controls(), [])

    def test_disable_during_confirmation_prevents_request(self):
        self.prop('init.svc.vendor.soter', 'stopped')
        self.run_shell('sf_sleep() { : > "$MODDIR/disable"; }; sf_repair auto', 10)
        self.assertEqual(self.controls(), [])

    def test_disable_during_evidence_capture_prevents_request(self):
        self.run_shell('sf_capture() { : > "$MODDIR/disable"; }; sf_repair manual', 10)
        self.assertEqual(self.controls(), [])

    def test_unknown_platform_and_unavailable_service_properties_are_safe(self):
        self.prop('ro.product.manufacturer', 'OtherVendor')
        self.run_shell('sf_repair manual', 10)
        self.prop('ro.product.manufacturer', 'OnePlus')
        self.write('deny.init.svc.vendor.soter')
        self.run_shell('sf_repair auto', 10)
        self.assertEqual(self.controls(), [])

    def test_symlinked_state_is_rejected(self):
        self.write('protected-keybox-fixture', 'must remain unchanged')
        (self.root / 'state/budget').symlink_to(self.root / 'protected-keybox-fixture')
        self.run_shell('sf_repair manual', 90)
        self.assertEqual((self.root / 'protected-keybox-fixture').read_text(), 'must remain unchanged')
        self.assertEqual(self.controls(), [])

    def test_nonroot_and_missing_lock_tools_fail_closed(self):
        self.run_shell('id() { echo 1000; }; sf_init', 1)
        self.run_shell('SF_BB=; PATH="$CASE_ROOT/bin"; sf_tools', 1)
        self.assertEqual(self.controls(), [])

    def test_healthy_watch_does_not_log_or_repair_each_poll(self):
        self.run_shell('''sf_sleep() {
            tick=$(( ${tick:-0} + 1 ))
            if [ "$tick" = 3 ]; then : > "$SF_STATE/pause"; fi
        }; sf_watch''')
        events = (self.root / 'state/events.log').read_text()
        self.assertEqual(events.count('availability=running'), 1)
        self.assertEqual(self.controls(), [])

    def test_parallel_actions_cannot_overlap(self):
        self.write('hold')
        cmd = SHELL + ['-c', self.prelude + 'sf_repair manual']
        a = subprocess.Popen(cmd, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        b = subprocess.Popen(cmd, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        a.communicate(timeout=10); b.communicate(timeout=10)
        self.assertIn(sorted([a.returncode, b.returncode]), ([0, 12], [0, 10]))
        self.assertEqual(len(self.controls()), 1)

    def test_duplicate_boot_hooks_only_keep_one_watcher(self):
        body = self.prelude + '''sf_sleep() {
            i=0
            while [ ! -f "$CASE_ROOT/release" ] && [ "$i" -lt 40 ]; do
                command sleep 0.05; i=$((i + 1))
            done
            : > "$SF_STATE/pause"
        }; sf_watch'''
        a = subprocess.Popen(SHELL + ['-c', body], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                if (self.root / 'state/events.log').exists():
                    break
                time.sleep(0.01)
            self.run_shell('sf_watch')
        finally:
            self.write('release')
            a.communicate(timeout=5)
        self.assertEqual(a.returncode, 0)
        events = (self.root / 'state/events.log').read_text()
        self.assertEqual(events.count('monitor=starting'), 1)
        self.assertEqual(self.controls(), [])

    def test_diagnostic_export_is_readonly_and_redacts_payload(self):
        self.run_shell('sf_profile; sf_diagnose')
        self.assertTrue((self.root / 'state/soterfix-diagnostics.tar.gz').is_file())
        evidence = (self.root / 'state/evidence-current.txt').read_text()
        self.assertIn('provider failure status=4', evidence)
        self.assertNotIn('PRIVATE_FIXTURE', evidence)
        self.assertEqual(self.controls(), [])

    def test_log_rotation_is_bounded(self):
        self.write('state/events.log', 'x' * 131072)
        self.run_shell('sf_log sample')
        self.assertEqual((self.root / 'state/events.log.1').stat().st_size, 131072)
        self.assertLess((self.root / 'state/events.log').stat().st_size, 1024)

    def test_real_timeout_is_bounded(self):
        started = time.monotonic()
        self.run_shell('sf_timed 1 sleep 4; test "$?" -ne 0')
        self.assertLess(time.monotonic() - started, 3)

    def test_production_payload_has_no_destructive_key_operations(self):
        payload = '\n'.join((ROOT / name).read_text() for name in (
            'lib/soter.sh', 'action.sh', 'service.sh', 'boot-completed.sh', 'soterctl.sh', 'uninstall.sh'))
        for forbidden in ('pm clear', 'resetprop', 'setenforce', 'service call', 'generateAppSecureKey', 'removeAllAuthKey'):
            self.assertNotIn(forbidden, payload)
        self.assertNotIn('setprop ctl.stop', payload)
        self.assertEqual(payload.count('setprop ctl.start vendor.soter'), 1)
        self.assertEqual(payload.count('setprop ctl.restart vendor.soter'), 1)


if __name__ == '__main__':
    unittest.main()
