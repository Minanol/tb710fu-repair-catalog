#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
: "${TB710FU_ATTACHMENTS_DIR:?修复助手未提供附件目录 TB710FU_ATTACHMENTS_DIR}"
[[ $EUID -eq 0 ]] || { echo '需要管理员权限。' >&2; exit 2; }
target=${TB710FU_SNAP_USER:-${SUDO_USER:-ubuntu}}
[[ $target != root ]] || target=ubuntu
exec python3 "$TB710FU_ATTACHMENTS_DIR/assemble-kernel-bundle.py" \
  --attachments-dir "$TB710FU_ATTACHMENTS_DIR" \
  --action "${TB710FU_SNAP_KERNEL_ACTION:-install}" --user "$target"
