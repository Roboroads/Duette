#!/usr/bin/env bash
# Remove a dev install of Duette (from scripts/install.sh) or a pkg install. Run with sudo.
#
# Usage: sudo scripts/uninstall.sh
#
# It runs packaging/uninstall.sh, the pkg's own uninstaller, so both remove the same things: the
# app, the HAL plug-in, the support folder and the installer receipts, then restart coreaudiod.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

case "${1:-}" in
  -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
  '') ;;
  *) echo "uninstall.sh: unknown argument '$1'" >&2; exit 2 ;;
esac

if [ "$(uname -s)" != Darwin ]; then
  echo "uninstall.sh: Duette runs only on macOS" >&2
  exit 1
fi

exec /bin/bash "$repo_root/packaging/uninstall.sh"
