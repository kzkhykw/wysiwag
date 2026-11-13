#!/usr/bin/env python3
"""Scan source and build bytes; emit paths only, never a matched secret value."""
import pathlib, re, sys
root = pathlib.Path(__file__).resolve().parents[1]
patterns = [re.compile(rb'(?:sk-|ghp_|gho_|github_pat_|ntn_|secret_)[A-Za-z0-9_-]{24,}'),
            re.compile(rb'ya29\.[A-Za-z0-9_-]{30,}'),
            re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')]
failures=[]; count=0
for directory in ['Sources','Tests','scripts','docs','.github','.build','dist']:
    base=root/directory
    if not base.exists(): continue
    for path in base.rglob('*'):
        if not path.is_file() or path.is_symlink() or path.suffix.lower() in {'.png','.gif','.mp4','.jpg'}: continue
        try:
            with path.open('rb') as stream:
                overlap=b''
                while chunk:=stream.read(1024*1024):
                    data=overlap+chunk
                    if any(pattern.search(data) for pattern in patterns):
                        failures.append(str(path.relative_to(root))); break
                    overlap=data[-512:]
            count+=1
        except OSError: failures.append(str(path.relative_to(root)))
for name in ['README.md','README.ja.md','Package.swift']:
    path=root/name
    if path.exists() and any(p.search(path.read_bytes()) for p in patterns): failures.append(name)
if failures:
    print('Secret scan failed in: ' + ', '.join(sorted(set(failures))))
    sys.exit(1)
print(f'PASS: no key-like strings in {count} source/build files')
