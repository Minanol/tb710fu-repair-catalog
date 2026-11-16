# 中文候选区与退格修复

本条目整理此前 TB710FU Ubuntu 适配中已经使用过的修复，针对两个配套问题：拼音跑到应用正文或错误的位置，没有显示在屏幕键盘候选区；退格删除已输入的正文，而没有删除尚未选词的拼音。

## 原因与对应旧文件

- Fcitx 的 `[Behavior] PreeditEnabledByDefault=True` 会将预编辑文本送入应用。改为 `False`，由原有 Kimpanel / TB710FU 候选区显示拼音。
- 关闭行内预编辑后，GNOME 的 `hasPreedit()` 有时返回假。原生屏幕键盘直接删除应用正文，而不是向输入法发送 Backspace。
- `extension.js` / `metadata.json` 是此前 `wowtype-osk` v2 的原样副本。它识别原候选区中的组合输入，把退格串行交给既有 Fcitx 兼容上下文；组合输入结束后，才回到正文删除。短按、连续按、长按以及切换焦点有独立保护。
- `patch-kimpanel.py` 与 `kimpanel-stable-candidates.txt` 是此前的 Kimpanel v92 适配。脚本在临时目录检查和应用补丁后，才部署到当前用户目录。

源文件对应适配工程中的 `ubuntu-tb710fu/offline-prep/wowtype-osk/`。v2 引擎桥接脚本与此前保存的历史版本字节一致。相关历史说明同时位于 `wowtype-osk/README.md` 的 Version 2 和 `osk-shortcuts/README.md` 的 Version 8 / Version 13。

## 适用范围与依赖

适用于已有 TB710FU 输入环境的 Ubuntu 26.04 ARM64、GNOME Shell 50、Wayland、Fcitx 5、WowType 0.4.0、Kimpanel 92。必须已经安装并启用 `tb-osk-shortcuts@tb710fu`，且其代码具有共享候选区和预编辑行。依赖 Python 3.8+、`gsettings`、`gnome-shell` 和 `fcitx5-remote`。

安装入口检查 Ubuntu/GNOME/会话和已有候选区，拒绝不匹配的 Kimpanel 版本及符号链接目标；不自动下载安装输入法或整套键盘布局。它不更新现有快捷键、剪贴板、截图或输入策略扩展，也不修改 `GTK_IM_MODULE`、服务、内核、引导器或分区。

## 使用

修复助手必须校验主脚本及全部附件 SHA-256，并将附件放在 `TB710FU_ATTACHMENTS_DIR`。在当前 GNOME 桌面用户会话中执行，不使用 sudo。

```sh
# 在仓库根目录执行：只检查依赖和暂存补丁，不修改用户配置。
TB710FU_ATTACHMENTS_DIR="$PWD/contributions/ime-preedit-backspace/attachments" \
TB710FU_FIX_ACTION=check bash contributions/ime-preedit-backspace/script.sh

# 应用修复。开始前结束正在进行的拼音组合并保存工作。
TB710FU_ATTACHMENTS_DIR="$PWD/contributions/ime-preedit-backspace/attachments" \
bash contributions/ime-preedit-backspace/script.sh
```

运行成功后，用户自行注销并重新登录，让扩展及 Fcitx 设置一起加载。入口不自行注销或重启正在运行的输入法。首次安装、桌面重新扫描和完整实际交互仍需重登后验证。

## 风险与回退

这是 GNOME 私有键盘 API 的版本限定修复，不能保证在其他 GNOME 版本工作。预编辑开关是 Fcitx 全局用户设置，可能改变其他应用的拼音呈现方式。它会更新用户目录中的 WowType 桥接扩展、Kimpanel 的两个 JS 文件，并将所需扩展 UUID 加入已有启用列表。

变更前在 `$XDG_STATE_HOME/tb710fu-ime-preedit-backspace/`（默认 `~/.local/state/tb710fu-ime-preedit-backspace/`）创建私有备份，包含原配置、原用户扩展和原启用列表。备份可能含用户设置，应留在本机，不能上传公开仓库。执行过程中失败会尝试自动恢复；也可手动运行：

```sh
TB710FU_ATTACHMENTS_DIR="$PWD/contributions/ime-preedit-backspace/attachments" \
TB710FU_FIX_ACTION=rollback bash contributions/ime-preedit-backspace/script.sh
```

回退恢复最近一次快照的整个相关配置/扩展目录及启用列表，会覆盖其后对这些项目的修改。恢复后自行注销并重新登录。候选区布局扩展本身不被安装入口替换。

## 验证记录

此前 2026-11-15 的实机记录：用户确认候选区拼音可删除、已提交中文也能正常删除；短按、连续按和长按经专门测试。临时诊断窗口及脚本已清理。此处只保留代码和测试描述，不附输入内容、设备日志、截图或配置备份。

本次重新整理可在电脑运行以下回归检查：

```sh
cd contributions/ime-preedit-backspace/attachments
node test-delete.cjs
node test-kimpanel-stable.cjs
python3 test-config.py
```

新增的安装/回退包装只进行离线测试及补丁暂存验证，本次未在平板重新部署。历史核心修复的实机验证不能替代本次安装包装的实机验证。

## 上游

- [WowType](https://github.com/Gloridust/WowType)：不在本包中分发其引擎或用户词库。
- [GNOME Kimpanel](https://github.com/wengxt/gnome-shell-extension-kimpanel)：只分发补丁工具，保留上游扩展其他文件；其 GPL-2.0 许可证附于 `COPYING-kimpanel`。
