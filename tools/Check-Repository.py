"""Check the Git index or HEAD without opening local credential/state files."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_PARTS = {'.state', '.tools', 'node_modules', '__pycache__', '.cache'}
LOCAL_ONLY_ROOTS = {'reports', 'device-settings'}
WALL_CLOCK = re.compile(rb'20\d{2}-\d{2}-\d{2}[T ]\d{2}:\d{2}|(?<![\w:])[0-2]?\d:[0-5]\d(?![\w:])')
PERSONAL_PATH = re.compile(rb'(?i)[A-Z]:[/\\]Users[/\\](?!Default|Public)[^/\\\s\"\x27]+')
FORBIDDEN_SUFFIXES = {
    '.clixml', '.pfx', '.p12', '.pem', '.key', '.cer', '.exe', '.dll',
    '.lib', '.msi', '.cab', '.vhd', '.appx', '.appxbundle', '.ppkg',
    '.zip', '.whl', '.tgz', '.pyc', '.obj', '.o', '.log', '.pid', '.tmp',
}
SIGNATURES = {
    'private_key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'github_token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b'),
    'aws_access_key': re.compile(rb'\bAKIA[A-Z0-9]{16}\b'),
    'basic_credential': re.compile(rb'(?i)Authorization[\x20\t]*[:=][\x20\t]*[\"\x27]?Basic[\x20\t]+[A-Za-z0-9+/]{24,}={0,2}'),
    'url_credential': re.compile(rb'https?://[^/\s:@]{1,80}:[^/\s@]{4,}@'),
}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--head', action='store_true', help='Check committed HEAD instead of the index.')
    args = parser.parse_args()
    if args.head:
        records = git('ls-tree', '-rz', '--full-tree', 'HEAD')
    else:
        records = git('ls-files', '-s', '-z')
    issues, count, total = [], 0, 0
    for record in records.split(b'\0'):
        if not record:
            continue
        meta, raw_path = record.split(b'\t', 1)
        if args.head:
            mode, _, oid = meta.split()
        else:
            mode, oid, _ = meta.split()
        path = raw_path.decode('utf-8')
        parts = PurePosixPath(path).parts
        lower = path.lower()
        reasons = []
        if FORBIDDEN_PARTS.intersection(parts) or lower.startswith('runtime/powershell/'):
            reasons.append('local_state_or_dependency')
        if parts[0] in LOCAL_ONLY_ROOTS or path in {'AGENTS.md', 'config.json', 'tools/Verify-Archive.py'} or lower.startswith('docs/evidence/'):
            reasons.append('local_operation_archive')
        if PurePosixPath(lower).suffix in FORBIDDEN_SUFFIXES or lower.endswith('.tar.gz'):
            reasons.append('credential_or_generated_payload')
        if parts[-1] == 'session.json' or parts[-1].startswith('.env') and parts[-1] != '.env.example':
            reasons.append('credential_configuration')
        if mode not in {b'100644', b'100755'}:
            reasons.append('unexpected_git_object_mode')
        data = git('cat-file', 'blob', oid.decode('ascii'))
        if PurePosixPath(lower).suffix in {'.md', '.json', '.txt', '.yml', '.yaml'} and WALL_CLOCK.search(data):
            reasons.append('wall_clock_in_team_document')
        if PERSONAL_PATH.search(data):
            reasons.append('personal_machine_path')
        if len(data) > 5 * 1024 * 1024:
            reasons.append('file_larger_than_5_MiB')
        # Match literal credentials only. Regex source and test placeholders do
        # not contain real signatures, so they remain reviewable in the repo.
        for name, pattern in SIGNATURES.items():
            matches = list(pattern.finditer(data))
            if name == 'url_credential':
                matches = [match for match in matches
                           if match.group(0) != b'https://username:password@']
            if matches:
                reasons.append(name)
        if reasons:
            issues.append({'path': path, 'reasons': reasons})
        count += 1
        total += len(data)
    print(json.dumps({'ok': not issues, 'scope': 'HEAD' if args.head else 'index',
                      'files': count, 'bytes': total, 'issues': issues}, ensure_ascii=True))
    return 1 if issues else 0


if __name__ == '__main__':
    sys.exit(main())
