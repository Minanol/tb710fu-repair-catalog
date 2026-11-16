# 验证与边界（2026-11-16）

- 设备：Lenovo TB710FU，Ubuntu 26.04.1 ARM64，目标内核 `7.2.6-tb710fu-snap1`。
- 已实机验证目标内核启动、普通用户 hello-world、Snap strict、AppArmor full、实际文件/网络拒绝及 Seccomp=2。已有更新保护保留，后摄/USB 配套服务正常。
- 升级器已在当前实机执行只读检查和“已经是目标内核”的安装分支；boot 内容和六份 GPT 未变化。未将当前平板降级重刷，自动旧到新的完整流程尚未进行实机端到端测试。
- 隔离测试使用真实启动镜像文件、完整模块归档、实际 depmod/modprobe 依赖解析，模拟硬件/服务。7 项测试覆盖正常安装/收尾/回退、部分写入中断恢复、网络失败后保留内核成功标记并重试、非法归档、GPT 身份/几何保护、写前镜像变化和已更新时不重复写入。
- 目录入口另验证全部附件哈希、分片重组、归档路径/类型限制、完整载荷及模块归档。validate 模式不运行修复；本次贡献准备不刷写设备、不重启设备。

## 发布数据检查

载荷仅含本次新构建并验证的启动镜像/模块、必要配套文件、配置和安装脚本。不是设备启动分区备份。对照私有审查资料排除了设备 GPT/文件系统 UUID 的文本及二进制形式、私钥标记；initramfs 的文件清单和启动/USB/NBD 脚本亦已检查。包内没有旧 boot、GPT 备份、私有 USB MAC 文件、账号数据、原始日志或已退役前摄资料。

包内 GPT 仅保留用于预检的通用分区几何、名称、类型及相关属性，不含设备分区 UUID；每次实际运行仍现场检查当前固件/GPT，按当时的 boot_a 标签动态定位设备。固件哈希用于严格匹配，不是设备唯一标识。

此条目不会安装 IDEA，不改桌面输入法。IDEA/WowType 的后续临时测试与本次 Snap 内核贡献分开。

## 来源与可复核信息

目标 boot SHA256：`6a588ec97a053d85afcf2b8dd8a62c479f50c7d6ec45552036c1a25e618fdf0e`。
完整配套模块归档 SHA256：`d5b172685d4a3ee0af71a7a86ec2e13dd9c9748c674085be9194b5f16822a6b4`。
目录分片/整体载荷/升级器哈希由 `bundle-parts.json` 固定，目录本身的脚本和附件哈希位于 catalog.json。

已有适配开发仓库：https://github.com/fakerUZI/tb710fu-ubuntu-adaptation
Linux 7.2.6 源码 SHA256：`039aef84f2b0994aeda3f4fcfc3d02ec9d7a9bbb9020ea264c43f446c860f606`。
基础板级补丁来源：

- https://github.com/mydanyi/armadaos-freedom/tree/ba692d8c06fc1d5d7cafe91325448b19765a7b08
- https://github.com/lich-wang/tb710fu-hyperos-steamos/tree/5e99ee13df849f592a4594910473f1bbdbd79ee3
- https://github.com/deinthoedoka/TB710FU-Archlinux/tree/110fbccb59ed3ea3bc323fc05601ad6fd442f02d

同目录附件包含内核构建步骤、AppArmor 兼容补丁及完整目标 config，供审核对照；构建工具依赖适配开发工作区，不在修复时运行。
