"""Retire only the obsolete headset ConvNeXt dynamic channel.

The independent legacy classifiers and their weights are kept intact. Runtime
modules and source are backed up before the mount is removed and services restart.
"""
import ast
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

MOUNT = '# Rice HoloLens dynamic recognition: versioned frame channel\nfrom api.dynamic import install_dynamic as _install_rice_dynamic\n_install_rice_dynamic(app, globals())\n'


def retire(source):
    ast.parse(source)
    if MOUNT not in source:
        if 'install_rice_dynamic' in source or 'from api.dynamic' in source:
            raise ValueError('Unrecognized dynamic mount; refusing partial removal')
        return source
    if source.count(MOUNT) != 1:
        raise ValueError('Expected exactly one guarded dynamic mount')
    result = source.replace(MOUNT, '', 1)
    ast.parse(result)
    return result


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def request_status(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


def health_wait():
    for _ in range(100):
        try:
            if request_status('http://127.0.0.1:8002/health') == 200 and request_status('http://127.0.0.1:9013/hololens-app/api/health') == 200:
                return
        except (OSError, TimeoutError):
            pass
        time.sleep(.5)
    raise RuntimeError('Services did not recover health')


def deploy(bundle):
    if os.geteuid() != 0:
        raise PermissionError('Run with sudo')
    bundle = Path(bundle).resolve()
    gateway = bundle / 'server.py'
    source = gateway.read_text(encoding='utf-8')
    ast.parse(source)
    if 'def dynamic_frame' in source or 'def dynamic_health' in source or "VERSION='1.2.0'" not in source:
        raise ValueError('Unexpected replacement gateway')
    upstream = Path('/opt/rice_disease/api/app_v2.py')
    checkpoint = Path('/opt/rice_disease/checkpoints/convnextv2_v2_best.pth')
    expected = '1ae2e8678431a4533aba61f49b085b5c72914e56e1cf78268d709be313f6dd8b'
    if sha(checkpoint) != expected:
        raise ValueError('Unrecognized independent classifier weights')
    old_upstream = upstream.read_text(encoding='utf-8')
    new_upstream = retire(old_upstream)
    current = Path('/opt/rice-hololens-app/current')
    previous = current.resolve(strict=True)
    releases = Path('/opt/rice-hololens-app/releases').resolve(strict=True)
    if previous.parent != releases:
        raise ValueError('Unexpected current release target')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-retire-dynamic'
    backup = Path('/var/lib/rice-hololens-app/backups') / stamp
    backup.mkdir(mode=0o700)
    release = releases / stamp
    release.mkdir(mode=0o755)
    # deploy.sh uses umask027; the service runs as admin and must traverse a
    # root-owned release directory. mkdir(mode=0755) alone would become0750.
    release.chmod(0o755)
    shutil.copy2(upstream, backup / 'app_v2.py')
    shutil.copy2(previous / 'server.py', backup / 'server.py')
    moved = []
    changed_link = False
    try:
        for name in ['patch_upstream.py', 'rice-hololens-app.service', 'nginx.conf']:
            shutil.copy2(previous / name, release / name)
        shutil.copy2(gateway, release / 'server.py')
        shutil.copy2(bundle / 'retire_dynamic.py', release / 'retire_dynamic.py')
        for item in release.iterdir():
            item.chmod(0o644)
        upstream.write_text(new_upstream, encoding='utf-8')
        for old in [Path('/opt/rice_disease/api/dynamic.py'), Path('/opt/rice_disease/api/cam.py'), Path('/opt/rice_disease/configs/dynamic-model.json')]:
            if old.exists():
                target = backup / old.name
                shutil.move(str(old), str(target))
                moved.append((old, target))
        temporary = current.with_name('current-retire-' + str(os.getpid()))
        temporary.symlink_to(release)
        temporary.replace(current)
        changed_link = True
        subprocess.run(['systemctl', 'restart', 'rice-disease.service', 'rice-hololens-app.service'], check=True)
        health_wait()
        urls = ['http://127.0.0.1:8002/dynamic/health', 'http://127.0.0.1:9013/hololens-app/api/dynamic/health', 'https://rice-srt.cn/hololens-app/api/dynamic/health']
        checks = {url: request_status(url) for url in urls}
        if any(status != 404 for status in checks.values()):
            raise RuntimeError('Obsolete dynamic channel remains reachable: ' + json.dumps(checks))
        if sha(checkpoint) != expected:
            raise RuntimeError('Independent classifier weights changed')
        result = {'retired': True, 'release': str(release), 'backup': str(backup), 'previous_release': str(previous),
                  'gateway_sha256': sha(release / 'server.py'), 'upstream_sha256': sha(upstream), 'old_dynamic_routes': checks,
                  'independent_classifier_weights_unchanged': True, 'camera_or_images_used': False}
        (backup / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result))
    except BaseException:
        shutil.copy2(backup / 'app_v2.py', upstream)
        for original, saved in moved:
            if saved.exists():
                shutil.copy2(saved, original)
        if changed_link:
            temporary = current.with_name('current-rollback-' + str(os.getpid()))
            temporary.symlink_to(previous)
            temporary.replace(current)
        subprocess.run(['systemctl', 'restart', 'rice-disease.service', 'rice-hololens-app.service'], check=False)
        raise


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Expected reviewed bundle directory')
    deploy(sys.argv[1])
