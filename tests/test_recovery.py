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
case "$*" in "ctl.start vendor.soter"|"ctl.stop vendor.soter") ;; *) exit 99 ;; esac
if [ -f "$CASE_ROOT/hold" ]; then sleep 0.3; fi
if [ -f "$CASE_ROOT/deny" ]; then exit 1; fi
if [ ! -f "$CASE_ROOT/ignore" ]; then
 case "$1" in
 ctl.stop) echo stopped > "$CASE_ROOT/prop.init.svc.vendor.soter" ;;
 ctl.start) echo running > "$CASE_ROOT/prop.init.svc.vendor.soter"
            echo 5678 > "$CASE_ROOT/prop.init.svc_debug_pid.vendor.soter" ;;
 esac
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

    def test_manual_uses_single_stop_pause_start_without_clearing(self):
        self.run_shell('sf_repair manual')
        self.assertEqual(self.controls(), ['ctl.stop vendor.soter', 'ctl.start vendor.soter'])
        self.assertEqual((self.root / 'clock').read_text().strip(), '1003')
        self.assertEqual(json.loads((self.root / 'state/status.json').read_text())['key_health'], 'UNKNOWN_UNVERIFIED')

    def test_boot_uses_identical_cycle_once_without_unlock_or_model_filters(self):
        self.prop('ro.product.manufacturer', 'OtherVendor')
        self.prop('ro.build.version.sdk', '36')
        self.prop('sys.user.0.ce_available', 'false')
        self.prop('init.svc.keystore2', '')
        self.prop('init.svc.vendor.qseecomd', '')
        self.stub('cmd', 'exit 1\n')
        self.write('state/grace', BOOT + ' 1000\n')
        self.run_shell('sf_boot_prepare; sf_boot_tick; sf_boot_tick; sf_boot_prepare; sf_boot_tick')
        self.assertEqual(self.controls(), ['ctl.stop vendor.soter', 'ctl.start vendor.soter'])
        self.assertEqual(json.loads((self.root / 'state/status.json').read_text())['request_mode'], 'boot')

    def test_full_watch_starts_one_cycle_after_boot_completion(self):
        self.run_shell('''sf_sleep() {
 n=$(sf_now); echo "$((n + $1))" > "$CASE_ROOT/clock"
 if [ "$n" -ge 1200 ]; then : > "$SF_STATE/pause"; fi
}; sf_watch''')
        self.assertEqual(self.controls(), ['ctl.stop vendor.soter', 'ctl.start vendor.soter'])

    def test_no_request_before_boot_or_during_shutdown(self):
        self.prop('sys.boot_completed', '0')
        self.run_shell('sf_repair manual', 10)
        self.prop('sys.boot_completed', '1')
        self.prop('sys.powerctl', 'reboot')
        self.run_shell('sf_repair manual', 10)
        self.assertEqual(self.controls(), [])

    def test_only_stopped_service_auto_start_is_allowed(self):
        self.run_shell('sf_repair auto', 10)
        self.prop('init.svc.vendor.soter', 'stopped')
        self.run_shell('sf_repair auto')
        self.assertEqual(self.controls(), ['ctl.start vendor.soter'])

    def test_unknown_or_restarting_service_is_not_stopped(self):
        for state in ('', 'restarting'):
            self.prop('init.svc.vendor.soter', state)
            self.run_shell('sf_repair manual', 10)
        self.assertEqual(self.controls(), [])

    def test_failed_stop_attempts_start_to_restore_availability(self):
        self.write('deny')
        self.run_shell('sf_repair manual', 1)
        self.assertEqual(self.controls(), ['ctl.stop vendor.soter', 'ctl.start vendor.soter'])
        self.run_shell('sf_repair manual', 10)
        self.assertEqual(len(self.controls()), 2)

    def test_stop_not_observed_is_bounded_and_restores_service(self):
        self.write('ignore')
        self.run_shell('sf_repair manual', 1)
        self.assertEqual(self.controls(), ['ctl.stop vendor.soter', 'ctl.start vendor.soter'])
        self.assertLessEqual(int((self.root / 'clock').read_text()), 1010)

    def test_interruption_in_pause_restores_service(self):
        self.run_shell('sf_sleep() { return 1; }; sf_repair manual', 1)
        self.assertEqual(self.controls(), ['ctl.stop vendor.soter', 'ctl.start vendor.soter'])

    def test_manual_not_blocked_by_old_grace_and_has_short_repeat_gap(self):
        self.write('state/grace', BOOT + ' 5000\n')
        self.write('state/budget', f'v1 {BOOT} 1 980\n')
        self.run_shell('sf_repair manual')
        self.run_shell('sf_repair manual', 10)
        self.assertEqual(len(self.controls()), 2)

    def test_shared_three_attempt_cap_survives_new_processes(self):
        self.run_shell('sf_repair manual')
        self.write('clock', '1020\n'); self.run_shell('sf_repair manual', 1)
        self.write('clock', '1060\n'); self.run_shell('sf_repair manual', 1)
        self.write('clock', '1100\n'); self.run_shell('sf_repair manual', 13)
        self.assertEqual(len(self.controls()), 6)

    def test_corrupt_budget_cannot_cause_unbounded_retries(self):
        self.write('state/budget', 'broken\n')
        self.run_shell('sf_repair manual', 13)
        self.assertEqual(self.controls(), [])

    def test_prior_manual_request_cancels_boot_cycle(self):
        self.run_shell('sf_repair manual; sf_set_grace; sf_boot_prepare; sf_boot_tick')
        self.assertEqual(len(self.controls()), 2)

    def test_disable_pause_remove_update_prevent_cycle(self):
        for name in ('state/pause', 'module/disable', 'module/remove', 'module/update'):
            self.write(name); self.run_shell('sf_repair manual', 10)
            (self.root / name).unlink()
        self.assertEqual(self.controls(), [])

    def test_disable_during_capture_prevents_stop(self):
        self.run_shell('sf_capture() { : > "$MODDIR/disable"; }; sf_repair manual', 10)
        self.assertEqual(self.controls(), [])

    def test_parallel_manual_requests_do_not_overlap(self):
        self.write('hold')
        cmd = SHELL + ['-c', self.prelude + 'sf_repair manual']
        a = subprocess.Popen(cmd, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        b = subprocess.Popen(cmd, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        a.communicate(timeout=10); b.communicate(timeout=10)
        self.assertIn(sorted([a.returncode, b.returncode]), ([0, 12], [0, 10]))
        self.assertEqual(len(self.controls()), 2)

    def test_diagnostics_are_readonly_and_redact_key_payload(self):
        self.run_shell('sf_diagnose')
        self.assertTrue((self.root / 'state/soterfix-diagnostics.tar.gz').is_file())
        evidence=(self.root / 'state/evidence-current.txt').read_text()
        self.assertNotIn('PRIVATE_FIXTURE', evidence)
        self.assertEqual(self.controls(), [])

    def test_state_symlink_is_rejected(self):
        self.write('protected', 'original')
        (self.root / 'state/budget').symlink_to(self.root / 'protected')
        self.run_shell('sf_repair manual', 90)
        self.assertEqual((self.root / 'protected').read_text(), 'original')

    def test_log_rotation_remains_bounded(self):
        self.write('state/events.log', 'x' * 131072)
        self.run_shell('sf_log sample')
        self.assertEqual((self.root / 'state/events.log.1').stat().st_size, 131072)

    def test_payload_does_not_clear_data_or_control_other_services(self):
        payload=(ROOT / 'lib/soter.sh').read_text()
        for forbidden in ('pm clear', 'resetprop', 'setenforce', 'service call', 'setprop ctl.restart'):
            self.assertNotIn(forbidden, payload)
        self.assertEqual(payload.count('setprop ctl.stop vendor.soter'), 1)
        self.assertEqual(payload.count('setprop ctl.start vendor.soter'), 1)


if __name__ == '__main__':
    unittest.main()
