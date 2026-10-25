#!/usr/bin/env python3
"""Build a reproducible, explicitly allowlisted KernelSU module ZIP."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent
PAYLOAD = [
    'module.prop', 'action.sh', 'service.sh', 'boot-completed.sh',
    'customize.sh', 'uninstall.sh', 'soterctl.sh', 'lib/soter.sh',
    'lib/profile.awk', 'README.md', 'docs/technical-report.md', 'LICENSE', 'banner.png',
    'META-INF/com/google/android/update-binary',
    'META-INF/com/google/android/updater-script',
]
EXECUTABLE = {'action.sh', 'service.sh', 'boot-completed.sh', 'uninstall.sh',
              'soterctl.sh', 'META-INF/com/google/android/update-binary'}


def build():
    output = ROOT / 'dist'
    output.mkdir(exist_ok=True)
    archive = output / 'SoterKeyFixer-1.4-TEST3.zip'
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if os.environ.get('GITHUB_SHA'):
        assert os.environ['GITHUB_SHA'] == revision, 'Checkout differs from workflow source'
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True))
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        assert not dirty, 'Refusing to package modified CI checkout'
    properties = dict(line.split('=', 1) for line in (ROOT / 'module.prop').read_text().splitlines() if '=' in line)
    build_info = dict(version=properties['version'], version_code=int(properties['versionCode']), source_commit=revision, working_tree_dirty=dirty,
                      functional_key_validation=False,
                      upstream_base='b029459e4fd50bcbbf87946fe63fd2c83e1e79bb')
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name in PAYLOAD:
            path = ROOT / name
            assert path.is_file() and not path.is_symlink(), name
            mode = 0o755 if name in EXECUTABLE else 0o644
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 25, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, path.read_bytes(), compresslevel=9)
        info = zipfile.ZipInfo('build-info.json', date_time=(2026, 10, 25, 0, 0, 0))
        info.create_system = 3
        info.external_attr = (stat.S_IFREG | 0o644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, json.dumps(build_info, indent=2) + '\n', compresslevel=9)
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert set(z.namelist()) == set(PAYLOAD) | {'build-info.json'}
        prop = z.read('module.prop').decode()
        assert 'id=SoterFix\n' in prop and 'versionCode=16\n' in prop and 'version=1.4-test3\n' in prop
        for name in EXECUTABLE:
            assert (z.getinfo(name).external_attr >> 16) & 0o777 == 0o755
        assert 'post-fs-data.sh' not in z.namelist()
        assert z.read('META-INF/com/google/android/updater-script').strip() == b'#MAGISK'
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / (archive.name + '.sha256')).write_text(digest + '  ' + archive.name + '\n')
    print(archive)
    print('SHA256:', digest)
    return archive


if __name__ == '__main__':
    build()
