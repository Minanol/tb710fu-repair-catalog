#!/bin/bash
# TB710FU / GNOME 中文输入法：让 fcitx5 不再抢占 org.freedesktop.IBus
# 现象：fcitx5 明明在跑，GNOME 的 Wayland 应用（含 Droidloom 这类原生 Wayland
#       客户端）打不出中文，顶栏「中/EN」点了也没反应。
# 原因：fcitx5 的 ibusfrontend 会占用 org.freedesktop.IBus 这个总线名，真正的
#       ibus-daemon 因此起不来；而 GNOME 的 text-input-v3 只对接 ibus。
# 做法：fcitx5 用 --disable ibusfrontend 启动（GTK/Qt 应用的中文输入不受影响），
#       把 IBus 名字让给 ibus-daemon，再给 GNOME 输入源加上 ibus libpinyin。
#
# 用法：TB710FU_FIX_ACTION=check|apply|rollback（默认 apply）
#   check     只检查，不改动任何文件
#   apply     安装并启用
#   rollback  移除用户级覆盖，恢复安装前的快照
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "✗ 请用普通桌面用户运行，不要 sudo / root（本包全部是用户级改动）" >&2
    exit 1
fi

AT="${TB710FU_ATTACHMENTS_DIR:-}"
[ -n "$AT" ] && [ -d "$AT" ] || { echo "✗ 缺少附件目录（TB710FU_ATTACHMENTS_DIR）" >&2; exit 1; }

ACTION="${TB710FU_FIX_ACTION:-apply}"
UD="$HOME/.config/systemd/user"
UNIT="$UD/tb-fcitx5.service"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/tb710fu-gnome-ibus-pinyin"
ORIG_SOURCES='[('"'"'xkb'"'"', '"'"'cn'"'"'), ('"'"'xkb'"'"', '"'"'us'"'"')]'

## ---- gsettings 输入源增删（用 ast.literal_eval，不 eval 任意内容）----
edit_sources() {
    python3 - "$1" "$2" "$3" "$ORIG_SOURCES" <<'PY'
import ast, subprocess, sys
mode, engine, layout, orig = sys.argv[1:5]
def get():
    out = subprocess.run(['gsettings', 'get', 'org.gnome.desktop.input-sources', 'sources'],
                         capture_output=True, text=True, check=True).stdout.strip()
    try: return ast.literal_eval(out) or []
    except (ValueError, SyntaxError): return []
cur = [(str(a), str(b)) for a, b in get()]
item = (engine, layout)
res = [x for x in cur if x != item] if mode == 'remove' else (cur if item in cur else cur + [item])
if mode == 'remove' and not res:
    res = [(str(a), str(b)) for a, b in ast.literal_eval(orig)]
if res == cur:
    print('  · 输入源无变化'); sys.exit(0)
subprocess.run(['gsettings', 'set', 'org.gnome.desktop.input-sources', 'sources', str(res)], check=True)
print('  ✓ 输入源: ' + str(res))
PY
}

check_only() {
    echo "== 检查（不修改任何文件）=="
    command -v fcitx5 >/dev/null && echo "  ✓ fcitx5 已安装" || echo "  ! 未安装 fcitx5，本机可能用别的方式启动输入法"
    ls /usr/share/ibus/component/libpinyin.xml >/dev/null 2>&1 \
        && echo "  ✓ ibus-libpinyin 已安装" \
        || echo "  ✗ 缺少 ibus-libpinyin（需 sudo apt install ibus-libpinyin）"
    if [ -e "$UNIT" ]; then
        grep -q 'disable ibusfrontend' "$UNIT" \
            && echo "  ✓ 已有用户级覆盖且带 --disable ibusfrontend" \
            || echo "  ! 存在用户级覆盖但未禁用 ibusfrontend"
    else
        echo "  · 无用户级覆盖，运行中的 fcitx5 仍会抢占 IBus 名字"
    fi
    echo "  当前输入源: $(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || echo '读不到')"
    BUS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$UID}/bus"
    PID=$(DBUS_SESSION_BUS_ADDRESS="$BUS" gdbus call --session \
        --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetConnectionUnixProcessID org.freedesktop.IBus 2>/dev/null \
        | sed -n 's/.*(uint32 \([0-9]*\).*/\1/p' || true)
    echo "  org.freedesktop.IBus 持有者 PID: ${PID:-无}"
}

do_apply() {
    echo "== 0. 检查前提 =="
    command -v fcitx5 >/dev/null || echo "  ! 未安装 fcitx5，本机可能用别的方式启动输入法"
    if ls /usr/share/ibus/component/libpinyin.xml >/dev/null 2>&1; then
        echo "  ✓ ibus-libpinyin 已安装"
    else
        echo "  ✗ 缺少 ibus-libpinyin 引擎，请先安装：sudo apt install ibus-libpinyin" >&2
        echo "    装好后再运行本脚本。" >&2
        exit 1
    fi

    echo "== 1. 快照原状态 =="
    mkdir -p "$STATE"
    chmod 700 "$STATE"
    [ -e "$UNIT" ] && cp -a "$UNIT" "$STATE/tb-fcitx5.service.orig" || true
    gsettings get org.gnome.desktop.input-sources sources > "$STATE/sources.orig" 2>/dev/null || true
    echo "  · 快照目录: $STATE（仅本机，不公开上传）"

    echo "== 2. 安装 fcitx5 用户级 unit（带 --disable ibusfrontend）=="
    mkdir -p "$UD"
    install -m 0644 "$AT/tb-fcitx5.service" "$UNIT"
    systemctl --user daemon-reload
    systemctl --user enable --now tb-fcitx5.service 2>/dev/null \
        || systemctl --user restart tb-fcitx5.service
    sleep 2
    echo "  状态: $(systemctl --user is-active tb-fcitx5.service 2>/dev/null || echo 未知)"

    echo "== 3. 拉起 ibus-daemon（GNOME 的 IBus 服务）=="
    systemctl --user start org.freedesktop.IBus.session.GNOME.service 2>/dev/null || true
    sleep 2
    BUS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$UID}/bus"
    owner() {
        DBUS_SESSION_BUS_ADDRESS="$BUS" gdbus call --session \
            --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.GetConnectionUnixProcessID "$1" 2>/dev/null \
            | sed -n 's/.*(uint32 \([0-9]*\).*/\1/p'
    }
    IBUS_PID=$(owner org.freedesktop.IBus || true)
    FCITX_PID=$(owner org.fcitx.Fcitx5 || true)
    echo "  org.freedesktop.IBus 持有者 PID: ${IBUS_PID:-无}"
    echo "  org.fcitx.Fcitx5  持有者 PID: ${FCITX_PID:-无}"
    if [ -n "$IBUS_PID" ] && [ "$IBUS_PID" != "$FCITX_PID" ]; then
        echo "  ✓ IBus 名字已交给 ibus-daemon"
    else
        echo "  ! IBus 名字仍可能被 fcitx5 占着，确认 fcitx5 是否真的带 --disable ibusfrontend 重启过"
    fi

    echo "== 4. 添加输入源（保留现有条目）=="
    echo "  当前: $(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || echo '[]')"
    edit_sources add ibus libpinyin

    cat <<'EOS'

== 完成，但必须做最后一步 ==
⚠ 现在请注销一次再重新登录（右上角电源菜单 → 注销）。

原因：正在运行的 gnome-shell 是在旧状态（IBus 名字被 fcitx5 占着）下初始化的，
它不会中途重连新的 ibus-daemon。不重登的话，顶栏「中/EN」依然点了没反应，
中文也依然出不来——这不是脚本没生效。

重登后自检：
  · 顶栏出现输入法图标，点击或 Super+空格可以在中/英之间切换
  · 在 gedit / GNOME 文本编辑器里打 nihao，应出现中文候选
EOS
}

do_rollback() {
    echo "== 回滚 =="
    if [ -e "$UNIT" ]; then
        rm -f "$UNIT" && echo "  ✓ 已移除用户级覆盖 $UNIT"
    else
        echo "  · 无用户级覆盖，跳过"
    fi
    systemctl --user daemon-reload
    # 回到 ROM 自带 /etc/systemd/user/tb-fcitx5.service（ExecStart 无 --disable）
    if systemctl --user restart tb-fcitx5.service 2>/dev/null; then
        sleep 2
        echo "  ✓ tb-fcitx5.service 已重启（ExecStart 应不再带 --disable ibusfrontend）"
    else
        echo "  ! 重启 tb-fcitx5.service 失败，请手动检查 systemctl --user status tb-fcitx5.service" >&2
    fi

    echo "== 恢复输入源 =="
    if [ -s "$STATE/sources.orig" ]; then
        gsettings set org.gnome.desktop.input-sources sources "$(cat "$STATE/sources.orig")"
        echo "  ✓ 已还原为快照值: $(cat "$STATE/sources.orig")"
    else
        edit_sources remove ibus libpinyin
    fi

    cat <<'EOS'

== 回滚完成，同样需要注销后重新登录 ==
注销原因同上：gnome-shell 只在登录时绑定输入法后端。

注意：fcitx5 重新拥有 org.freedesktop.IBus 之后，GNOME 顶栏的输入法菜单
会再次由 fcitx5 接管，中文输入恢复为「只有 GTK/Qt 应用能用」的原状态。
EOS
}

case "$ACTION" in
    check)    check_only ;;
    apply)    do_apply ;;
    rollback) do_rollback ;;
    *) echo "✗ TB710FU_FIX_ACTION 只能是 check / apply / rollback，收到：$ACTION" >&2; exit 2 ;;
esac
