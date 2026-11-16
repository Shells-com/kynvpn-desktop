#!/usr/bin/env python3
# Install official Qt binaries from download.qt.io, without the online
# installer (which needs a Qt account) or aqtinstall (which doesn't handle the
# repository layout used since Qt 6.12).
#
#   install-qt-official.py <host> <version> <arch> <output dir> [module ...]
#
#   host:    windows_x86, windows_arm64, linux_x64, linux_arm64, mac_x64
#   version: e.g. 6.12.0
#   arch:    package suffix, e.g. win64_msvc2022_64, win64_msvc2022_arm64
#   module:  add-on modules besides the essentials, e.g. qtimageformats
#   --debug-info=qtbase,qtdeclarative: also install the debug symbols of
#            these repositories
#
# Qt ends up in <output dir>/<version>/<arch without the "win64_" prefix>
# (e.g. C:/Qt/6.12.0/msvc2022_64), the same layout as the official installer.
#
# Every archive is checked against the SHA-256 published on download.qt.io
# before it is extracted (archives may be served by other mirrors).
#
# Uses only the Python standard library.  Extraction needs 7-Zip ("7z" in PATH,
# or the default install location on Windows).

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

BASE = 'https://download.qt.io/online/qtsdkrepository'
# Archives of the essentials package that aren't needed to build
SKIP_ARCHIVES = ('qtdoc-',)
BIN_ARCHIVES = ('d3dcompiler_47-', 'opengl32sw-')


def fetch(url, attempts=5):
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                return response.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise
            error = e
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            error = e
        if attempt == attempts:
            raise RuntimeError(f'{url}: {error}')
        print(f'  retrying {url} ({error})', flush=True)
        time.sleep(10 * attempt)


def expected_sha256(url):
    # "<hash>  <file name>"
    return fetch(url + '.sha256').decode().split()[0].lower()


def find_repository(host, version, arch):
    """Return (repository URL, Updates.xml content)."""
    ver = version.replace('.', '')
    toolchain = arch.split('_', 1)[1] if arch.startswith('win64_') else arch
    candidates = [
        # Qt 6.12+: one repository per toolchain
        f'{BASE}/{host}/desktop/qt6_{ver}/qt6_{ver}_{toolchain}',
        # Earlier releases (and some hosts): one repository per version
        f'{BASE}/{host}/desktop/qt6_{ver}/qt6_{ver}',
    ]
    for repo in candidates:
        try:
            updates = fetch(f'{repo}/Updates.xml')
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue
            raise
        digest = hashlib.sha256(updates).hexdigest()
        if digest != expected_sha256(f'{repo}/Updates.xml'):
            raise RuntimeError(f'{repo}/Updates.xml: checksum mismatch')
        root = ET.fromstring(updates)
        names = {p.findtext('Name') for p in root.findall('PackageUpdate')}
        if f'qt.qt6.{ver}.{arch}' in names:
            return repo, root
    raise RuntimeError(f'Qt {version} {arch} not found for host {host}')


def select_packages(root, version, arch, modules):
    ver = version.replace('.', '')
    wanted = {f'qt.qt6.{ver}.{arch}'}
    for m in modules:
        wanted.add(f'qt.qt6.{ver}.addons.{m}.{arch}')
        wanted.add(f'qt.qt6.{ver}.{m}.{arch}')  # older naming
    packages = [p for p in root.findall('PackageUpdate') if p.findtext('Name') in wanted]
    found = {p.findtext('Name') for p in packages}
    for m in modules:
        if not ({f'qt.qt6.{ver}.addons.{m}.{arch}', f'qt.qt6.{ver}.{m}.{arch}'} & found):
            raise RuntimeError(f'Module {m} not available for {arch}')
    return packages


def seven_zip():
    for candidate in ('7z', '7za', 'C:/Program Files/7-Zip/7z.exe'):
        path = shutil.which(candidate) or (candidate if os.path.isfile(candidate) else None)
        if path:
            return path
    raise RuntimeError('7-Zip not found')


def main():
    args = sys.argv[1:]
    # --debug-info=<repo>,<repo>: also install the debug symbols (e.g. PDBs)
    # of these Qt repositories (e.g. qtbase,qtdeclarative)
    debug_repos = []
    for a in list(args):
        if a.startswith('--debug-info='):
            debug_repos = [r for r in a.split('=', 1)[1].split(',') if r]
            args.remove(a)
    if len(args) < 4:
        print('usage: install-qt-official.py [--debug-info=<repo>,...] <host> <version> <arch> <dir> [module ...]')
        sys.exit(2)
    host, version, arch, out_dir = args[:4]
    modules = args[4:]

    repo, root = find_repository(host, version, arch)
    print(f'Repository: {repo}', flush=True)
    target = os.path.join(out_dir, version, arch[len('win64_'):] if arch.startswith('win64_') else arch)
    os.makedirs(target, exist_ok=True)
    sevenzip = seven_zip()

    with tempfile.TemporaryDirectory() as tmp:
        packages = select_packages(root, version, arch, modules)
        if debug_repos:
            debug_name = f'qt.qt6.{version.replace(".", "")}.debug_info.{arch}'
            packages += [p for p in root.findall('PackageUpdate') if p.findtext('Name') == debug_name]
        for package in packages:
            name = package.findtext('Name')
            pkg_version = package.findtext('Version')
            archives = [a.strip() for a in (package.findtext('DownloadableArchives') or '').split(',') if a.strip()]
            if '.debug_info.' in name:
                archives = [a for a in archives if a.startswith(tuple(f'{r}-' for r in debug_repos))]
                if not archives:
                    raise RuntimeError(f'No debug symbols found for {debug_repos}')
            for archive in archives:
                if archive.startswith(SKIP_ARCHIVES):
                    continue
                url = f'{repo}/{name}/{pkg_version}{archive}'
                print(f'{name}: {archive}', flush=True)
                data = fetch(url)
                if hashlib.sha256(data).hexdigest() != expected_sha256(url):
                    raise RuntimeError(f'{url}: checksum mismatch')
                path = os.path.join(tmp, archive)
                with open(path, 'wb') as f:
                    f.write(data)
                # These archives hold bare DLLs that the official installer
                # puts in bin/ (where windeployqt looks for them)
                dest = os.path.join(target, 'bin') if archive.startswith(BIN_ARCHIVES) else target
                subprocess.run([sevenzip, 'x', '-y', '-bd', '-bso0', f'-o{dest}', path], check=True)
                os.remove(path)

    print(f'Installed Qt {version} {arch} to {target}')


if __name__ == '__main__':
    main()
