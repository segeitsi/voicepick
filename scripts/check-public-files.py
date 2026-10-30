#!/usr/bin/env python3
"""Audit tracked/staged paths before publishing. Never prints file contents."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
records = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root).split(b'\0')
indexed = {}
for record in records:
    if record:
        metadata, name = record.split(b'\t', 1)
        mode, _, stage = metadata.decode().split()
        indexed[Path(name.decode('utf-8'))] = (mode, stage)
paths = list(indexed)
if not paths:
    sys.exit('No tracked files. Stage the intended public sources before this check.')

root_files = {'.gitignore', '.gitattributes', 'README.md', 'CONTRIBUTING.md',
              'CHANGELOG.md', 'LICENSE', 'NOTICE', 'Запустить.command'}
asset_files = {'assets/Info.plist', 'assets/face-mesh/NOTICE.md',
               'assets/face-mesh/face_mesh.py', 'assets/face-mesh/requirements-lock.txt'}
text_roots = {'Sources', 'Tests', 'Tools', 'scripts', '.github', 'docs'}
patterns = {
    'private key': rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'GitHub token': rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})',
    'AWS access key': rb'(?:AKIA|ASIA)[A-Z0-9]{16}',
    'personal home path': rb'/' + rb'Users/[^/\s]+',
    'embedded reference data': rb'"(?:thumbnail|feature)"\s*:\s*"[A-Za-z0-9+/]{200,}={0,2}"',
}
problems = []
total = 0
for relative in paths:
    name = relative.as_posix()
    if not (name in root_files or name in asset_files or relative.parts[0] in text_roots
            or name.startswith('assets/face-mesh/licenses/')):
        problems.append((name, 'path is outside public source allowlist'))
        continue
    personal_report = relative.suffix == '.json' and relative.name.startswith(('reference-bank', 'face-debug'))
    if relative.suffix.lower() in {'.png', '.jpg', '.jpeg', '.heic', '.webp', '.task', '.dmg'} or personal_report:
        problems.append((name, 'image, model, build or personal report'))
        continue
    mode, stage = indexed[relative]
    if mode == '120000' or stage != '0':
        problems.append((name, 'symlink or unmerged index entry'))
        continue
    # Read the index, not the working file: this is exactly what the commit contains.
    data = subprocess.check_output(['git', 'show', ':' + name], cwd=root)
    total += len(data)
    for label, pattern in patterns.items():
        if re.search(pattern, data):
            problems.append((name, label))
    try:
        data.decode('utf-8')
    except UnicodeDecodeError:
        problems.append((name, 'unexpected binary file'))

if problems:
    for name, reason in problems:
        print(f'REJECT: {name}: {reason}', file=sys.stderr)
    sys.exit(1)
print(f'PASS: {len(paths)} public source files, {total:,} bytes; no personal banks, images, builds or detected secrets')
