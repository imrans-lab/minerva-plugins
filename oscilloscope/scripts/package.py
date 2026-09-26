#!/usr/bin/env python3
"""Build a self-contained marketplace archive from pinned upstream sources.
Requires Go, a C toolchain, pkg-config, autoconf/automake/libtool, make and SDCC.
No downloaded executable or generated firmware is committed to this repository.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build'
FIRMWARE_REV = 'e65d52b0f2536e56eaadbb555e5d7b756409c36e'
USB_REV = '87a55632db62c9bdc58cd31d3ccfa673f1bb017f'


def run(argv, cwd=ROOT, env=None):
    subprocess.run([str(x) for x in argv], cwd=cwd, env=env, check=True)


def source(name, url, revision):
    path = BUILD / name
    if not path.exists():
        run(['git', 'clone', '--no-checkout', url, path])
    run(['git', 'checkout', '--detach', revision], cwd=path)
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=path, text=True).strip()
    if actual != revision:
        raise RuntimeError('upstream revision mismatch')
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--target', choices=['macos-universal', 'linux-x86_64'], required=True)
    args = parser.parse_args()
    mac = args.target == 'macos-universal'
    if mac != (platform.system() == 'Darwin'):
        raise RuntimeError('Build on the target operating system')
    BUILD.mkdir(exist_ok=True)
    fw = source('firmware-source', 'https://github.com/Ho-Ro/Hantek6022API.git', FIRMWARE_REV)
    usb = source('libusb-source', 'https://github.com/libusb/libusb.git', USB_REV)
    run(['make', 'fw_DSO6022BE'], cwd=fw)
    if not (usb / 'configure').exists():
        run(['./bootstrap.sh'], cwd=usb)
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    package = BUILD / ('package-' + args.target)
    if package.exists():
        shutil.rmtree(package)
    (package / 'lib').mkdir(parents=True)
    (package / 'firmware').mkdir()
    (package / 'sources').mkdir()
    (package / 'licenses').mkdir()
    arches = [('arm64', 'arm64'), ('amd64', 'x86_64')] if mac else [('amd64', 'x86_64')]
    bins, libs = [], []
    for goarch, arch in arches:
        work = BUILD / ('usb-' + args.target + '-' + arch)
        prefix = work / 'install'
        work.mkdir(exist_ok=True)
        env = os.environ.copy()
        if mac:
            env.update(CFLAGS=f'-O2 -arch {arch} -mmacosx-version-min=13.0',
                       LDFLAGS=f'-arch {arch} -mmacosx-version-min=13.0',
                       ac_cv_func_pipe2='no')
        # Recent macOS SDKs weak-link pipe2 although the running OS may lack it.
        # Force libusb's portable pipe fallback for our macOS 13+ package.
        cmd = [usb / 'configure', '--prefix=' + str(prefix), '--disable-static']
        if mac:
            cmd.append('--host=' + ('aarch64' if arch == 'arm64' else 'x86_64') + '-apple-darwin')
        else:
            cmd += ['--disable-udev']
        run(cmd, cwd=work, env=env)
        run(['make', '-j4'], cwd=work, env=env)
        run(['make', 'install'], cwd=work, env=env)
        goenv = os.environ.copy()
        goenv.update(GOWORK='off', CGO_ENABLED='1', GOOS='darwin' if mac else 'linux', GOARCH=goarch,
                     PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'))
        if mac:
            goenv['CGO_CFLAGS'] = f'-arch {arch} -mmacosx-version-min=13.0'
            goenv['CGO_LDFLAGS'] = f'-arch {arch} -mmacosx-version-min=13.0'
        else:
            goenv['CGO_LDFLAGS'] = '-Wl,-rpath,$ORIGIN/lib'
        binary = BUILD / ('oscilloscope-' + args.target + '-' + arch)
        run(['go', 'build', '-trimpath', '-o', binary, '.'], env=goenv)
        lib = prefix / ('lib/libusb-1.0.0.dylib' if mac else 'lib/libusb-1.0.so.0')
        if mac:
            old = str(prefix / 'lib/libusb-1.0.0.dylib')
            run(['install_name_tool', '-change', old, '@executable_path/lib/libusb-1.0.0.dylib', binary])
        bins.append(binary)
        libs.append(lib.resolve())
    binary = package / 'oscilloscope-plugin'
    if mac:
        library = package / 'lib/libusb-1.0.0.dylib'
        run(['lipo', '-create', *bins, '-output', binary])
        run(['lipo', '-create', *libs, '-output', library])
        run(['install_name_tool', '-id', '@loader_path/libusb-1.0.0.dylib', library])
        for file in [library, binary]:
            run(['codesign', '--force', '--sign', '-', file])
    else:
        shutil.copy2(bins[0], binary)
        shutil.copy2(libs[0], package / 'lib/libusb-1.0.so.0')
    run([binary, '--check-usb'])
    shutil.copy2(fw / 'Firmware/DSO6022BE/dso6022be-firmware.hex', package / 'firmware/dso6022be.hex')
    shutil.copytree(ROOT / 'ui', package / 'ui')
    for file in ['manifest.json', 'README.md', 'help.md', 'LICENSE', 'NOTICE.md']:
        shutil.copy2(ROOT / file, package / file)
    for path, name in [(fw, 'hantek-firmware'), (usb, 'libusb')]:
        run(['git', 'archive', '--format=tar.gz', '-o', package / 'sources' / (name + '.tar.gz'), 'HEAD'], cwd=path)
    shutil.copy2(usb / 'COPYING', package / 'licenses/libusb-LGPL-2.1.txt')
    shutil.copy2(fw / 'Firmware/fx2lib/COPYING.LESSER', package / 'licenses/fx2lib-LGPL-2.1.txt')
    module = Path(subprocess.check_output(['go', 'env', 'GOMODCACHE'], text=True).strip()) / 'github.com/google/gousb@v1.1.3'
    shutil.copy2(module / 'LICENSE', package / 'licenses/gousb-Apache-2.0.txt')
    with tarfile.open(package / 'sources/gousb.tar.gz', 'w:gz') as archive:
        archive.add(module, arcname='gousb')
    # Include this plugin's corresponding source in each release, without build output.
    with tarfile.open(package / 'sources/oscilloscope.tar.gz', 'w:gz') as archive:
        for file in sorted(ROOT.rglob('*')):
            rel = file.relative_to(ROOT)
            if any(x in {'build', 'dist', '__pycache__'} for x in rel.parts) or not file.is_file():
                continue
            archive.add(file, arcname=str(rel))
    sums = []
    for file in sorted(package.rglob('*')):
        if file.is_file():
            sums.append(hashlib.sha256(file.read_bytes()).hexdigest() + '  ' + file.relative_to(package).as_posix())
    (package / 'SHA256SUMS').write_text('\n'.join(sums) + '\n')
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    output = dist / f"oscilloscope-{manifest['version']}-{args.target}.tar.gz"
    with tarfile.open(output, 'w:gz', format=tarfile.USTAR_FORMAT) as archive:
        for file in sorted(package.rglob('*')):
            if file.is_file():
                archive.add(file, arcname=file.relative_to(package).as_posix())
    print(output)


if __name__ == '__main__':
    main()
