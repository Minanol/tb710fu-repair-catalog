#!/bin/bash
set -e
printf '%s\n' '=== 管理员权限检查（只读） ==='
printf '当前有效用户 ID：%s\n' "$(id -u)"
printf '内核：%s\n' "$(uname -sr)"
printf '%s\n' '检查完成，未修改系统。'
