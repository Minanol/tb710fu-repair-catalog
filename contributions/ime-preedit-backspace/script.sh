#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -eq 0 ]]; then
    printf '%s\n' '请以当前 GNOME 桌面用户运行，不要使用 sudo。' >&2
    exit 1
fi
command -v python3 >/dev/null || { printf '%s\n' '需要 Python 3.8 或更新版本。' >&2; exit 1; }
attachments=${TB710FU_ATTACHMENTS_DIR:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/attachments"}
[[ -f "$attachments/repair.py" ]] || { printf '%s\n' '缺少附件 repair.py，请完整下载脚本及附件。' >&2; exit 1; }
exec python3 "$attachments/repair.py" "${TB710FU_FIX_ACTION:-apply}"
