#!/bin/bash
# TB710FU 电源键修正：熄屏后按一次即亮屏
# 原理：原 tb-gnome-power-button.py 用 Mutter.DisplayConfig.PowerSaveMode 判断
#       “屏幕是否已关”，但 GNOME 熄屏是 gsd-power 直接关 DRM 输出完成，该属性
#       长期为 0，于是熄屏后的第一次按键被当成“关屏”丢掉，必须按第二次。
# 本包改用真实判据：/sys/class/drm/*-DSI-1/dpms 与背光 bl_power。
# 做法：不改只读的系统文件，用用户级同名 unit 覆盖 /etc/systemd/user 里的版本。
#
# 用法：TB710FU_FIX_ACTION=check|apply|rollback（默认 apply）
#   check     只检查，不改动任何文件
#   apply     安装脚本与用户级 unit，并启用服务
#   rollback  移除用户级覆盖并重启服务，回到系统自带脚本
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "✗ 请用普通桌面用户运行，不要 sudo / root（本包全部是用户级改动）" >&2
    exit 1
fi

AT="${TB710FU_ATTACHMENTS_DIR:-}"
[ -n "$AT" ] && [ -d "$AT" ] || { echo "✗ 缺少附件目录（TB710FU_ATTACHMENTS_DIR）" >&2; exit 1; }

ACTION="${TB710FU_FIX_ACTION:-apply}"
BIN="$HOME/.local/bin"
UD="$HOME/.config/systemd/user"
WANTS="$UD/graphical-session.target.wants"
UNIT="$UD/tb-gnome-power-button.service"
PKG_UNIT="$AT/tb-gnome-power-button.service"
SYS_UNIT="/etc/systemd/user/tb-gnome-power-button.service"
OBJ=/org/freedesktop/systemd1/unit/tb_2dgnome_2dpower_2dbutton_2eservice

have_dpms() { ls /sys/class/drm/*-DSI-1/dpms >/dev/null 2>&1; }

report_hw() {
    if have_dpms; then
        echo "  ✓ dpms: $(ls /sys/class/drm/*-DSI-1/dpms | head -1)"
    else
        echo "  ✗ 找不到 DSI 输出的 dpms 节点，本机可能不是 TB710FU"
    fi
    if [ -d /sys/class/backlight/sy7758-backlight ]; then
        echo "  ✓ 背光: sy7758-backlight"
    elif ls /sys/class/backlight/*/bl_power >/dev/null 2>&1; then
        echo "  ! 未找到 sy7758-backlight，改用 $(ls -d /sys/class/backlight/*/ | head -1)"
    else
        echo "  ! 无可用背光设备，脚本会退化为只看 dpms"
    fi
}

check_only() {
    echo "== 检查（不修改任何文件）=="
    report_hw
    have_dpms || { echo "  → 结论：本机不具备前提，不应安装"; exit 1; }

    echo "== 当前状态 =="
    if [ -x "$BIN/tb-power-key.py" ]; then
        echo "  · 已安装 $BIN/tb-power-key.py"
    else
        echo "  · 未安装 $BIN/tb-power-key.py（apply 会写入）"
    fi
    if [ -e "$UNIT" ]; then
        if cmp -s "$UNIT" "$PKG_UNIT"; then
            echo "  · 已有用户级 unit（与本包一致）"
        else
            echo "  ! 已有用户级 unit 且与本包不同，apply 会先备份成 $UNIT.bak-<时间戳>"
        fi
    else
        echo "  · 无用户级 unit（apply 会创建）"
    fi
    [ -L "$WANTS/tb-gnome-power-button.service" ] && echo "  · 开机自启软链已存在" \
        || echo "  · 无开机自启软链（apply 会创建）"
    local frag
    frag=$(systemctl --user show -p FragmentPath --value tb-gnome-power-button.service 2>/dev/null || true)
    echo "  · 当前生效的单元文件: ${frag:-未知}"
    case "$frag" in
        "$HOME"*) echo "    → 已由用户级覆盖接管" ;;
        *)        echo "    → 仍指向系统文件（apply 后会切换到这里）" ;;
    esac
    if [ ! -e "$SYS_UNIT" ]; then
        echo "  ! 未找到 $SYS_UNIT，回滚后可能没有可回退的系统版本"
    fi
    echo "  · 服务状态: $(systemctl --user is-active tb-gnome-power-button.service 2>/dev/null || echo 未知)"
    echo
    echo "== 当前判据读数 =="
    readout
}

readout() {
    python3 - <<'PY' || true
import glob, pathlib
for p in sorted(glob.glob('/sys/class/drm/*-DSI-1/dpms')):
    print('  dpms =', pathlib.Path(p).read_text().strip(), '(', p, ')')
bl = pathlib.Path('/sys/class/backlight/sy7758-backlight')
if not bl.is_dir():
    found = sorted(glob.glob('/sys/class/backlight/*'))
    bl = pathlib.Path(found[0]) if found else bl
bl = bl / 'bl_power'
if bl.exists():
    print('  bl_power =', bl.read_text().strip())
PY
}

do_apply() {
    echo "== 0. 检查前提 =="
    report_hw
    have_dpms || { echo "✗ 找不到 DSI 输出的 dpms 节点，本机可能不是 TB710FU，已中止" >&2; exit 1; }

    echo "== 1. 安装脚本 =="
    mkdir -p "$BIN" "$UD" "$WANTS"
    install -m 0755 "$AT/tb-power-key.py"  "$BIN/tb-power-key.py"
    install -m 0755 "$AT/tb-power-key-off" "$BIN/tb-power-key-off"
    echo "  ✓ $BIN/tb-power-key.py"

    echo "== 2. 安装用户级 unit（覆盖系统同名单元，无需 root）=="
    # 只在自己不是旧版本时才备份，避免反复 apply 堆出与包内容相同的 .bak
    if [ -e "$UNIT" ] && ! cmp -s "$UNIT" "$PKG_UNIT"; then
        cp -a "$UNIT" "$UNIT.bak-$(date +%Y%m%d-%H%M%S)"
        echo "  · 已备份原有用户级 unit"
    fi
    install -m 0644 "$PKG_UNIT" "$UNIT"
    ln -sf "$UNIT" "$WANTS/tb-gnome-power-button.service"
    echo "  ✓ $UNIT"

    echo "== 3. 启用并启动 =="
    systemctl --user daemon-reload
    systemctl --user enable --no-reload tb-gnome-power-button.service >/dev/null 2>&1 || true
    systemctl --user restart tb-gnome-power-button.service 2>/dev/null \
        || systemctl --user enable --now tb-gnome-power-button.service

    sleep 2
    echo "== 4. 验证 =="
    local frag state
    frag=$(systemctl --user show -p FragmentPath --value tb-gnome-power-button.service 2>/dev/null || true)
    state=$(systemctl --user is-active tb-gnome-power-button.service 2>/dev/null || true)
    echo "  单元文件: ${frag:-未知}"
    echo "  运行状态: ${state:-未知}"
    case "$frag" in
        "$HOME"*) echo "  ✓ 已由用户级覆盖接管";;
        *) echo "  ! FragmentPath 仍指向系统文件，检查 ~/.config/systemd/user 是否被 systemd 读到";;
    esac
    readout

    cat <<'EOS'

== 完成 ==
测试：合上保护套熄屏（或等自动熄屏）后按一次电源键，应立即亮屏。
回滚：TB710FU_FIX_ACTION=rollback    （或运行 tb-power-key-off，效果相同）
说明：长按 1 秒仍然是关机请求，短按才是亮/熄屏切换。
EOS
}

do_rollback() {
    echo "== 回滚 =="
    local restored=""
    # 若存在与包内容不同的 .bak，说明那是用户自己的旧覆盖，优先还原它
    local bak
    bak=$(ls -t "$UNIT".bak-* 2>/dev/null | head -1 || true)
    if [ -n "$bak" ] && ! cmp -s "$bak" "$PKG_UNIT"; then
        mv -f "$bak" "$UNIT" && restored="$UNIT（已还原 $bak）"
    fi

    if systemctl --user is-enabled tb-gnome-power-button.service >/dev/null 2>&1; then
        systemctl --user disable tb-gnome-power-button.service >/dev/null 2>&1 \
            && echo "  ✓ 已取消开机自启" || echo "  ! disable 失败，继续清理文件"
    fi
    if [ -e "$UNIT" ] || [ -L "$UNIT" ]; then
        if [ -n "$restored" ]; then
            echo "  ✓ $restored"
        else
            mv -f "$UNIT" "$UNIT.disabled" && echo "  ✓ 用户级 unit 已停用（$UNIT.disabled）"
        fi
    else
        echo "  · 无用户级 unit，跳过"
    fi
    if [ -L "$WANTS/tb-gnome-power-button.service" ] || [ -e "$WANTS/tb-gnome-power-button.service" ]; then
        rm -f "$WANTS/tb-gnome-power-button.service" && echo "  ✓ 已删除开机自启软链"
    fi

    systemctl --user daemon-reload

    echo "== 重启服务（恢复系统自带脚本）=="
    systemctl --user restart tb-gnome-power-button.service 2>/dev/null \
        || echo "  ! 重启失败，请手动执行: systemctl --user restart tb-gnome-power-button.service"
    sleep 2

    local frag
    frag=$(systemctl --user show -p FragmentPath --value tb-gnome-power-button.service 2>/dev/null || true)
    echo "  单元文件: ${frag:-未知}"
    echo "  运行状态: $(systemctl --user is-active tb-gnome-power-button.service 2>/dev/null || echo 未知)"
    case "$frag" in
        "$HOME"*) echo "  ! 仍指向用户级文件，回滚未完全生效";;
        "$SYS_UNIT"|/usr/*|/etc/*) echo "  ✓ 已回到系统自带脚本（按两次才亮屏）";;
    esac

    for f in "$BIN/tb-power-key.py" "$BIN/tb-power-key-off"; do
        [ -e "$f" ] && rm -f "$f" && echo "  ✓ 已删除 $f"
    done
    echo "  完成。再次需要时重新执行 apply 即可（会重新安装这两个脚本）。"
}

case "$ACTION" in
    check)    check_only ;;
    apply)    do_apply ;;
    rollback) do_rollback ;;
    *) echo "✗ TB710FU_FIX_ACTION 只能是 check / apply / rollback，收到：$ACTION" >&2; exit 2 ;;
esac
