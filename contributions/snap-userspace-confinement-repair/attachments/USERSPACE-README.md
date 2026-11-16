# Snap 用户态修复

修复助手下载本条目全部附件并验证 catalog.json 中的 SHA256，由用户审核并确认管理员执行后，Bash 入口通过 TB710FU_ATTACHMENTS_DIR 调用 repair-ubuntu-snap.py。

默认执行 `--apply --verify`，以 sudo 原用户或 ubuntu 测试。需要其他用户时设置 TB710FU_SNAP_USER。首次安装依赖/hello-world 需要联网。不会整体升级系统、解除 hold 或自动安装 IDEA。

如果只需要人工执行只读检查，可运行：

```bash
sudo python3 /path/to/repair-ubuntu-snap.py --check
```

普通执行会备份配置、修复支持的用户态问题并进行实际隔离测试，详见目录说明和风险。旧内核缺少 AppArmor 或 SquashFS 功能时会停止，先使用内核完整升级条目，不能通过修改配置把未编译的功能加进旧内核。
