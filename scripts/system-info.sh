#!/bin/bash
set -e
printf '%s\n' '=== 系统版本 ==='
if [ -r /etc/os-release ]; then cat /etc/os-release; else printf '%s\n' '无法读取 /etc/os-release'; fi
printf '\n%s\n' '=== 内核 ==='
uname -srmo
printf '\n%s\n' '=== 设备型号 ==='
if [ -r /sys/firmware/devicetree/base/model ]; then tr -d '\000' < /sys/firmware/devicetree/base/model; printf '\n'; else printf '%s\n' '设备树型号不可用'; fi
