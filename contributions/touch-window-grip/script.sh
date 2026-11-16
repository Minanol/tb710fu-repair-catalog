#!/bin/bash
# TB710FU 触摸窗口抓取：手指拖动 / 缩放宽边框为无边框的 X11 窗口（Electron 等）
# 背景：Chromium 的 -webkit-app-region: drag 与窗口缩放热区只认鼠标事件，
#       平板上没有鼠标，于是窗口既拖不动也缩不了。本工具用 XInput2 被动触摸
#       抓取，在按下瞬间分流：角落缩放 / 边缘单轴缩放 / 顶部条拖动 / 其余交还应用。
#
# 用法：TB710FU_FIX_ACTION=check|apply|rollback（默认 apply）
#   check     只检查，不改动任何文件
#   apply     安装程序、默认配置与用户级服务
#   rollback  停用服务并移除本包文件（保留你的 targets.json 备份）
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "✗ 请用普通桌面用户运行，不要 sudo / root（本包全部是用户级改动）" >&2
    exit 1
fi

AT="${TB710FU_ATTACHMENTS_DIR:-}"
[ -n "$AT" ] && [ -d "$AT" ] || { echo "✗ 缺少附件目录（TB710FU_ATTACHMENTS_DIR）" >&2; exit 1; }

ACTION="${TB710FU_FIX_ACTION:-apply}"
BIN="$HOME/.local/bin"
CFG="$HOME/.config/touch-window-grip"
UD="$HOME/.config/systemd/user"
UNIT="$UD/touch-window-grip.service"

check_only() {
    echo "== 检查（不修改任何文件）=="
    [ -n "${DISPLAY:-}" ] && echo "  ✓ DISPLAY=$DISPLAY" \
        || echo "  ! 当前 shell 没有 DISPLAY，本工具只对 XWayland/X11 窗口有效"
    command -v python3 >/dev/null && echo "  ✓ python3 $(python3 -V 2>&1 | awk '{print $2}')" \
        || echo "  ✗ 缺少 python3"
    [ -x "$BIN/touch-window-grip" ] && echo "  ✓ 已安装 $BIN/touch-window-grip" \
        || echo "  · 未安装程序本体"
    [ -x "$BIN/touch-window-grip-launch" ] && echo "  ✓ 已安装启动器" \
        || echo "  · 未安装启动器（unit 需要它）"
    [ -e "$UNIT" ] && echo "  ✓ 已有用户级服务 unit" || echo "  · 无用户级服务 unit"
    [ -e "$CFG/targets.json" ] && echo "  · 现有配置: $(grep -o '"name": *"[^"]*"' "$CFG/targets.json" | sed 's/.*"\([^"]*\)"$/ \1/' | tr -d '\n')" \
        || echo "  · 无配置，apply 时会写入默认 targets.json"
}

do_apply() {
    echo "== 0. 检查前提 =="
    [ -n "${DISPLAY:-}" ] || echo "  ! 当前 shell 没有 DISPLAY，本工具只对 XWayland/X11 窗口有效"
    command -v python3 >/dev/null || { echo "✗ 缺少 python3" >&2; exit 1; }
    echo "  ✓ python3 $(python3 -V 2>&1 | awk '{print $2}')"

    echo "== 1. 安装程序与配置 =="
    mkdir -p "$BIN" "$CFG" "$UD"
    install -m 0755 "$AT/touch-window-grip" "$BIN/touch-window-grip"
    install -m 0755 "$AT/touch-window-grip-launch" "$BIN/touch-window-grip-launch"
    if [ -e "$CFG/targets.json" ]; then
        cp -a "$CFG/targets.json" "$CFG/targets.json.bak-$(date +%Y%m%d-%H%M%S)"
        echo "  · 已备份原有 targets.json，保留你的目标配置不覆盖"
    else
        install -m 0644 "$AT/targets.json" "$CFG/targets.json"
        echo "  ✓ 写入默认 targets.json"
    fi

    echo "== 2. 安装常驻服务 =="
    install -m 0644 "$AT/touch-window-grip.service" "$UNIT"
    systemctl --user daemon-reload
    systemctl --user enable touch-window-grip.service
    # 已在运行就先停，避免 ExecStartPre 的 pkill 只杀掉旧实例后自身被连带收养
    systemctl --user restart touch-window-grip.service 2>/dev/null || \
        systemctl --user enable --now touch-window-grip.service
    sleep 2
    echo "  状态: $(systemctl --user is-active touch-window-grip.service 2>/dev/null || echo 未知)"

    echo "== 3. 自检（无窗口时会跳过）=="
    [ -x "$BIN/touch-window-grip" ] && { python3 "$BIN/touch-window-grip" --status 2>&1 | sed 's/^/  /' || true; }

    cat <<'EOS'

== 完成 ==
使用：
  · 目前默认只接管 targets.json 里 match 命中的窗口（出厂只有 workbuddy）。
  · 增加一个应用：touch-window-grip --add firefox   （或用窗口标题关键字）
  · 查看清单：touch-window-grip --list
  · 移除一个：touch-window-grip --remove firefox
手感调节（~/.config/touch-window-grip/targets.json 的 defaults）：
  corner 54  角落缩放区边长（px）
  edge   18  边缘单轴缩放区宽度（px）
  strip  80  顶部拖动条高度（px）
  tap reject 抓取判定为非拖动/缩放时，原样交还给应用（保证点击与滚动不被抢）
注意：
  · 只对 XWayland / X11 窗口有效，原生 Wayland 客户端抓不到。
  · 登录初期若 Xwayland 尚未就绪，服务会自动退避重试（不会一直刷日志）。
  · 日志：journalctl --user -u touch-window-grip -f
回滚：TB710FU_FIX_ACTION=rollback
EOS
}

do_rollback() {
    echo "== 回滚 =="
    if systemctl --user is-enabled touch-window-grip.service >/dev/null 2>&1; then
        systemctl --user disable --now touch-window-grip.service 2>/dev/null \
            && echo "  ✓ 已停用并禁用 touch-window-grip.service" \
            || echo "  ! disable 失败，继续清理文件"
    else
        echo "  · 服务未启用，跳过"
    fi
    [ -e "$UNIT" ] && rm -f "$UNIT" && echo "  ✓ 已删除 $UNIT"
    systemctl --user daemon-reload

    for f in "$BIN/touch-window-grip" "$BIN/touch-window-grip-launch"; do
        [ -e "$f" ] && rm -f "$f" && echo "  ✓ 已删除 $f"
    done
    if [ -d "$CFG" ]; then
        KEEP="$CFG.bak-$(date +%Y%m%d-%H%M%S)"
        mv "$CFG" "$KEEP" && echo "  ✓ 配置目录已移到 $KEEP（含你改过的 targets.json）"
    fi
    echo "  完成。触摸行为回到系统默认（无边框窗口将无法用手指拖动/缩放）。"
}

case "$ACTION" in
    check)    check_only ;;
    apply)    do_apply ;;
    rollback) do_rollback ;;
    *) echo "✗ TB710FU_FIX_ACTION 只能是 check / apply / rollback，收到：$ACTION" >&2; exit 2 ;;
esac
