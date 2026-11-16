#!/usr/bin/env python3
"""Restore the historical GNOME 50 / WowType preedit and Backspace fix."""
import argparse
import ast
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

WOW_UUID = 'tb-wowtype-osk@tb710fu'
PANEL_UUID = 'kimpanel@kde.org'
ROW_UUID = 'tb-osk-shortcuts@tb710fu'
HERE = Path(__file__).resolve().parent


def preedit_config(text):
    """Change just Behavior/PreeditEnabledByDefault, preserving other settings."""
    lines = text.splitlines(keepends=True)
    newline = '\r\n' if '\r\n' in text else '\n'
    sections = [(i, m.group(1)) for i, line in enumerate(lines)
                for m in [re.match(r'^\s*\[([^]]+)\]\s*(?:[#;].*)?$', line.rstrip('\r\n'))] if m]
    positions = [i for i, name in sections if name == 'Behavior']
    if len(positions) > 1:
        raise ValueError('Duplicate Behavior sections; inspect Fcitx config manually.')
    if not positions:
        prefix = text + (newline if text and not text.endswith(('\n', '\r')) else '')
        return prefix + '[Behavior]' + newline + 'PreeditEnabledByDefault=False' + newline
    start = positions[0]
    end = next((i for i, _ in sections if i > start), len(lines))
    keys = [i for i in range(start+1, end)
            if re.match(r'^\s*PreeditEnabledByDefault\s*=', lines[i])]
    if len(keys) > 1:
        raise ValueError('Duplicate preedit keys; inspect Fcitx config manually.')
    if keys:
        i = keys[0]
        m = re.match(r'^(\s*PreeditEnabledByDefault\s*=\s*)[^#;\r\n]*(.*)$', lines[i].rstrip('\r\n'))
        ending = newline if lines[i].endswith(('\n', '\r')) else ''
        lines[i] = m.group(1) + 'False' + m.group(2) + ending
    else:
        if end and not lines[end-1].endswith(('\n', '\r')):
            lines[end-1] += newline
        lines.insert(end, 'PreeditEnabledByDefault=False' + newline)
    return ''.join(lines)


def call(*args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=30).stdout.strip()


def write_atomic(path, data, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('Refusing symlink target: ' + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.tb-ime-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def snapshot_target(path, destination):
    if path.is_symlink():
        raise ValueError('Refusing symlink target: ' + str(path))
    existed = path.exists()
    if existed:
        if path.is_dir():
            shutil.copytree(path, destination, symlinks=True)
        else:
            shutil.copy2(path, destination)
    return existed


def restore_target(path, source, existed):
    if path.is_symlink():
        raise ValueError('Refusing symlink target: ' + str(path))
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()
    if existed:
        path.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, path, symlinks=True)
        else:
            shutil.copy2(source, path)


def paths():
    home = Path.home()
    data = Path(os.environ.get('XDG_DATA_HOME', str(home/'.local/share')))
    config = Path(os.environ.get('XDG_CONFIG_HOME', str(home/'.config')))
    state = Path(os.environ.get('XDG_STATE_HOME', str(home/'.local/state')))
    extensions = data/'gnome-shell/extensions'
    return dict(config=config/'fcitx5/config', wow=extensions/WOW_UUID,
                panel=extensions/PANEL_UUID, row=extensions/ROW_UUID,
                state=state/'tb710fu-ime-preedit-backspace')


def preflight(p):
    if sys.platform != 'linux' or os.geteuid() == 0:
        raise ValueError('Run as the normal desktop user on Ubuntu; do not use sudo.')
    release = {}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            release[key] = value.strip('"')
    if release.get('ID') != 'ubuntu' or release.get('VERSION_ID') != '26.04':
        raise ValueError('This historical fix supports Ubuntu 26.04 / GNOME 50 only.')
    if os.environ.get('XDG_SESSION_TYPE') != 'wayland' or not os.environ.get('DBUS_SESSION_BUS_ADDRESS'):
        raise ValueError('Run inside the logged-in GNOME Wayland session with its session D-Bus.')
    for tool in ('gnome-shell', 'gsettings', 'fcitx5-remote'):
        if not shutil.which(tool):
            raise ValueError('Missing installed dependency: ' + tool)
    if not re.search(r'\b50(?:\.|\b)', call('gnome-shell', '--version')):
        raise ValueError('Unsupported GNOME Shell version; expected 50.')
    if call('gsettings', 'get', 'org.gnome.shell', 'disable-user-extensions') != 'false':
        raise ValueError('User extensions are disabled. Enable them explicitly before repair.')
    enabled_text = call('gsettings', 'get', 'org.gnome.shell', 'enabled-extensions')
    enabled = ast.literal_eval(re.sub(r'^@as\s+', '', enabled_text))
    if not isinstance(enabled, list) or not all(isinstance(x, str) for x in enabled):
        raise ValueError('Unexpected enabled-extensions setting.')
    if ROW_UUID not in enabled:
        raise ValueError('The existing TB710FU shared candidate-row extension must be enabled.')
    row = p['row']
    if not row.is_dir():
        row = Path('/usr/share/gnome-shell/extensions')/ROW_UUID
    text = (row/'extension.js').read_text()
    if not all(x in text for x in ('_compositionText', 'UpdatePreeditText', '_preeditLabel')):
        raise ValueError('Existing candidate-row extension lacks the historical composition UI.')
    source = p['panel']
    if not source.is_dir():
        source = Path('/usr/share/gnome-shell/extensions')/PANEL_UUID
    metadata = json.loads((source/'metadata.json').read_text())
    if metadata.get('uuid') != PANEL_UUID or metadata.get('version') != 92:
        raise ValueError('Expected installed Kimpanel version 92; no package is downloaded automatically.')
    if '50' not in metadata.get('shell-version', []):
        raise ValueError('Kimpanel metadata does not support GNOME 50.')
    for target in (p['config'], p['wow'], p['panel'], source/'extension.js', source/'panel.js'):
        if target.is_symlink():
            raise ValueError('Refusing symlinked configuration/extension: ' + str(target))
    if call('fcitx5-remote') not in ('1', '2'):
        raise ValueError('Fcitx 5 is not running in this desktop session.')
    return source, enabled


def rollback(p):
    if os.geteuid() == 0:
        raise ValueError('Rollback must run as the same normal desktop user.')
    name = (p['state']/'latest').read_text().strip()
    if not re.fullmatch(r'[0-9TZ-]+', name):
        raise ValueError('Invalid local snapshot name.')
    root = p['state']/name
    state = json.loads((root/'state.json').read_text())
    for key in ('config', 'wow', 'panel'):
        restore_target(p[key], root/key, state['existed'][key])
    call('gsettings', 'set', 'org.gnome.shell', 'enabled-extensions', repr(state['enabled']))
    print('Restored the latest private local snapshot. Save work, then log out/in yourself.')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'apply', 'rollback'), default='apply', nargs='?')
    action = parser.parse_args(argv).action
    p = paths()
    if action == 'rollback':
        rollback(p)
        return
    source, enabled = preflight(p)
    original = p['config'].read_bytes() if p['config'].exists() else b''
    config = preedit_config(original.decode('utf-8')).encode('utf-8')
    with tempfile.TemporaryDirectory(prefix='tb-ime-stage-') as directory:
        stage = Path(directory)/PANEL_UUID
        shutil.copytree(source, stage, symlinks=True)
        call(sys.executable, str(HERE/'patch-kimpanel.py'), str(stage))
        if 'TB710FU: stable five-slot candidates' not in (stage/'extension.js').read_text():
            raise ValueError('Candidate integration staging failed.')
        if action == 'check':
            print('Prerequisites and staged Kimpanel patch passed; no user files/settings changed.')
            return
        p['state'].mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(p['state'], 0o700)
        name = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        snapshot = p['state']/name
        snapshot.mkdir(mode=0o700)
        existed = {key: snapshot_target(p[key], snapshot/key) for key in ('config', 'wow', 'panel')}
        write_atomic(snapshot/'state.json', json.dumps(dict(existed=existed, enabled=enabled)).encode())
        write_atomic(p['state']/'latest', name.encode())
        try:
            mode = stat.S_IMODE(p['config'].stat().st_mode) if p['config'].exists() else 0o600
            write_atomic(p['config'], config, mode)
            write_atomic(p['wow']/'extension.js', (HERE/'extension.js').read_bytes(), 0o644)
            write_atomic(p['wow']/'metadata.json', (HERE/'metadata.json').read_bytes(), 0o644)
            if not p['panel'].exists():
                shutil.copytree(stage, p['panel'], symlinks=True)
            else:
                for item in ('extension.js', 'panel.js'):
                    write_atomic(p['panel']/item, (stage/item).read_bytes(), 0o644)
            new_enabled = enabled + [uuid for uuid in (PANEL_UUID, WOW_UUID) if uuid not in enabled]
            call('gsettings', 'set', 'org.gnome.shell', 'enabled-extensions', repr(new_enabled))
        except Exception:
            rollback(p)
            raise
    print('Applied historical preedit-panel and Backspace fix. No input text was logged.')
    print('Save work and log out/in to load the extension and Fcitx configuration together.')
    print('Private rollback snapshot is under ~/.local/state/tb710fu-ime-preedit-backspace (or XDG_STATE_HOME).')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError, UnicodeError) as exc:
        print('STOPPED: ' + str(exc), file=sys.stderr)
        sys.exit(1)
