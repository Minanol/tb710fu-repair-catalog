#!/bin/bash
# TB710FU / GNOME 中文输入法：让 fcitx5 不再抢占 org.freedesktop.IBus
# 现象：fcitx5 明明在跑，GNOME 的 Wayland 应用（含 Droidloom 这类原生 Wayland
#       客户端）打不出中文，顶栏「中/EN」点了也没反应。
# 原因：fcitx5 的 ibusfrontend 会占用 org.freedesktop.IBus 这个总线名，真正的
#       ibus-daemon 因此起不来；而 GNOME 的 text-input-v3 只对接 ibus。
# 做法：fcitx5 用 --disable ibusfrontend 启动（GTK/Qt 应用的中文输入不受影响），
#       把 IBus 名字让给 ibus-daemon，再给 GNOME 输入源加上 ibus libpinyin。
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "✗ 请用普通桌面用户运行，不要 sudo / root（本包全部是用户级改动）" >&2
    exit 1
fi

AT="${TB710FU_ATTACHMENTS_DIR:-}"
[ -n "$AT" ] && [ -d "$AT" ] || { echo "✗ 缺少附件目录（TB710FU_ATTACHMENTS_DIR）" >&2; exit 1; }

UD="$HOME/.config/systemd/user"

echo "== 0. 检查前提 =="
command -v fcitx5 >/dev/null || echo "  ! 未安装 fcitx5，本机可能用别的方式启动输入法"
if ls /usr/share/ibus/component/libpinyin.xml >/dev/null 2>&1; then
    echo "  ✓ ibus-libpinyin 已安装"
else
    echo "  ✗ 缺少 ibus-libpinyin 引擎，请先安装：sudo apt install ibus-libpinyin" >&2
    echo "    装好后再运行本脚本。" >&2
    exit 1
fi

echo "== 1. 安装 fcitx5 用户级 unit（带 --disable ibusfrontend）=="
mkdir -p "$UD"
if [ -e "$UD/tb-fcitx5.service" ]; then
    cp -a "$UD/tb-fcitx5.service" "$UD/tb-fcitx5.service.bak-$(date +%Y%m%d-%H%M%S)"
    echo "  · 已备份原用户级 unit"
fi
install -m 0644 "$AT/tb-fcitx5.service" "$UD/tb-fcitx5.service"
systemctl --user daemon-reload
systemctl --user enable --now tb-fcitx5.service 2>/dev/null || systemctl --user restart tb-fcitx5.service
sleep 2
echo "  状态: $(systemctl --user is-active tb-fcitx5.service 2>/dev/null || echo 未知)"

echo "== 2. 拉起 ibus-daemon（GNOME 的 IBus 服务）=="
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

echo "== 3. 添加输入源（保留现有条目）=="
CUR=$(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || echo "[]")
echo "  当前: $CUR"
case "$CUR" in
    *libpinyin*) echo "  · 已包含 ibus libpinyin，跳过";;
    *)
        NEW=$(printf '%s' "$CUR" | sed "s/^\[//;s/\]$//")
        if [ -n "${NEW// /}" ]; then NEW="$NEW, ('ibus', 'libpinyin')"; else NEW="('ibus', 'libpinyin')"; fi
        gsettings set org.gnome.desktop.input-sources sources "[$NEW]"
        echo "  新的: $(gsettings get org.gnome.desktop.input-sources sources)"
        ;;
esac

cat <<'EOS'

== 完成，但必须做最后一步 ==
⚠ 现在请注销一次再重新登录（右上角电源菜单 → 注销）。

原因：正在运行的 gnome-shell 是在旧状态（IBus 名字被 fcitx5 占着）下初始化的，
它不会中途重连新的 ibus-daemon。不重登的话，顶栏「中/EN」依然点了没反应，
中文也依然出不来——这不是脚本没生效。

重登后自检：
  · 顶栏出现输入法图标，点击或 Super+空格可以在中/英之间切换
  · 在 gedit / GNOME 文本编辑器里打 nihao，应出现中文候选

回滚：
  systemctl --user disable --now tb-fcitx5.service
  rm -f ~/.config/systemd/user/tb-fcitx5.service
  systemctl --user daemon-reload
  systemctl --user restart tb-fcitx5.service   # 若系统自带该单元，会回到原版
EOS
