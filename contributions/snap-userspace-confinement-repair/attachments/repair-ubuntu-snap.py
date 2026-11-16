#!/usr/bin/env python3
"""TB710FU Ubuntu Snap repair. No kernel flashing or partition writes.

sudo python3 repair-ubuntu-snap.py --check
sudo python3 repair-ubuntu-snap.py --apply --verify --user ubuntu
sudo python3 repair-ubuntu-snap.py --apply --install-idea --user ubuntu
"""

import argparse
import gzip
import json
import os
import platform
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


BACKUPS = Path('/var/backups/tb710fu-snap-support-20261116/script-runs')
PARSER = Path('/etc/apparmor/parser.conf')
ABI = '/etc/apparmor.d/abi/4.0'
CAPS = Path('/usr/lib/snapd/snap-confine.caps')
CONFINE = Path('/usr/lib/snapd/snap-confine')
PACKAGES = {
    'snap': 'snapd', 'apparmor_parser': 'apparmor', 'aa-exec': 'apparmor',
    'getcap': 'libcap2-bin', 'setcap': 'libcap2-bin',
}
FLAGS = (
    'SECURITY_APPARMOR', 'SECURITY_NETWORK', 'SECURITY_PATH',
    'SECCOMP', 'SECCOMP_FILTER', 'NAMESPACES', 'USER_NS', 'PID_NS', 'NET_NS',
    'SQUASHFS', 'SQUASHFS_XATTR', 'SQUASHFS_ZLIB', 'SQUASHFS_LZO',
    'SQUASHFS_LZ4', 'SQUASHFS_XZ', 'SQUASHFS_ZSTD',
)


class RepairError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def run(argv, *, check=True, input=None, timeout=120, env=None):
    result = subprocess.run(argv, input=input, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, env=env)
    if check and result.returncode:
        detail = (result.stderr or result.stdout).strip()[-2500:]
        raise RepairError(f'命令失败：{shlex.join(argv)}\n{detail}')
    return result


def log(message):
    print(message, flush=True)


def kernel_preflight():
    if platform.system() != 'Linux':
        raise RepairError('只能在 Ubuntu Linux 执行；当前不是 Linux。', 2)
    release = {}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            release[key] = value.strip('"')
    if release.get('ID') != 'ubuntu' or platform.machine() != 'aarch64':
        raise RepairError('本脚本适用于 Ubuntu ARM64 的 TB710FU 修复环境。', 2)
    if os.geteuid() != 0:
        raise RepairError('请用 sudo python3 repair-ubuntu-snap.py ... 执行，以检查内核安全功能。', 2)
    if not Path('/run/systemd/system').is_dir():
        raise RepairError('需要正在运行 systemd 的完整 Ubuntu，不能在普通容器/chroot 内修复宿主机。', 2)
    config_file = Path('/proc/config.gz')
    if config_file.exists():
        with gzip.open(config_file, 'rt') as handle:
            text = handle.read()
    else:
        config_file = Path('/boot') / ('config-' + platform.release())
        if not config_file.is_file():
            raise RepairError('无法读取运行内核配置；需要 /proc/config.gz 或对应 /boot/config-*。', 3)
        text = config_file.read_text()
    config = dict(re.findall(r'^CONFIG_(\w+)=(.*)$', text, re.M))
    missing = [f'CONFIG_{flag}=y' for flag in FLAGS if config.get(flag) != 'y']
    lsm = Path('/sys/kernel/security/lsm')
    if not lsm.is_file() or 'apparmor' not in lsm.read_text().strip().split(','):
        missing.append('AppArmor 必须在当前启动的 LSM 列表中启用')
    features = Path('/sys/kernel/security/apparmor/features')
    if not features.is_dir():
        missing.append('AppArmor 内核功能接口不可用')
    elif (features / 'network_v8').exists() and not (features / 'network').exists():
        missing.append('本次已验证的 AppArmor network 兼容功能接口缺失')
    if missing:
        raise RepairError(
            '当前内核无法完成本次修复：\n  - ' + '\n  - '.join(missing) +
            '\n需要安装匹配 TB710FU 的完整内核和模块并重启后再运行。'
            '\napt 安装 snapd 无法添加缺失的内核功能；本脚本不会刷写 boot/GPT。', 3)
    log(f'内核前置检查通过：{platform.release()}')


def compatibility_change():
    # This parser workaround is specific to the tested 7.2 TB710FU port.
    if not re.fullmatch(r'7\.2\.\d+-tb710fu(?:[-.].*)?', platform.release()):
        return None
    if not Path(ABI).is_file():
        raise RepairError(f'缺少 {ABI}；安装/修复 apparmor 包后再执行。', 4)
    if not PARSER.is_file() or PARSER.is_symlink():
        raise RepairError('AppArmor parser.conf 不存在或是符号链接，请先检查其来源。', 4)
    text = PARSER.read_text()
    active = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if re.match(r'(?:kernel-features|override-policy-abi|policy-features)\b', line):
            active.append(line)
    wanted = 'policy-features=' + ABI
    if active and active != [wanted]:
        raise RepairError('发现自定义 AppArmor 功能/ABI 覆盖，未自动改写：\n' + '\n'.join(active), 4)
    if active:
        return None
    return text.rstrip() + ('\n\n# TB710FU 7.2: modern networking for profiles without an ABI.\n'
                            '# Explicit ABI declarations remain authoritative.\n' + wanted + '\n')


def cap_spec():
    if not CAPS.is_file() or not CONFINE.is_file() or CONFINE.is_symlink():
        raise RepairError('缺少 apt snapd 包自带的 snap-confine 或能力清单；请先修复该软件包。', 4)
    expected = CAPS.read_text().strip()
    if not re.fullmatch(r'cap_[a-z0-9_,]+=[eip]+', expected):
        raise RepairError('snap-confine 能力清单格式异常，拒绝猜测或提升权限。', 4)
    st = CONFINE.stat()
    if st.st_uid != 0 or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH | stat.S_ISUID):
        raise RepairError('snap-confine 所有者/权限与本次验证的能力模式不同，请先检查软件包。', 4)
    return expected


def current_caps():
    value = run(['getcap', str(CONFINE)]).stdout.strip()
    return value.split(' ', 1)[1].strip() if ' ' in value else ''


class Backup:
    def __init__(self):
        BACKUPS.mkdir(mode=0o700, parents=True, exist_ok=True)
        # This path is excluded by the project's existing private-backup audit.
        os.chmod(BACKUPS, 0o700)
        self.path = Path(tempfile.mkdtemp(prefix=time.strftime('%Y%m%d-%H%M%S-'), dir=BACKUPS))
        self.saved = False

    def save(self):
        if self.saved:
            return
        shutil.copy2(PARSER, self.path / 'parser.conf')
        (self.path / 'snap-confine-capabilities.txt').write_text(current_caps() + '\n')
        data = {'kernel': platform.release(), 'time': time.strftime('%Y-%m-%d %H:%M:%S'),
                'held_packages': run(['apt-mark', 'showhold']).stdout.splitlines(),
                'apparmor_active': run(['systemctl', 'is-active', 'apparmor'], check=False).stdout.strip(),
                'snapd_active': run(['systemctl', 'is-active', 'snapd'], check=False).stdout.strip()}
        (self.path / 'before.json').write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        self.saved = True
        log('本次备份：' + str(self.path))


def atomic_parser_write(text):
    info = PARSER.stat()
    fd, name = tempfile.mkstemp(prefix='.tb-snap-', dir=PARSER.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chown(name, info.st_uid, info.st_gid)
        os.chmod(name, stat.S_IMODE(info.st_mode))
        os.replace(name, PARSER)
    finally:
        Path(name).unlink(missing_ok=True)


def assessment():
    confinement = run(['snap', 'debug', 'confinement']).stdout.strip()
    features = run(['snap', 'debug', 'sandbox-features']).stdout
    if confinement != 'strict' or not any(
            line.startswith('apparmor:') and 'support-level:full' in line
            for line in features.splitlines()):
        raise RepairError('Snap 隔离仍不完整：' + confinement + '\n' + features[-2500:], 5)
    for service in ('apparmor', 'snapd'):
        if run(['systemctl', 'is-active', service], check=False).returncode:
            raise RepairError(service + ' 服务未运行，请检查 journalctl -u ' + service, 5)
    log('Snap strict / AppArmor full / 服务检查通过')


def ordinary_user(name):
    name = name or os.environ.get('SUDO_USER')
    if not name or name == 'root':
        raise RepairError('验证/安装 IDEA 时请用 --user 指定非 root 桌面用户，例如 --user ubuntu。', 2)
    try:
        account = pwd.getpwnam(name)
    except KeyError:
        raise RepairError('用户不存在：' + name, 2)
    if account.pw_uid == 0 or not Path(account.pw_dir).is_dir():
        raise RepairError('需要有实际主目录的非 root 用户。', 2)
    return account


def as_user(account, command, *, input=None, timeout=120):
    return run(['runuser', '-u', account.pw_name, '--', 'env',
                'HOME=' + account.pw_dir, 'USER=' + account.pw_name,
                'LOGNAME=' + account.pw_name] + command, input=input, timeout=timeout)


def verify_isolation(account):
    if run(['snap', 'list', 'hello-world'], check=False).returncode:
        log('安装官方 hello-world，用于实际严格隔离检查……')
        run(['snap', 'install', 'hello-world'], timeout=1800)
    result = as_user(account, ['snap', 'run', 'hello-world'])
    if 'Hello World!' not in result.stdout:
        raise RepairError('普通用户 hello-world 输出异常。', 5)
    temp = Path(tempfile.mkdtemp(prefix='tb-snap-isolation-', dir='/var/tmp'))
    profile = temp.name
    loaded = False
    try:
        os.chmod(temp, 0o755)
        allowed, denied = temp / 'allowed', temp / 'denied'
        for fixture in (allowed, denied):
            fixture.write_text('harmless isolation fixture\n')
            fixture.chmod(0o644)
        # Prove the later EACCES is not merely ordinary directory/file permissions.
        as_user(account, ['/bin/cat', str(denied)])
        interpreter = str(Path(sys.executable).resolve())
        policy = ('profile ' + profile + ' {\n  /** mr,\n  ' + interpreter +
                  ' ix,\n  deny ' + str(denied) + ' r,\n}\n')
        policy_file = temp / 'profile'
        policy_file.write_text(policy)
        run(['apparmor_parser', '-r', '-T', '-K', str(policy_file)])
        loaded = True
        code = (
            'import errno,socket\n'
            f'with open({str(allowed)!r}) as f: assert f.read()\n'
            f'target={str(denied)!r}\n'
            'try:\n f=open(target);f.close()\n'
            'except OSError as e:\n assert e.errno==errno.EACCES\n'
            'else:\n raise RuntimeError("file denial failed")\n'
            'try:\n s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);s.close()\n'
            'except OSError as e:\n assert e.errno==errno.EACCES\n'
            'else:\n raise RuntimeError("network denial failed")\n'
            'print("AppArmor file/network denial PASS")\n'
        )
        result = as_user(account, ['aa-exec', '-p', profile, '--', interpreter, '-I', '-B', '-c', code])
        log(result.stdout.strip())
        shell = ('set -eu\n'
                 'grep -qE "^Seccomp:[[:space:]]+2$" /proc/self/status\n'
                 'if cat ' + shlex.quote(str(denied)) + ' >/dev/null 2>&1; then exit 7; fi\n'
                 'printf "Snap outside-file denial / Seccomp PASS\\n"\n')
        log(as_user(account, ['snap', 'run', '--shell', 'hello-world'], input=shell).stdout.strip())
    finally:
        if loaded:
            result = run(['apparmor_parser', '-R', str(temp / 'profile')], check=False)
            if result.returncode:
                log('警告：测试 profile 卸载失败，保留诊断目录：' + str(temp))
                raise RepairError('请用 apparmor_parser -R ' + str(temp / 'profile') + ' 清理测试策略。', 5)
        shutil.rmtree(temp)


def install_idea(account):
    if run(['snap', 'list', 'intellij-idea'], check=False).returncode:
        log('从 Snap 商店安装官方 IntelliJ IDEA ARM64（发行者要求 classic 模式）……')
        run(['snap', 'install', 'intellij-idea', '--classic'], timeout=7200)
    root = Path('/snap/intellij-idea/current')
    runtimes = list(root.glob('**/jbr/bin/javac'))
    if len(runtimes) != 1:
        raise RepairError('IDEA 已安装，但不能唯一定位内置 Java 编译器；未声称完成运行测试。', 5)
    javac = runtimes[0]
    java = javac.with_name('java')
    temp = Path(tempfile.mkdtemp(prefix='tb-idea-java-', dir='/var/tmp'))
    os.chown(temp, account.pw_uid, account.pw_gid)
    try:
        source = temp / 'Hello.java'
        source.write_text('class Hello { public static void main(String[] a) { '
                          'System.out.println("TB710FU IDEA runtime OK"); } }\n')
        os.chown(source, account.pw_uid, account.pw_gid)
        as_user(account, [str(javac), '-d', str(temp), str(source)])
        result = as_user(account, [str(java), '-cp', str(temp), 'Hello'])
        if result.stdout.strip() != 'TB710FU IDEA runtime OK':
            raise RepairError('IDEA Java 运行输出异常。', 5)
        log('IDEA 已安装，普通用户 Java 编译/运行通过。图形界面请从应用菜单打开验证。')
    finally:
        shutil.rmtree(temp)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true', help='只读检查，不安装、不修改系统')
    mode.add_argument('--apply', action='store_true', help='备份后修复用户态配置；不刷写内核、不重启')
    parser.add_argument('--verify', action='store_true', help='配合 --apply，安装/运行 hello-world 并实测隔离')
    parser.add_argument('--install-idea', action='store_true', help='配合 --apply，安装官方 IDEA 并测试内置 Java')
    parser.add_argument('--user', help='执行实际测试的普通用户；默认使用 sudo 的原用户')
    args = parser.parse_args()
    if args.check and (args.verify or args.install_idea):
        parser.error('--verify / --install-idea 需要 --apply；它们可能安装软件或产生临时文件')
    os.umask(0o077)
    os.environ['PATH'] = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    os.environ['LC_ALL'] = 'C.UTF-8'
    kernel_preflight()
    account = ordinary_user(args.user) if args.verify or args.install_idea else None
    missing = sorted({package for command, package in PACKAGES.items() if not shutil.which(command)})
    if args.check and missing:
        raise RepairError('缺少用户态软件包：' + ', '.join(missing) + '；使用 --apply 安装。', 4)
    if missing:
        log('安装缺失依赖：' + ', '.join(missing))
        env = dict(os.environ, DEBIAN_FRONTEND='noninteractive', NEEDRESTART_MODE='l')
        run(['apt-get', 'update'], timeout=1800, env=env)
        run(['apt-get', 'install', '-y', '--no-install-recommends'] + missing, timeout=1800, env=env)
    change = compatibility_change()
    expected = cap_spec()
    caps_changed = current_caps() != expected
    if args.check:
        if change is not None or caps_changed:
            raise RepairError('需要修复：' + ', '.join(
                name for name, pending in [('parser 默认 ABI', change is not None),
                                            ('snap-confine 文件能力', caps_changed)] if pending) +
                '；请运行 --apply。', 4)
        assessment()
        log('只读检查完成；未修改系统。')
        return
    backup = Backup()
    backup.save()
    held_before = run(['apt-mark', 'showhold']).stdout
    changed = []
    try:
        if change is not None:
            atomic_parser_write(change)
            changed.append('parser')
        if caps_changed:
            run(['setcap', expected, str(CONFINE)])
            changed.append('capabilities')
        if current_caps() != expected:
            raise RepairError('snap-confine 文件能力写入/读取验证失败。', 5)
        if change is not None:
            run(['systemctl', 'restart', 'apparmor'])
        for service in ('apparmor', 'snapd'):
            if run(['systemctl', 'is-failed', service], check=False).returncode == 0:
                run(['systemctl', 'reset-failed', service])
            run(['systemctl', 'enable', '--now', service])
        if change is not None and run(['systemctl', 'show', '-p', 'LoadState', '--value',
                                      'snapd.apparmor'], check=False).stdout.strip() == 'loaded':
            run(['systemctl', 'restart', 'snapd.apparmor'])
        assessment()
    except Exception:
        if 'parser' in changed:
            atomic_parser_write((backup.path / 'parser.conf').read_text())
            run(['systemctl', 'restart', 'apparmor'], check=False)
        if 'capabilities' in changed:
            old = (backup.path / 'snap-confine-capabilities.txt').read_text().strip()
            run(['setcap', old or '-r', str(CONFINE)], check=False)
        log('修复检查失败；已尝试恢复本次更改的配置/文件能力。备份：' + str(backup.path))
        raise
    if args.verify:
        verify_isolation(account)
    if args.install_idea:
        install_idea(account)
    if held_before != run(['apt-mark', 'showhold']).stdout:
        raise RepairError('受保护软件包 hold 列表发生变化，请检查；本脚本没有解除 hold。', 5)
    (backup.path / 'result.txt').write_text('PASS\n' + ('Isolation verified\n' if args.verify else '') +
                                          ('IDEA Java verified\n' if args.install_idea else ''))
    log('完成。更新保护列表保留；未修改 boot/GPT、USB 网络、摄像头或桌面输入法。')


if __name__ == '__main__':
    try:
        main()
    except RepairError as exc:
        print('停止：' + str(exc), file=sys.stderr)
        sys.exit(exc.code)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print('停止：系统操作失败：' + str(exc), file=sys.stderr)
        sys.exit(1)
