#!/usr/bin/env python3
"""Signs a release: writes update.json, SHA256SUMS and SHA256SUMS.sig.

Usage: sign-release.py <release dir> <version.txt>... --repo <owner/repo>
           --tag <tag> --key <Ed25519 private key PEM>

<release dir> holds the installers (kyn-*.exe, kyn-*.zip, kyn-*.run).  The
version.txt files come from each platform build (first line: the version
string the daemon compares, e.g. 3.6.0+01234); they must all agree.

- SHA256SUMS: sha256sum format, for people verifying a download, with
  SHA256SUMS.sig its raw Ed25519 signature:
      openssl pkeyutl -verify -pubin -inkey kynvpn-release.pub -rawin \\
          -in SHA256SUMS -sigfile SHA256SUMS.sig
- update.json: the update metadata the client polls through
  https://github.com/<repo>/releases/latest/download/update.json, with its
  base64 Ed25519 signature appended after a blank line (the format
  JsonRefresher verifies).  For each platform: version, download URL and the
  installer's SHA-256, which the daemon checks after downloading.

Needs openssl (3.x) in PATH.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

# Update platform name (UpdateChannel::platformName) -> installer file name
PLATFORMS = {
    'windows_x64': re.compile(r'^kyn-windows-x64-\d.*\.exe$'),
    'windows_arm64': re.compile(r'^kyn-windows-arm64-\d.*\.exe$'),
    'mac': re.compile(r'^kyn-macos-\d.*\.zip$'),
    'linux_x64': re.compile(r'^kyn-linux-\d.*\.run$'),
    'linux_arm64': re.compile(r'^kyn-linux-arm64-\d.*\.run$'),
}
# Key holding the platforms (BRAND_UPDATE_JSON_KEY_NAME)
UPDATE_JSON_KEY = 'latest_version_kyn'


def sign(key, data):
    """Raw Ed25519 signature of data"""
    with tempfile.TemporaryDirectory() as tmp:
        data_path = os.path.join(tmp, 'data')
        sig_path = os.path.join(tmp, 'sig')
        with open(data_path, 'wb') as f:
            f.write(data)
        subprocess.run(['openssl', 'pkeyutl', '-sign', '-inkey', key, '-rawin',
                        '-in', data_path, '-out', sig_path], check=True)
        with open(sig_path, 'rb') as f:
            sig = f.read()
    if len(sig) != 64:
        sys.exit(f'Unexpected signature length {len(sig)} (is the key Ed25519?)')
    return sig


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('release_dir')
    parser.add_argument('version_files', nargs='+')
    parser.add_argument('--repo', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--key', required=True)
    args = parser.parse_args()

    versions = set()
    for path in args.version_files:
        with open(path, encoding='utf-8') as f:
            versions.add(f.readline().strip())
    if len(versions) != 1 or '' in versions:
        sys.exit(f'The platform builds have different versions: {sorted(versions)}')
    version = versions.pop()
    print(f'Version: {version}')

    files = sorted(f for f in os.listdir(args.release_dir)
                   if os.path.isfile(os.path.join(args.release_dir, f)) and
                   f not in ('SHA256SUMS', 'SHA256SUMS.sig', 'update.json'))
    hashes = {}
    for name in files:
        with open(os.path.join(args.release_dir, name), 'rb') as f:
            hashes[name] = hashlib.file_digest(f, 'sha256').hexdigest()

    platforms = {}
    for platform, pattern in PLATFORMS.items():
        matches = [f for f in files if pattern.match(f)]
        if len(matches) != 1:
            sys.exit(f'Expected one installer for {platform}, found {matches}')
        name = matches[0]
        platforms[platform] = {
            'version': version,
            'download': f'https://github.com/{args.repo}/releases/download/{args.tag}/{name}',
            'sha256': hashes[name],
        }
        print(f'{platform}: {name} {hashes[name]}')
    unused = set(files) - {p['download'].rsplit('/', 1)[1] for p in platforms.values()}
    if unused:
        sys.exit(f'Files that are no installer for any platform: {sorted(unused)}')

    sums = ''.join(f'{hashes[name]}  {name}\n' for name in files).encode()
    with open(os.path.join(args.release_dir, 'SHA256SUMS'), 'wb') as f:
        f.write(sums)
    with open(os.path.join(args.release_dir, 'SHA256SUMS.sig'), 'wb') as f:
        f.write(sign(args.key, sums))

    # The signature covers the JSON up to its closing brace
    manifest = json.dumps({UPDATE_JSON_KEY: platforms}, indent=2, sort_keys=True).encode()
    signature = base64.b64encode(sign(args.key, manifest))
    with open(os.path.join(args.release_dir, 'update.json'), 'wb') as f:
        f.write(manifest + b'\n\n' + signature + b'\n')


if __name__ == '__main__':
    main()
